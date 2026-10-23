import os,subprocess,json,time,signal
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2]
NODE='/Users/torbjorn.lager/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node'
SWIPL='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
ENV=dict(os.environ,SWIPL=SWIPL,PATH=str(Path(NODE).parent)+':'+os.environ['PATH']);results=[]
for label,cmd,limit in [('rpc-bridge-smoke',[NODE,'tests/wasm/swi_wasm_rpc_bridge_smoke.js'],60),('wasm-tier',['bash','tools/test.sh','WASM'],600)]:
 start=time.time();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen(cmd,cwd=ROOT,env=ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=limit)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 results.append(dict(label=label,command=cmd,SWIPL=SWIPL,NODE=NODE,exit_code=rc,seconds=round(time.time()-start,3)))
 (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('END',label,rc,flush=True)
