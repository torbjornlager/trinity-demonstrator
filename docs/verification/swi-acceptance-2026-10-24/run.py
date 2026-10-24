"""Bounded SWI acceptance; no live-node or existing installed-runtime changes."""
from pathlib import Path
import os,subprocess,json,time,signal,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2];NATIVE=ROOT.parent/'swi-prolog-node'
BASE=Path.home()/'.local/share/trinity-runtime-tests';NEW=BASE/'swipl-09b6299-pcre-2026-10-23';BUILD=NEW/'build';PREFIX=NEW/'install';EXE=PREFIX/'bin/swipl';TOOLS=BASE/'swipl-09b6299/build-tools/bin'
NODE=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin'
ENV=dict(os.environ,PATH=str(TOOLS)+os.pathsep+str(NODE)+os.pathsep+os.environ['PATH'])
for k in ['SWI_HOME_DIR','SWIPL_HOME_DIR','SWIPL_PACK_PATH','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR']:ENV.pop(k,None)
ROWS=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tree(p):return {str(f.relative_to(p)):sha(f)for f in p.rglob('*')if f.is_file()}
def snapshot():
 binaries=[Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl'),ROOT.parent/'trealla-port/.build/trealla-v3.14.10/tpl',ROOT.parent/'trealla-port/.build/trealla-v3.13.10/tpl',BUILD/'src/swipl',BUILD/'src/libswipl.10.1.18.dylib',BUILD/'CMakeCache.txt']
 files={}
 for repo in [ROOT,NATIVE]:
  for rel in subprocess.check_output(['git','ls-files'],cwd=repo,text=True).splitlines():
   p=repo/rel
   if p.is_file()and(p.suffix in ['.pl','.sh']or p.name=='pack.pl'):files[str(p)]=sha(p)
 return {'binary_sha256':{str(p):sha(p)for p in binaries},'source_sha256':files,'trealla_library_sha256':tree(ROOT.parent/'trealla-port/.build/trealla-v3.14.10/library'),'live_processes':subprocess.check_output(['ps','-p','55051,42134,97896,97669','-o','pid=,command='],text=True),'engine_revision':subprocess.check_output(['git','-C',str(NEW/'source'),'rev-parse','HEAD'],text=True).strip(),'engine_source_status':subprocess.check_output(['git','-C',str(NEW/'source'),'status','--short','--untracked-files=no'],text=True)}
def run(label,cmd,cwd=ROOT,timeout=300,env=None):
 start=time.monotonic();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w')as log:
  p=subprocess.Popen([str(x)for x in cmd],cwd=cwd,env=env or ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 row={'label':label,'command':list(map(str,cmd)),'cwd':str(cwd),'exit_code':rc,'seconds':round(time.monotonic()-start,3),'outer_watchdog_seconds':timeout};ROWS.append(row);(OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print('DONE',label,rc,row['seconds'],flush=True);return rc
BEFORE=snapshot();(OUT/'before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
assert BEFORE['engine_revision']=='09b6299f696574c9230f23e53b1ab041a942b6f3'
assert not PREFIX.exists(),'Refuse to overwrite any existing prefix'
assert run('stage-install',[TOOLS/'cmake','--install',BUILD],timeout=180)==0
assert EXE.exists();ENV['SWIPL']=str(EXE)
run('installed-runtime-probe',[EXE,'-f','none','-q','-s',OUT/'runtime-probe.pl','-g','runtime_acceptance_probe:run','-t','halt'],cwd=OUT)
run('upstream-ctest',[TOOLS/'ctest','--test-dir',BUILD,'--output-on-failure','-j','2'],timeout=900)
for label in ['LINT','T0','T1_NATIVE','T2','T3_NATIVE','T4_NATIVE','T5']:
 run(label,['bash','tools/test.sh',label],cwd=NATIVE)
for label in ['T1_INTEGRATION','T3_INTEGRATION','T4_INTEGRATION']:
 env=dict(ENV,WP_ASSET_ROOT=str(ROOT),WP_WASM_SOURCE_DIR=str(ROOT/'prolog/web_prolog/wasm'))
 run(label,['bash','tools/test.sh',label],cwd=NATIVE,env=env)
run('T4_LEGACY_LAYOUT',['bash','tools/test.sh','T4_LEGACY_LAYOUT'])
for i in range(1,11):
 run(f'callback-{i:02}',[EXE,'-f','none','-q','-s','tests/tiers/t4_node.pl','-g','run_tests(node:isobase_yield_timeout_callback_is_sandboxed)','-t','halt'],cwd=NATIVE,timeout=30)
 run(f'supervisor-{i:02}',[EXE,'-f','none','-q','-s','tests/tiers/t4_node.pl','-g','run_tests(supervisor_restart:automatic_failure_respects_numeric_and_brutal_shutdown)','-t','halt'],cwd=NATIVE,timeout=30)
AFTER=snapshot();AFTER['unchanged_from_batch_start']={k:AFTER[k]==BEFORE[k]for k in BEFORE};(OUT/'after.json').write_text(json.dumps(AFTER,indent=2)+'\n')
(OUT/'installed-manifest.json').write_text(json.dumps(tree(PREFIX),indent=2)+'\n')
print('COMPLETE',len(ROWS),'failed',[r['label']for r in ROWS if r['exit_code']!=0],flush=True)
