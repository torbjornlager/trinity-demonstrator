from pathlib import Path
import os,subprocess,json,signal,time,hashlib
ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).resolve().parent;NATIVE=ROOT.parent/'swi-prolog-node';WORK=Path.home()/'.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24';EXE=WORK/'runtime/bin/swipl';WASM=Path(__import__('json').loads((ROOT/'.trinity/native-swi.json').read_text())['wasm_root']);ROWS=[]
ENV=dict(os.environ,SWIPL=str(EXE));ENV['PATH']=str(Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin')+os.pathsep+ENV['PATH']
for key in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR']:ENV.pop(key,None)
def run(label,cmd,cwd=ROOT,env=None,timeout=300):
 start=time.monotonic();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen([str(x) for x in cmd],cwd=cwd,env=env or ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 row={'label':label,'command':list(map(str,cmd)),'cwd':str(cwd),'exit_code':rc,'seconds':round(time.monotonic()-start,3),'outer_watchdog_seconds':timeout};ROWS.append(row);(OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print('DONE',label,rc,row['seconds'],flush=True)
run('default-startup-regressions',['python3','tests/test_default_swi_startup.py'],env=dict(ENV,STARTUP_TEST_SWIPL=str(EXE)))
run('pin-negative-regressions',['python3','tests/test_pinned_swi_dependency.py'])
run('existing-extraction-regressions',['python3','tests/test_swi_extraction_tools.py'])
for tier in ['LINT','T0','T1_NATIVE','T2','T3_NATIVE','T4_NATIVE','T5']:run(tier,['bash','tools/test.sh',tier],cwd=NATIVE)
for tier in ['T1_INTEGRATION','T3_INTEGRATION','T4_INTEGRATION']:run(tier,['bash','tools/test.sh',tier],cwd=NATIVE,env=dict(ENV,WP_ASSET_ROOT=str(ROOT),WP_WASM_SOURCE_DIR=str(WASM)))
run('T4_LEGACY_LAYOUT',['bash','tools/test.sh','T4_LEGACY_LAYOUT'],env=dict(ENV,WP_NATIVE_MODE='legacy'))
run('T4-original-legacy',['bash','tools/test.sh','T4'],env=dict(ENV,WP_NATIVE_MODE='legacy'))
run('WASM',['bash','tools/test.sh','WASM'])
run('cross-repository-equivalence',['python3','tools/check_statechart_wasm_equivalence.py','--native-root',NATIVE,'--wasm-dir',WASM])
origins=OUT/'origins.json'
goal="pinned_swi_bootstrap:check_origins,findall(_{module:M,file:F},module_property(M,file(F)),Rows),setup_call_cleanup(open("+repr(str(origins))+",write,S),json_write_dict(S,Rows,[]),close(S))"
run('default-loader-origin',[EXE,'-f','none','-q','-s',ROOT/'load.pl','-p','library='+str(ROOT/'prolog'),'-g',goal,'-t','halt'],cwd=WORK)
print('COMPLETE; failed',[r['label'] for r in ROWS if r['exit_code']!=0],flush=True)
