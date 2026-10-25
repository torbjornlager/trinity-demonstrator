from pathlib import Path
import os,sys,json,subprocess,shutil,signal,time,socket,hashlib,shlex
from urllib.request import urlopen
from urllib.parse import urlencode
BASE=Path('/Users/torbjorn.lager/Documents/GitHub');DEMO=BASE/'trinity-demonstrator';NATIVE=BASE/'swi-prolog-node';TPLROOT=BASE/'trealla-port'
OUT=Path(__file__).resolve().parent;STATE=Path.home()/'.local/share/trinity-local-nodes';BATCH=STATE/'code-restart-2026-10-25'
assert not BATCH.exists();BATCH.mkdir()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def get(url):
 with urlopen(url,timeout=8) as r:return json.load(r)
def archive(repo,dest):
 dest.mkdir();p=subprocess.Popen(['git','-C',str(repo),'archive','HEAD'],stdout=subprocess.PIPE)
 subprocess.run(['tar','-x','-C',str(dest)],stdin=p.stdout,check=True);p.stdout.close();assert p.wait()==0
def quote(x):return "'"+str(x).replace("'","''")+"'"
def free():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def stop(pid,expected):
 command=subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip();assert expected in command,(pid,command)
 os.kill(pid,signal.SIGTERM)
 for _ in range(60):
  p=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
  if p.returncode or p.stdout.strip().startswith('Z'):return False
  time.sleep(.1)
 os.kill(pid,signal.SIGKILL);time.sleep(.2);return True
def start(script,log,pidfile=None):
 with Path(log).open('ab',buffering=0) as f:p=subprocess.Popen([str(script)],stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)
 if pidfile:Path(pidfile).write_text(str(p.pid)+'\n')
 return p
def ready(url,proc):
 for _ in range(100):
  if proc.poll() is not None:raise RuntimeError('startup exit '+str(proc.returncode))
  try:return get(url)
  except Exception:time.sleep(.1)
 raise RuntimeError('startup timeout '+url)
