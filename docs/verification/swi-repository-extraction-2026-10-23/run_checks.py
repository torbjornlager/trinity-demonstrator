import json,os,signal,subprocess,time
from pathlib import Path
source=Path('/Users/torbjorn.lager/Documents/GitHub/trinity-demonstrator')
native=source.parent/'swi-prolog-node'
work=Path(__file__).resolve().parent
out=source/'docs/verification/swi-repository-extraction-2026-10-23'
exe='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
results=[]
env=dict(os.environ,SWIPL=exe)
for name in ['WP_ASSET_ROOT','WP_WASM_SOURCE_DIR']:env.pop(name,None)
def run(label,command,cwd,external=False,timeout=300):
    e=dict(env)
    if external:e.update(WP_ASSET_ROOT=str(source),WP_WASM_SOURCE_DIR=str(work/'browser-prolog'))
    start=time.monotonic();print('START',label,flush=True)
    with (out/(label+'.log')).open('w') as f:
        p=subprocess.Popen(command,cwd=cwd,env=e,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        try:rc=p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
    results.append(dict(label=label,command=command,cwd=str(cwd),external_assets=external,exit_code=rc,seconds=round(time.monotonic()-start,3)))
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('DONE',label,rc,flush=True)
for label in ['LINT','T0','T1_NATIVE','T2','T3_NATIVE','T4_NATIVE','T5']:
    run(label,['bash','tools/test.sh',label],native)
for label in ['T1_INTEGRATION','T3_INTEGRATION','T4_INTEGRATION']:
    run(label,['bash','tools/test.sh',label],native,external=True)
run('T4_LEGACY_LAYOUT',['bash','tools/test.sh','T4_LEGACY_LAYOUT'],source)
run('WASM',['bash','tools/test.sh','WASM'],source)
run('cross-repository-equivalence',['python3','tools/check_statechart_wasm_equivalence.py','--native-root',str(native),'--wasm-dir',str(work/'browser-prolog')],source)
# SWI pack registration is local to this process, with no installed pack mutation.
foreign=work/'foreign-cwd';foreign.mkdir(exist_ok=True)
goal=f"use_module(library(prolog_pack)),pack_attach('{native}',[]),use_module(library(web_prolog)),module_property(actors,file(F)),assertion(same_file(F,'{native}/prolog/web_prolog/actors.pl')),node_version:web_prolog_version(V),assertion(V=='0.2.0'),writeln(pack_attachment_verified)"
run('pack-attachment',[exe,'-q','-g',goal,'-t','halt'],foreign)
raise SystemExit(0 if all(r['exit_code']==0 for r in results) else 1)
