import json,os,signal,subprocess,time
from pathlib import Path
source=Path('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator')
native=source.parent/'swi-prolog-node'
out=source/'docs/verification/swi-repository-extraction-2026-10-23'
exe='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
results=[]
env=dict(os.environ,SWIPL=exe)
for name in ['WP_ASSET_ROOT','WP_WASM_SOURCE_DIR']:env.pop(name,None)
def run(label,goal,cwd,timeout):
    cmd=[exe,'-q','-s','tests/tiers/t4_node.pl','-g',goal,'-t','halt'];start=time.monotonic()
    print('START',label,flush=True)
    with (out/(label+'.log')).open('w') as f:
        p=subprocess.Popen(cmd,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        try:rc=p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
    results.append(dict(label=label,command=cmd,cwd=str(cwd),exit_code=rc,seconds=round(time.monotonic()-start,3)))
    (out/'control-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('DONE',label,rc,flush=True)
run('T4-native-fresh-control','run_native',native,120)
run('callback-original-control','run_tests(node:isobase_yield_timeout_callback_is_sandboxed)',source,30)
run('callback-native-control','run_tests(node:isobase_yield_timeout_callback_is_sandboxed)',native,30)
