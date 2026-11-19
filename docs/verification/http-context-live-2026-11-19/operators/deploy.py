"""Sealed seven-service cutover with health checks, smoke rejection and rollback."""
import copy,hashlib,json,os,subprocess,sys,time
from pathlib import Path
from urllib.request import urlopen
P=Path(__file__).resolve().parent;R=P.parents[1]
TARGETS=json.loads((P/'targets.json').read_text());BEFORE=json.loads((P/'private/all-before.json').read_text());CHANGED=[];JOURNAL=[]
PROFILES={'n0':'relation','wp_n1':'isobase','wp_n2':'isotope','wp_n3':'actor','wp_n4':'actor','wp_admin':'actor','wp_n5':'actor'}
def docker(*a):return subprocess.check_output(['docker',*map(str,a)],stderr=subprocess.PIPE)
def inspect(n):return json.loads(docker('inspect',n))[0]
def record(stage,**v):
 JOURNAL.append(dict(stage=stage,utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),**v));(P/'journal.json').write_text(json.dumps(JOURNAL,indent=2)+'\n');print(stage,v,flush=True)
def up(t,phase):
 with (P/'logs'/(t['service']+'-'+phase+'-cutover.private.log')).open('a') as out:
  subprocess.run(['docker','compose','-p',t['project'],'-f',str(P/'models'/(t['service']+'-'+phase+'.json')),'up','-d','--no-build','--pull','never','--no-deps',t['service']],stdout=out,stderr=subprocess.STDOUT,check=True)
def health(t):
 svc=t['service'];node='n0' if svc=='n0' else svc[3:];url='http://127.0.0.1:3054' if svc=='wp_admin' else 'https://'+node+'.elfenbenstornet.se';last=''
 for _ in range(60):
  try:
   assert inspect(t['container'])['State']['Running']
   with urlopen(url+'/node_info',timeout=4) as f:info=json.load(f)
   assert info['profile']==PROFILES[svc] and not info.get('maintenance',False)
   if svc!='wp_admin':assert info['auth']=='open'
   if svc=='wp_n5':assert 'linda' in info['services']
   return
  except Exception as e:last=type(e).__name__;time.sleep(1)
 raise RuntimeError(svc+' readiness failed: '+last)
def preservation(phase):
 names={t['container'] for t in TARGETS}
 for old in BEFORE:
  if old['Name'].removeprefix('/') not in names and (old['Config'].get('Labels') or {}).get('com.docker.compose.service'):
   now=inspect(old['Name']);assert (now['Id'],now['Image'])==(old['Id'],old['Image']),'unrelated service changed: '+old['Name']
 for t in TARGETS:
  old=next(x for x in BEFORE if x['Name']=='/'+t['container']);now=inspect(t['container']);assert now['Image']==t['candidate_image' if phase=='candidate' else 'old_image']
  for field in ['Env','Cmd','Entrypoint','User','WorkingDir','Healthcheck','ExposedPorts','StopSignal']:
   a,b=old['Config'].get(field),now['Config'].get(field)
   if field=='Env':a,b=sorted(a),sorted(b)
   assert a==b,t['service']+' config mismatch: '+field
  for field in ['ReadonlyRootfs','Memory','MemorySwap','NanoCpus','PidsLimit','CapDrop','SecurityOpt','Tmpfs','PortBindings','Init','RestartPolicy','LogConfig']:
   assert old['HostConfig'].get(field)==now['HostConfig'].get(field),t['service']+' host config mismatch: '+field
  mounts=lambda d:sorted((m['Type'],m.get('Name',m['Source']),m['Destination'],m['RW']) for m in d['Mounts'])
  assert mounts(old)==mounts(now),t['service']+' mounts changed'
  model=json.loads((P/'models'/(t['service']+'-'+phase+'.json')).read_text());s=model['services'][t['service']]
  assert set(old['NetworkSettings']['Networks'])==set(now['NetworkSettings']['Networks'])
  for alias,opts in s['networks'].items():
   net=model['networks'][alias]['name'];a=old['NetworkSettings']['Networks'][net];b=now['NetworkSettings']['Networks'][net]
   assert set(a['Aliases'])==set(b['Aliases']),t['service']+' network aliases changed'
   if opts.get('ipv4_address'):assert a['IPAddress']==b['IPAddress'],t['service']+' static IP changed'
  for m in old['Mounts']:
   if not m['RW']:
    got=docker('exec',t['container'],'sh','-c','find "$1" -type f -exec sha256sum {} +','sh',m['Destination'])
    assert sorted(got.splitlines())==sorted((P/'private'/(t['service']+'-'+Path(m['Destination']).name+'.hashes')).read_bytes().splitlines()),'read-only payload changed'
 assert docker('exec','deployment-caddy-1','cat','/etc/caddy/Caddyfile')==(P/'private/Caddyfile.before').read_bytes(),'Caddy changed'
 record('protected_configuration_preserved',phase=phase)
def atomic(path,data):
 tmp=path.with_name(path.name+'.http-context-tmp');tmp.write_bytes(data);tmp.chmod(0o600);os.replace(tmp,path)
