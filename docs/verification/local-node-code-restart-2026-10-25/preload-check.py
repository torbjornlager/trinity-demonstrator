from pathlib import Path
import subprocess,time,re,sys,json
from urllib.request import urlopen
sys.path.insert(0,'../trinity-conformance/runner');import run as wire
state=Path.home()/'.local/share/trinity-local-nodes/code-restart-2026-10-25/n3-preflight';out=Path(__file__).resolve().parent
port=int(re.search(r'config\(n3,(\d+),', (state/'start_local_node.pl').read_text()).group(1))
with (out/'xml-preload-preflight.log').open('w') as log:
 p=subprocess.Popen([str(state/'start.sh')],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
 try:
  for _ in range(100):
   if p.poll() is not None:raise RuntimeError('startup exit')
   try:
    with urlopen(f'http://localhost:{port}/healthz',timeout=.3) as r:assert r.status==200
    break
   except Exception:time.sleep(.1)
  w=wire.WebSocket(f'ws://localhost:{port}/ws',5,None,None,False,())
  events=[]
  try:
   w.send_json({'command':'toplevel_spawn','options':'[session(true)]'});e=w.recv_json();events.append(e);pid=e['pid']
   goal="statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"/></statechart>'),monitor(true)]),statechart_halt(P,true),receive({down(P,P,_)->true},[timeout(2)])"
   w.send_json({'command':'toplevel_call','pid':pid,'goal':goal,'options':'[limit(1)]'})
   for _ in range(20):
    e=w.recv_json();events.append(e)
    if e.get('type') in ['success','error','failure']:break
   assert e['type']=='success',events
   w.send_json({'command':'toplevel_halt','pid':pid});print('XML preloads restore statechart startup',flush=True)
  finally:w.close();(out/'xml-preload-preflight.json').write_text(json.dumps(events,indent=2)+'\n')
 finally:
  p.terminate();p.wait(timeout=8)
