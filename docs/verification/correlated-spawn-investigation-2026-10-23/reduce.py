"""Fresh-process two-test controls, with fail-port diagnostics only."""
from pathlib import Path
import subprocess,os,json,time
OUT=Path(__file__).resolve().parent
BASE=Path.home()/'.local/share/trinity-runtime-tests/correlated-spawn-2026-10-23'
EXE=str(Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl')
trace="use_module(library(prolog_trace)),trace(websocket:ws_close(S,C,D),fail((test_toplevel_correlation_transport:spawn_diag(ws_close_failed(S,C,D)),fail))),trace(distribution:remote_drop_connection_locked(N),fail((test_toplevel_correlation_transport:spawn_diag(drop_locked_failed(N)),fail)))"
units='[toplevel_correlation_transport:spawn_errors_isolated_on_negotiated_connection,toplevel_correlation_transport:matching_startup_failure_and_legacy_fallback]'
results=[]
for i in range(1,4):
 for name in ['baseline','assets']:
  label=f'pair-{name}-{i:02}'
  env=dict(os.environ,WP_SPAWN_TEST_DIAGNOSTICS='1',WP_SPAWN_TEST_LOG=str(OUT/(label+'.events')))
  cmd=[EXE,'-q','-s','tests/tiers/t4_node.pl','-g',trace+',run_tests('+units+')','-t','halt']
  t=time.monotonic()
  with (OUT/(label+'.log')).open('w') as log:
   r=subprocess.run(cmd,cwd=BASE/name,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=60)
  results.append(dict(version=name,trial=i,exit_code=r.returncode,seconds=round(time.monotonic()-t,3),command=cmd))
  print(label,r.returncode,flush=True)
(OUT/'pair-results.json').write_text(json.dumps(results,indent=2)+'\n')