def selection(restore=False):
 paths=[R/'Deployment/compose.live.json',R/'.trinity/live-swi-current.json',R/'.trinity/live-n5-current.json']
 if restore:
  for path in paths:
   backup=P/'private'/(path.name+'.before-selection')
   if backup.exists():atomic(path,backup.read_bytes())
  return
 for path in paths:
  assert not (P/'private'/(path.name+'.before-selection')).exists()
  if path.exists():(P/'private'/(path.name+'.before-selection')).write_bytes(path.read_bytes())
 model=json.loads(paths[0].read_text());previous=copy.deepcopy(model)
 for t in TARGETS:
  if t['project']!='deployment':continue
  frozen=json.loads((P/'models'/(t['service']+'-candidate.json')).read_text());model['services'][t['service']]=frozen['services'][t['service']]
  for kind in ['networks','volumes']:
   for k,v in frozen.get(kind,{}).items():
    if k in model.get(kind,{}):assert model[kind][k]==v,'resource alias conflict'
    model.setdefault(kind,{})[k]=v
 selected={t['service'] for t in TARGETS if t['project']=='deployment'}
 assert all(model['services'][k]==v for k,v in previous['services'].items() if k not in selected)
 atomic(paths[0],(json.dumps(model,indent=2)+'\n').encode())
 revisions=json.loads((P/'revisions.json').read_text())
 for path,kind in [(paths[1],'swi'),(paths[2],'trealla')]:
  pointer=dict(preparation=str(P),revisions=revisions,targets=[dict(service=t['service'],project=t['project'],image=t['candidate_image'],model=str(P/'models'/(t['service']+'-candidate.json')),rollback_model=str(P/'models'/(t['service']+'-rollback.json'))) for t in TARGETS if t['kind']==kind],rollback_command='python3 '+str(P/'deploy.py')+' --rollback')
  if kind=='swi':pointer.update(shared_revision=revisions['shared'],native_revision=revisions['native'],browser_revision=revisions['browser'],engine='11.0.0')
  else:
   t=next(t for t in TARGETS if t['kind']=='trealla');pointer.update(project=t['project'],service=t['service'],image=t['candidate_image'],model=str(P/'models'/(t['service']+'-candidate.json')),predecessor=t['old_image'],rollback_model=str(P/'models'/(t['service']+'-rollback.json')),source_revision=revisions['trealla'])
  atomic(path,(json.dumps(pointer,indent=2)+'\n').encode())
def rollback():
 failures=[]
 for t in reversed(CHANGED):
  try:up(t,'rollback');health(t);assert inspect(t['container'])['Image']==t['old_image'];record('predecessor_restored',service=t['service'])
  except BaseException as e:failures.append(dict(service=t['service'],error=type(e).__name__))
 selection(restore=True)
 if not failures and len(CHANGED)==len(TARGETS):preservation('rollback')
 record('rolled_back' if not failures else 'rollback_needs_attention',failures=failures)
 return not failures
def main():
 seal=json.loads((P/'seal.json').read_text())
 for f,h in seal['files'].items():assert hashlib.sha256((P/f).read_bytes()).hexdigest()==h,'sealed input changed: '+f
 if '--rollback' in sys.argv:
  CHANGED.extend(TARGETS);return 0 if rollback() else 2
 for t in TARGETS:
  old=next(x for x in BEFORE if x['Name']=='/'+t['container']);assert inspect(t['container'])['Id']==old['Id'],'predecessor moved: '+t['service']
 assert hashlib.sha256((R/'Deployment/compose.live.json').read_bytes()).hexdigest()==seal['canonical_sha256'],'canonical selection moved'
 ci=json.loads((P/'ci.json').read_text());assert ci['conclusion']=='success' and ci['headSha']==json.loads((P/'revisions.json').read_text())['shared']
 checks=json.loads((P/'pinned-ci/results.json').read_text());assert len(checks)==34 and all(r['exit_code']==0 for r in checks)
 browser=json.loads((P/'browser-tests/results.json').read_text());assert len(browser['runs'])==5 and all(r['exit_code']==0 for r in browser['runs'])
 assert json.loads((P/'open-exercises/results.json').read_text())['status']=='pass'
 assert json.loads((P/'rollback-rehearsal.json').read_text())['state_marker_preserved']
 assert len(json.loads((P/'context-rehearsal.json').read_text()))==7
 assert json.loads((P/'image-qualification.json').read_text())['status']=='pass'
 for engine in ['swi','trealla']:assert json.loads((P/('image-gate-'+engine)/engine/'release-summary.json' if engine=='swi' else P/'image-gate-trealla/release-summary.json').read_text())['passed']
 record('preflight_verified')
 try:
  for svc in ['wp_admin','wp_n4','wp_n3','wp_n1','wp_n2','wp_n5','n0']:
   t=next(t for t in TARGETS if t['service']==svc);CHANGED.append(t);up(t,'candidate');health(t)
   assert inspect(t['container'])['Image']==t['candidate_image'];record('upgraded_and_healthy',service=svc,image=t['candidate_image'])
  preservation('candidate');subprocess.run([sys.executable,str(P/'smoke.py')],check=True);preservation('candidate');selection();record('verified_and_selected');return 0
 except BaseException as e:
  record('deployment_failed',error=type(e).__name__,detail=str(e))
  for t in CHANGED:
   with (P/'logs'/(t['service']+'-failure.private.log')).open('wb') as out:subprocess.run(['docker','logs','--tail','150',t['container']],stdout=out,stderr=subprocess.STDOUT)
  rollback();return 1
if __name__=='__main__':raise SystemExit(main())