def script(path,text):path.write_text(text);path.chmod(0o755)
def swi_start(path,source,port,envroot):
 text=(STATE/'n3/start_local_node.pl').read_text().replace(str(DEMO/'load.pl'),str(source/'load.pl'))
 text=text.replace('config(n3,3053,open,',f'config(n3,{port},open,')
 (envroot/'start_local_node.pl').write_text(text)
 config=json.loads((DEMO/'.trinity/native-swi.json').read_text())
 script(path,'#!/bin/sh\nset -eu\ncd '+shlex.quote(str(DEMO))+"\nunset SWI_HOME_DIR SWIPL_HOME_DIR WP_EXPERIMENTAL_TEXT WP_NATIVE_MODE WP_NATIVE_STATE\nexport WP_ASSET_ROOT="+shlex.quote(str(DEMO))+"\nexport WP_WASM_SOURCE_DIR="+shlex.quote(config['wasm_root'])+'\nexec '+shlex.quote(str(Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl'))+' -f none -q -s '+shlex.quote(str(envroot/'start_local_node.pl'))+' -- n3\n')
def tpl_start(path,source,port=3062):
 old=(STATE/'n5/start.sh').read_text();text=old.replace('cd '+str(TPLROOT),'cd '+shlex.quote(str(source))).replace('web_prolog_node(3062,',f'web_prolog_node({port},')
 script(path,text)
before=dict(n3_config=get('http://localhost:3053/admin/config'),n5_info=get('http://127.0.0.1:3062/node_info'),processes=subprocess.check_output(['ps','-p','7072,97896,97669,42134','-o','pid=,lstart=,command='],text=True),engines={str(p):dict(target=str(p.resolve()),sha256=sha(p)) for p in [Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl',TPLROOT/'.build/trealla-current/tpl']},pin_sha256=sha(DEMO/'dependencies/swi-prolog-node.json'))
(OUT/'before.json').write_text(json.dumps(before,indent=2)+'\n')
for node in ['n3','n5']:
 dest=BATCH/(node+'-original-launcher');dest.mkdir()
 for f in (STATE/node).glob('*'):
  if f.is_file():shutil.copy2(f,dest/f.name)
for kind,repo in [('swi',NATIVE),('trealla',TPLROOT)]:
 archive(repo,BATCH/(kind+'-rollback-source'))
 shutil.copytree(BATCH/(kind+'-rollback-source'),BATCH/(kind+'-active-source'))
for rel in ['prolog/web_prolog/toplevel_actors.pl']:shutil.copy2(NATIVE/rel,BATCH/'swi-active-source'/rel)
for rel in ['answer_terms.pl','toplevel_actors.pl','node.pl']:shutil.copy2(TPLROOT/rel,BATCH/'trealla-active-source'/rel)
for kind in ['n3-active','n3-rollback','n3-preflight','n5-active','n5-rollback','n5-preflight']:(BATCH/kind).mkdir()
swi_start(BATCH/'n3-active/start.sh',BATCH/'swi-active-source',3053,BATCH/'n3-active')
swi_start(BATCH/'n3-rollback/start.sh',BATCH/'swi-rollback-source',3053,BATCH/'n3-rollback')
tpl_start(BATCH/'n5-active/start.sh',BATCH/'trealla-active-source')
tpl_start(BATCH/'n5-rollback/start.sh',BATCH/'trealla-rollback-source')
# Check actual startup with the existing service/shared DB configuration before stopping live nodes.
p3=free();p5=free()
swi_start(BATCH/'n3-preflight/start.sh',BATCH/'swi-active-source',p3,BATCH/'n3-preflight')
tpl_start(BATCH/'n5-preflight/start.sh',BATCH/'trealla-active-source',p5)
for name,port,route,expected in [('n3',p3,'admin/config',before['n3_config']),('n5',p5,'node_info',before['n5_info'])]:
 proc=start(BATCH/(name+'-preflight/start.sh'),BATCH/(name+'-preflight/log'))
 try:
  value=ready(f'http://localhost:{port}/'+route,proc)
  if name=='n3':
   # The listening/public URL and its derived resident-service PID addresses differ in this preflight.
   (OUT/'preflight-n3-config.json').write_text(json.dumps(value,indent=2)+'\n')
  else:assert value==expected
  q=urlencode(dict(goal='(X=f(X))',template='(X)',format='prolog',limit='1'))
  with urlopen(f'http://localhost:{port}/call?'+q,timeout=8) as r:answer=r.read().decode()
  assert 'representation_error(cyclic_term)' in answer,answer
  print(name,'preflight passed',flush=True)
 finally:
  if proc.poll() is None:proc.terminate();proc.wait(timeout=8)
# Stage launchers durably only after successful preflight.
for node in ['n3','n5']:
 shutil.copy2(BATCH/(node+'-active/start.sh'),STATE/node/'start.sh')
records=[]
for node,pid,needle,url in [('n3',7072,'start_local_node.pl -- n3','http://localhost:3053/admin/config'),('n5',97896,'web_prolog_node(3062,','http://127.0.0.1:3062/node_info')]:
 forced=stop(pid,needle)
 proc=start(STATE/node/'start.sh',STATE/node/(node+'.log'),STATE/node/(node+'.pid'))
 value=ready(url,proc)
 assert value==(before['n3_config'] if node=='n3' else before['n5_info']),(node,'configuration differs')
 records.append(dict(node=node,old_pid=pid,new_pid=proc.pid,forced_stop=forced,configuration_identical=True))
 (OUT/'restart.json').write_text(json.dumps(dict(batch=str(BATCH),nodes=records),indent=2)+'\n')
 print(node,'restarted',proc.pid,flush=True)
(OUT/'after.json').write_text(json.dumps(dict(engines={str(p):dict(target=str(p.resolve()),sha256=sha(p)) for p in [Path(x) for x in before['engines']]},pin_sha256=sha(DEMO/'dependencies/swi-prolog-node.json')),indent=2)+'\n')
