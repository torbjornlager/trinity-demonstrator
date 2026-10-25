from pathlib import Path
import os,subprocess,shutil,signal,time,json,hashlib,socket,shlex
from urllib.request import urlopen
from urllib.parse import urlencode
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');DEMO=BASE/'trinity-demonstrator';STATE=Path.home()/'.local/share/trinity-local-nodes';BATCH=STATE/'portable-text-live-2026-10-25';OUT=Path(__file__).resolve().parent
assert not BATCH.exists();BATCH.mkdir()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def get(url):
 with urlopen(url,timeout=5) as r:return json.load(r)
def query(port,goal):
 with urlopen(f'http://localhost:{port}/call?'+urlencode(dict(goal='('+goal+')',template='(Outcome)',format='prolog',limit=1)),timeout=8) as r:return r.read().decode()
def free():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def start(script,log):
 with log.open('ab',buffering=0) as f:return subprocess.Popen([str(script)],stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)
def ready(port,p):
 for _ in range(100):
  if p.poll() is not None:raise RuntimeError('startup exit '+str(p.returncode))
  try:return get(f'http://localhost:{port}/node_info')
  except Exception:time.sleep(.1)
 raise RuntimeError('startup timeout')
def stop(pid,needle):
 command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True);assert needle in command
 os.kill(pid,signal.SIGTERM)
 for _ in range(60):
  status=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
  if status.returncode or status.stdout.strip().startswith('Z'):return False
  time.sleep(.1)
 os.kill(pid,signal.SIGKILL);time.sleep(.2);return True
def script(p,text):p.write_text(text);p.chmod(0o755)
engines=[Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl',BASE/'trealla-port/.build/trealla-current/tpl']
before=dict(engines={str(p):dict(target=str(p.resolve()),sha256=sha(p)) for p in engines},pin_sha256=sha(DEMO/'dependencies/swi-prolog-node.json'),n3_config=get('http://localhost:3053/admin/config'),n5_info=get('http://localhost:3062/node_info'),protected=subprocess.check_output(['ps','-p','91509,97669','-o','pid=,lstart=,command='],text=True))
(OUT/'before.json').write_text(json.dumps(before,indent=2)+'\n')
for name in ['n3','n5']:shutil.copy2(STATE/name/'start.sh',BATCH/(name+'-rollback.sh'))
shutil.copytree(STATE/'code-restart-2026-10-25/swi-active-source',BATCH/'swi-source')
for f in (BASE/'swi-prolog-node/prolog').rglob('*.pl'):shutil.copy2(f,BATCH/'swi-source/prolog'/f.relative_to(BASE/'swi-prolog-node/prolog'))
shutil.copytree(STATE/'write-output-2026-10-25/trealla-active-source',BATCH/'trealla-source',ignore=shutil.ignore_patterns('reproducers','docs','tests','.build','.git'))
shutil.copytree(DEMO/'examples',BATCH/'demonstrator/examples');shutil.copytree(DEMO/'Deployment',BATCH/'demonstrator/Deployment')
pl=(STATE/'code-restart-2026-10-25/n3-active/start_local_node.pl').read_text().replace(str(STATE/'code-restart-2026-10-25/swi-active-source'),str(BATCH/'swi-source'))
pl=pl.replace(str(DEMO/'examples'),str(BATCH/'demonstrator/examples')).replace(str(DEMO/'Deployment'),str(BATCH/'demonstrator/Deployment'))
(BATCH/'start_local_node.pl').write_text(pl)
n3=(STATE/'n3/start.sh').read_text().replace(str(STATE/'code-restart-2026-10-25/n3-active/start_local_node.pl'),str(BATCH/'start_local_node.pl'))
n3=n3.replace('exec /Users/', 'export WP_EXPERIMENTAL_TEXT=portable-text-0.2\nexec /Users/')
script(BATCH/'n3-start.sh',n3)
n5=(STATE/'n5/start.sh').read_text().replace(str(STATE/'write-output-2026-10-25/trealla-active-source'),str(BATCH/'trealla-source'))
script(BATCH/'n5-start.sh',n5)
checks=[]
for name in ['n3','n5']:
 port=free();text=(BATCH/(name+'-start.sh')).read_text()
 if name=='n3':
  (BATCH/'preflight.pl').write_text(pl.replace('config(n3,3053,open,',f'config(n3,{port},open,'));text=text.replace(str(BATCH/'start_local_node.pl'),str(BATCH/'preflight.pl'))
 else:text=text.replace('web_prolog_node(3062,',f'web_prolog_node({port},')
 path=BATCH/(name+'-preflight.sh');script(path,text);p=start(path,BATCH/(name+'-preflight.log'))
 try:
  ready(port,p)
  for label,goal in [('chars','"abc"==[a,b,c],Outcome=ok'),('shared','authorized(alice),owns(alice,P),online(P),Outcome=ok')]:
   answer=query(port,goal);assert 'success([ok],false)' in answer,(name,label,answer);checks.append(dict(node=name,check=label,result=answer))
 finally:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
(OUT/'preflight.json').write_text(json.dumps(checks,indent=2)+'\n')
records=[]
for name,pid,needle,port in [('n3',91992,'start_local_node.pl -- n3',3053),('n5',94384,'web_prolog_node(3062,',3062)]:
 forced=stop(pid,needle)
 try:
  shutil.copy2(BATCH/(name+'-start.sh'),STATE/name/'start.sh');p=start(STATE/name/'start.sh',STATE/name/(name+'.log'));ready(port,p)
  (STATE/name/(name+'.pid')).write_text(str(p.pid)+'\n')
  value=get('http://localhost:3053/admin/config') if name=='n3' else get('http://localhost:3062/node_info')
  assert value==before['n3_config' if name=='n3' else 'n5_info'],'configuration changed'
  assert 'success([ok],false)' in query(port,'"abc"==[a,b,c],Outcome=ok')
 except Exception:
  if 'p' in locals() and p.poll() is None:p.terminate();p.wait(timeout=10)
  shutil.copy2(BATCH/(name+'-rollback.sh'),STATE/name/'start.sh');rollback=start(STATE/name/'start.sh',STATE/name/(name+'.log'));ready(port,rollback);(STATE/name/(name+'.pid')).write_text(str(rollback.pid)+'\n');raise
 records.append(dict(node=name,old_pid=pid,new_pid=p.pid,forced_stop=forced,configuration_preserved=True));print(name,p.pid,flush=True)
 (OUT/'restart.json').write_text(json.dumps(dict(batch=str(BATCH),nodes=records),indent=2)+'\n')
after=dict(engines={str(p):dict(target=str(p.resolve()),sha256=sha(p)) for p in engines},pin_sha256=sha(DEMO/'dependencies/swi-prolog-node.json'),protected=subprocess.check_output(['ps','-p','91509,97669','-o','pid=,lstart=,command='],text=True))
assert all(after[k]==before[k] for k in after)
(OUT/'after.json').write_text(json.dumps(after,indent=2)+'\n')
(OUT/'source-hashes.json').write_text(json.dumps({str(f.relative_to(BATCH)):sha(f) for root in ['swi-source/prolog','trealla-source','demonstrator/examples','demonstrator/Deployment'] for f in (BATCH/root).rglob('*') if f.is_file() and (f.suffix in ['.pl','.xml'] or f.name.endswith('.sh'))},indent=2)+'\n')
