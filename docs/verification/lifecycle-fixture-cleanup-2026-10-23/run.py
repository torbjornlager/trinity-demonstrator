"""Deterministic red control and full T4; private engine and temporary snapshot."""
from pathlib import Path
import subprocess,os,signal,time,json,hashlib,shutil
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2]
EXE=str(Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl')
BASE=Path.home()/'.local/share/trinity-runtime-tests/lifecycle-fixture-cleanup-2026-10-23'
BASE.mkdir();archive=BASE/'head.tar';subprocess.run(['git','archive','-o',str(archive),'HEAD'],cwd=ROOT,check=True)
RED=BASE/'red';RED.mkdir();subprocess.run(['tar','-xf',str(archive),'-C',str(RED)],check=True)
TEST=Path('tests/tiers/node/cross_node_lifecycle_tests.plt');text=(ROOT/TEST).read_text()
a=text.index('cleanup_lifecycle_monitors(Token) :-');b=text.index('\nflush_lifecycle_down(',a)
(RED/TEST).write_text(text[:a]+'cleanup_lifecycle_monitors(_Token) :- lifecycle_control_before_cleanup.\n'+text[b:])
results=[]
def run(label,goal,cwd=ROOT,diag=False,timeout=180):
 cmd=[EXE,'-q','-s','tests/tiers/t4_node.pl','-g',goal,'-t','halt'];env=dict(os.environ)
 if diag:env.update(WP_LIFECYCLE_DIAGNOSTICS='1',WP_LIFECYCLE_LOG=str(OUT/(label+'.events')))
 start=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='external_timeout'
 results.append(dict(label=label,command=cmd,cwd=str(cwd),exit_code=rc,seconds=round(time.monotonic()-start,3),test_sha256=hashlib.sha256((cwd/TEST).read_bytes()).hexdigest()))
 (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(label,rc,flush=True);return rc
run('red-control','run_tests(cross_node_lifecycle:late_previous_fixture_notification_is_retired)',cwd=RED,diag=True,timeout=20)
rc=run('final-focused','run_tests([cross_node_lifecycle:late_previous_fixture_notification_is_retired,cross_node_lifecycle:fixture_cleanup_preserves_other_watchers_and_messages])',diag=True,timeout=20)
if rc==0:run('t4','run_tier')
