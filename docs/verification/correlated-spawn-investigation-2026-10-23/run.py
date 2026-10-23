"""Three fresh-process T4 prefixes per version; diagnostics only."""
from pathlib import Path
import os,json,subprocess,shutil,signal,time,hashlib
ROOT=Path(__file__).resolve().parents[3];OUT=Path(__file__).resolve().parent
BASE=Path.home()/'.local/share/trinity-runtime-tests/correlated-spawn-2026-10-23'
SWI=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl'
TEST=Path('tests/tiers/node/toplevel_correlation_transport_tests.pl')
if BASE.exists(): raise SystemExit('Preserve the existing snapshots; choose a new BASE before rerunning.')
BASE.mkdir(parents=True)
archive=BASE/'committed.tar'
subprocess.run(['git','archive','--format=tar','-o',str(archive),'HEAD'],cwd=ROOT,check=True)
patch=BASE/'working-tree.patch'
patch.write_bytes(subprocess.check_output(['git','diff','--binary','HEAD'],cwd=ROOT))
for name in ['baseline','assets']:
 dst=BASE/name;dst.mkdir();subprocess.run(['tar','-xf',str(archive),'-C',str(dst)],check=True)
 if name=='assets':
  subprocess.run(['git','apply',str(patch)],cwd=dst,check=True)
  for file in ['prolog/web_prolog/node_assets.pl','tests/tiers/node/node_assets_tests.pl']:
   shutil.copy2(ROOT/file,dst/file)
 shutil.copy2(ROOT/TEST,dst/TEST)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
(OUT/'snapshots.json').write_text(json.dumps(dict(base=str(BASE),baseline_revision=json.loads((OUT/'before.json').read_text())['revision'],engine=dict(path=str(SWI),sha256=sha(SWI)),diagnostic_test_sha256=sha(ROOT/TEST),snapshot_test_sha256={n:sha(BASE/n/TEST) for n in ['baseline','assets']},patch_sha256=sha(patch)),indent=2)+'\n')
units='[lifetime_authority,node,public_goal_guard,sandbox_source_names,promise_yield,promise_lifecycle,promise_ownership,rpc_options,native_paging,toplevel_synch,toplevel_correlation_transport]'
cmd=[str(SWI),'-q','-s','tests/tiers/t4_node.pl','-g',f'layer_honesty,run_tests({units})','-t','halt']
results=[]
for i in range(1,4):
 for name in ['baseline','assets']:
  label=f'{name}-{i:02}';events=OUT/(label+'.events');events.write_text('')
  env=dict(os.environ,WP_SPAWN_TEST_DIAGNOSTICS='1',WP_SPAWN_TEST_LOG=str(events))
  env.pop('WP_ASSET_ROOT',None);env.pop('WP_WASM_SOURCE_DIR',None)
  start=time.monotonic();print('START',label,flush=True)
  with (OUT/(label+'.log')).open('w') as log:
   p=subprocess.Popen(cmd,cwd=BASE/name,env=env,stdout=log,stderr=log,start_new_session=True)
   try:rc=p.wait(timeout=180)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
  results.append(dict(version=name,trial=i,command=cmd,cwd=str(BASE/name),exit_code=rc,seconds=round(time.monotonic()-start,3),events=events.name,log=label+'.log'))
  (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n');print('DONE',label,rc,flush=True)
print('FINISHED',len(results),flush=True)
