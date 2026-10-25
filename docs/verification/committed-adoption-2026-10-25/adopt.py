from pathlib import Path
import os,sys,json,subprocess,shutil,time,signal,socket,hashlib
from urllib.request import urlopen
from urllib.parse import urlencode
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');ROOT=Path.home()/'.local/share/trinity-local-nodes';STATE=ROOT/'committed-adoption-2026-10-25';OUT=Path(__file__).resolve().parent
sys.path.insert(0,str(BASE/'trinity-conformance/runner'));import run as wire
selection=json.loads((STATE/'selection.json').read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def get(url):
 with urlopen(url,timeout=8) as r:return json.load(r)
def http(port,goal):
 with urlopen(f'http://localhost:{port}/call?'+urlencode(dict(goal='('+goal+')',template='(Outcome)',limit=1,format='prolog')),timeout=8) as r:return r.read().decode()
def launch(path,log):
 with log.open('ab',buffering=0) as f:return subprocess.Popen([str(path)],stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)
def ready(port,p):
 for _ in range(100):
  if p.poll() is not None:raise RuntimeError('startup exit '+str(p.returncode))
  try:return get(f'http://localhost:{port}/node_info')
  except Exception:time.sleep(.1)
 raise RuntimeError('startup timeout')
def free():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def check(port):
 result=http(port,'"hé😀"==[h,é,\'😀\'],authorized(alice),owns(alice,P),online(P),Outcome=ok');assert 'success([ok],false)' in result,result
 # Use the same negotiated terminal path as the browser.
 source=(STATE/'demonstrator/examples/actors/06 ping-pong.pl').read_text();q="'"+source.replace('\\','\\\\').replace('\r','\\r').replace('\n','\\n').replace('\t','\\t').replace("'","''")+"'";events=[]
 with wire.Harness(wire.Candidate(f'ws://localhost:{port}/ws','actor',10,None,f'http://localhost:{port}',False,())) as h:
  h.send(dict(command='transport_hello',version=1,io_ack=True,answer_terms=False));h.recv();h.spawn_shell('[session(true),src_text('+q+')]' )
  h.call('ping_pong,Outcome=ok','[template(Outcome),format(prolog),limit(1)]')
  for _ in range(40):
   e=h.recv();events.append(e)
   if e.get('type')=='io_request':h.send(dict(command='browser_io_reply',request_id=e['request_id'],status='ok'))
   if any(x.get('type')=='success' for x in events) and all(any(m in str(x) for x in events) for m in ['Ping finished.','Pong finished.']):break
  else:raise RuntimeError(events)
  h.halt()
 return dict(text_and_shared=result,ping_pong=events)
before=dict(n3_config=get('http://localhost:3053/admin/config'),n5_info=get('http://localhost:3062/node_info'),protected=subprocess.check_output(['ps','-p','91509,97669','-o','pid=,lstart=,command='],text=True),engines=json.loads((STATE/'engine-selection.json').read_text()),pin_sha256=sha(BASE/'trinity-demonstrator/dependencies/swi-prolog-node.json'))
(OUT/'before.json').write_text(json.dumps(before,indent=2)+'\n');subprocess.run([sys.executable,str(STATE/'verify.py')],check=True)
preflight={}
for name in ['n3','n5']:
 port=free();text=(STATE/(name+'-start.sh')).read_text()
 if name=='n3':
  (STATE/'preflight.pl').write_text((STATE/'start_local_node.pl').read_text().replace('config(n3,3053,open,',f'config(n3,{port},open,'));text=text.replace(str(STATE/'start_local_node.pl'),str(STATE/'preflight.pl'))
 else:text=text.replace('web_prolog_node(3062,',f'web_prolog_node({port},')
 path=STATE/(name+'-preflight.sh');path.write_text(text);path.chmod(0o755);p=launch(path,STATE/(name+'-preflight.log'))
 try:ready(port,p);preflight[name]=check(port);print(name,'committed preflight passed',flush=True)
 finally:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
(OUT/'preflight.json').write_text(json.dumps(preflight,indent=2)+'\n')
records=[]
for name,pid,needle,port in [('n3',8855,'portable-text-live-2026-10-25/start_local_node.pl',3053),('n5',11084,'web_prolog_node(3062,',3062)]:
 command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True);assert needle in command
 os.kill(pid,signal.SIGTERM)
 for _ in range(80):
  status=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
  if status.returncode or status.stdout.strip().startswith('Z'):break
  time.sleep(.1)
 else:raise RuntimeError('old backend has not stopped: '+name)
 shutil.copy2(STATE/(name+'-start.sh'),ROOT/name/'start.sh');p=launch(ROOT/name/'start.sh',ROOT/name/(name+'.log'))
 try:
  ready(port,p);value=get('http://localhost:3053/admin/config') if name=='n3' else get('http://localhost:3062/node_info');assert value==before['n3_config' if name=='n3' else 'n5_info'];result=check(3053 if name=='n3' else 3060)
 except Exception:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
  shutil.copy2(STATE/(name+'-rollback.sh'),ROOT/name/'start.sh');old=launch(ROOT/name/'start.sh',ROOT/name/(name+'.log'));ready(port,old);(ROOT/name/(name+'.pid')).write_text(str(old.pid)+'\n');raise
 (ROOT/name/(name+'.pid')).write_text(str(p.pid)+'\n');records.append(dict(node=name,old_pid=pid,new_pid=p.pid,configuration_preserved=True,checks=result));(OUT/'restart.json').write_text(json.dumps(records,indent=2)+'\n');print(name,'commit-pinned restart passed',p.pid,flush=True)
subprocess.run([sys.executable,str(STATE/'verify.py')],check=True)
assert before['protected']==subprocess.check_output(['ps','-p','91509,97669','-o','pid=,lstart=,command='],text=True)
for path,item in before['engines'].items():assert sha(Path(path))==item['sha256'] and str(Path(path).resolve())==item['target']
(OUT/'preservation.json').write_text(json.dumps(dict(engine_targets_and_hashes_unchanged=True,frontend_and_auxiliary_processes_unchanged=True,commit_guard_passes=True,selection=selection),indent=2)+'\n')
for name in ['selection.json','engine-selection.json','verify.py','start_local_node.pl','n3-start.sh','n5-start.sh']:
 shutil.copy2(STATE/name,OUT/name)
