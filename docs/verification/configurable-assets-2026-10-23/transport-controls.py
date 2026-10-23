"""Bounded diagnostics only: compare existing transport tests with committed base."""
from pathlib import Path
import json,os,subprocess,signal,time,tempfile
ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).resolve().parent
SWI=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
env=dict(os.environ,SWIPL=str(SWI));env.pop('WP_ASSET_ROOT',None);env.pop('WP_WASM_SOURCE_DIR',None)
results=[]
def run(label,cmd,cwd,limit):
 start=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=limit)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 results.append(dict(label=label,command=cmd,cwd=str(cwd),exit_code=rc,seconds=round(time.monotonic()-start,3)))
 (OUT/'transport-control-results.json').write_text(json.dumps(results,indent=2)+'\n');print(label,rc,flush=True)
with tempfile.TemporaryDirectory(prefix='swi-asset-baseline-') as tmp:
 baseline=Path(tmp)/'checkout';baseline.mkdir();archive=Path(tmp)/'base.tar'
 subprocess.run(['git','archive','--format=tar','-o',str(archive),'HEAD'],cwd=ROOT,check=True)
 subprocess.run(['tar','-xf',str(archive),'-C',str(baseline)],check=True)
 goal='run_tests([toplevel_correlation_transport:matching_startup_failure_and_legacy_fallback,cross_node_lifecycle:explicit_monitor_2_carries_user_ref])'
 for i in range(1,11):
  for name,cwd in [('baseline',baseline),('changed',ROOT)]:
   run(f'transport-{name}-{i:02}',[str(SWI),'-q','-s','tests/tiers/t4_node.pl','-g',goal,'-t','halt'],cwd,30)
 run('t4-baseline',['bash','tools/test.sh','T4'],baseline,360)
 run('t4-repeat',['bash','tools/test.sh','T4'],ROOT,360)
