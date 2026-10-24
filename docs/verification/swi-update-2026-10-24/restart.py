from pathlib import Path
import subprocess,os,signal,time,json,urllib.request
ROOT=Path('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator');OUT=Path(__file__).resolve().parent;DURABLE=Path.home()/'.local/share/trinity-local-nodes/n3';old_pid=55051
assert 'start_local_node_reuse.pl -- n3' in subprocess.check_output(['ps','-p',str(old_pid),'-o','command='],text=True)
os.kill(old_pid,signal.SIGTERM)
for _ in range(100):
 try:os.kill(old_pid,0)
 except ProcessLookupError:break
 time.sleep(.1)
else:raise RuntimeError('Original n3 has not stopped; no replacement started')
log=(DURABLE/'n3.log').open('ab',buffering=0);p=subprocess.Popen([str(DURABLE/'start.sh')],cwd=ROOT,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True);(DURABLE/'n3.pid').write_text(str(p.pid)+'\n')
record={'old_pid':old_pid,'new_pid':p.pid,'launcher':str(DURABLE/'start.sh'),'runtime':str((Path.home()/'.local/share/trinity-runtimes/swi-current').resolve()),'log':str(DURABLE/'n3.log')};(OUT/'restart.json').write_text(json.dumps(record,indent=2)+'\n')
for _ in range(100):
 if p.poll() is not None:raise RuntimeError('Candidate n3 exited; inspect durable log and use rollback launcher')
 try:
  with urllib.request.urlopen('http://localhost:3053/admin/config',timeout=.3) as r:config=json.load(r)
  break
 except Exception:time.sleep(.1)
else:raise RuntimeError('Candidate readiness timeout')
before=json.loads((OUT/'before-admin-config.json').read_text());assert config==before,'Configuration mismatch';(OUT/'after-admin-config.json').write_text(json.dumps(config,indent=2)+'\n');print(json.dumps(record));print('n3 ready; admin configuration identical')
