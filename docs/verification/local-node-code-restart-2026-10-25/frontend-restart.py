from pathlib import Path
import subprocess,socket,time,json,signal,os,sys,shutil
from urllib.request import urlopen
OUT=Path(__file__).resolve().parent;STATE=Path.home()/'.local/share/trinity-local-nodes/n5';src=STATE/'frontend.py'
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
def start(port,log):
 with log.open('ab') as f:return subprocess.Popen([sys.executable,str(src),'--port',str(port)],stdin=subprocess.DEVNULL,stdout=f,stderr=f,start_new_session=True)
def ready(port,proc):
 for _ in range(100):
  if proc.poll() is not None:raise RuntimeError('frontend exited')
  try:
   with urlopen(f'http://127.0.0.1:{port}/version',timeout=.4) as r:v=json.load(r)
   assert v['trealla']=='3.14.10'
   with urlopen(f'http://127.0.0.1:{port}/portal',timeout=3) as r:body=r.read();assert r.status==200 and b'Web Prolog' in body
   return dict(version=v,portal_bytes=len(body))
  except Exception:time.sleep(.1)
 raise RuntimeError('frontend readiness timed out')
p=start(port,OUT/'frontend-preflight.log')
try:preflight=ready(port,p)
finally:p.terminate();p.wait(timeout=5)
command=subprocess.check_output(['ps','-p','42134','-o','command='],text=True);assert '/tmp/web-prolog-local-ui/n5_frontend.py' in command
os.kill(42134,signal.SIGTERM)
for _ in range(50):
 try:os.kill(42134,0)
 except ProcessLookupError:break
 time.sleep(.1)
else:raise RuntimeError('old frontend did not stop')
p=start(3060,STATE/'frontend.log');(STATE/'frontend.pid').write_text(str(p.pid)+'\n');result=ready(3060,p)
shutil.copy2(src,OUT/'frontend.py')
(OUT/'frontend-restart.json').write_text(json.dumps(dict(old_pid=42134,new_pid=p.pid,original_script_missing=True,reconstruction_basis='Existing acceptance UI proxy, same asset/API split, durable path and explicit version/health routes',preflight=preflight,after=result),indent=2)+'\n')
print('n5 public frontend ready',p.pid,result)
