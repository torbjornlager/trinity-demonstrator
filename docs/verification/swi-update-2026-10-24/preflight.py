from pathlib import Path
import subprocess,json,urllib.request,time,os,signal
ROOT=Path('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator');OUT=Path(__file__).resolve().parent;DURABLE=Path.home()/'.local/share/trinity-local-nodes/n3';EXE=Path.home()/'.local/share/trinity-runtimes/swi-current/bin/swipl'
source=(DURABLE/'start_local_node.pl').read_text().replace('config(n3,3053,open,','config(n3,51854,open,');entry=OUT/'preflight-node.pl';entry.write_text(source)
with (OUT/'preflight-node.log').open('w') as log:
 p=subprocess.Popen([str(EXE),'-f','none','-q','-s',str(entry),'--','n3'],cwd=ROOT,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
 try:
  for _ in range(100):
   if p.poll() is not None:raise RuntimeError('preflight exited')
   try:
    with urllib.request.urlopen('http://localhost:51854/admin/config',timeout=.3) as r:config=json.load(r)
    break
   except Exception:time.sleep(.1)
  else:raise RuntimeError('preflight readiness timeout')
  before=json.loads((OUT/'before-admin-config.json').read_text());difference={k:{'old':before.get(k),'candidate':config.get(k)} for k in set(before)|set(config) if before.get(k)!=config.get(k)}
  (OUT/'preflight-config.json').write_text(json.dumps(config,indent=2)+'\n');(OUT/'preflight-config-difference.json').write_text(json.dumps(difference,indent=2)+'\n');print(json.dumps(difference));assert set(difference)=={'self_url'},'Configuration changed; do not restart n3'
 finally:
  if p.poll() is None:p.terminate();p.wait(timeout=10)
