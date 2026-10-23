"""Verify configurable assets using the separate SWI candidate, not live nodes."""
from pathlib import Path
import json,os,signal,subprocess,time
ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
SWI=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
NODE=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'
env=dict(os.environ,SWIPL=str(SWI),PATH=str(NODE.parent)+os.pathsep+os.environ['PATH'])
# The default-layout checks must not inherit operator overrides from the shell.
env.pop('WP_ASSET_ROOT',None);env.pop('WP_WASM_SOURCE_DIR',None)
cases=[('focused',[str(SWI),'-q','-s','tests/tiers/node/node_assets_tests.pl','-g','run_tests(node_assets)','-t','halt'],60),
       ('lint',['bash','tools/test.sh','LINT'],60),
       ('t4',['bash','tools/test.sh','T4'],360),
       ('wasm',['bash','tools/test.sh','WASM'],360)]
results=[]
for label,cmd,timeout in cases:
 print('START',label,flush=True);start=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=log,start_new_session=True)
  try: rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 results.append(dict(label=label,command=cmd,exit_code=rc,seconds=round(time.monotonic()-start,3)))
 (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('DONE',label,rc,flush=True)
