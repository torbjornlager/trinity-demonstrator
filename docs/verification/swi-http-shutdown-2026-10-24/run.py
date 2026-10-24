from pathlib import Path
import os,subprocess,json,time,signal,shutil,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2];NATIVE=ROOT.parent/'swi-prolog-node';BASE=Path.home()/'.local/share/trinity-runtime-tests/swipl-http-shutdown-2026-10-24';OLD=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23';EXE=BASE/'install/bin/swipl';ROWS=[]
ENV=dict(os.environ,SWIPL=str(EXE))
for key in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR']: ENV.pop(key,None)
def run(label,cmd,cwd=NATIVE,timeout=30):
 start=time.monotonic()
 with (OUT/(label+'.log')).open('w') as log:
  proc=subprocess.Popen([str(x) for x in cmd],cwd=cwd,env=ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=proc.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait();rc='watchdog_timeout'
 row={'label':label,'command':list(map(str,cmd)),'cwd':str(cwd),'exit_code':rc,'seconds':round(time.monotonic()-start,3),'outer_watchdog_seconds':timeout};ROWS.append(row);(OUT/'results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print(label,rc,row['seconds'],flush=True)
def prolog(label,source,goal,exe=EXE,timeout=30):run(label,[exe,'-f','none','-q','-s',source,'-g',goal,'-t','halt'],timeout=timeout)
shutil.copyfile(OUT/'test_thread_httpd.pl',BASE/'http-source/test_thread_httpd.pl')
# Controlled negative control: original scheduling-hook regression must stall.
prolog('baseline-gated',ROOT/'docs/verification/swi-callback-stall-2026-10-24/http-stop-gated.pl','http_stop_gated:run',exe=OLD/'install/bin/swipl')
for i in range(1,21):prolog(f'regression-{i:02}',OUT/'test_thread_httpd.pl','test_thread_httpd')
for i in range(1,31):prolog(f'callback-{i:02}','tests/tiers/t4_node.pl','run_tests(node:isobase_yield_timeout_callback_is_sandboxed)')
checks='run_tests([native_paging,node:call_cache_eviction_stops_evicted_actor,node:rpc_cut_reclaims_cached_continuation_after_ttl,node:call_cache_is_isolated_per_node])'
for i in range(1,6):prolog(f'http-cleanup-{i:02}','tests/tiers/t4_node.pl',checks,timeout=60)
for name in ['http','cgi_stream','multipart','proxy','websocket','graphql','sse']:
 prolog('upstream-'+name,BASE/f'http-source/test_{name}.pl','test_'+name,timeout=90)
run('T4_NATIVE',['bash','tools/test.sh','T4_NATIVE'],timeout=300)
before=json.loads((OUT/'before.json').read_text());current={}
for key in ['source_sha256','binary_sha256']:
 current[key]={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in before[key]}
current['live_processes']=subprocess.check_output(['ps','-p','55051,42134,97896,97669','-o','pid=,command='],text=True)
current['unchanged_from_start']={key:current[key]==before[key] for key in ['source_sha256','binary_sha256','live_processes']}
manifest=json.loads((ROOT/'docs/verification/swi-acceptance-2026-10-24/installed-manifest.json').read_text());current['original_staged_prefix_changed']=[rel for rel,h in manifest.items() if hashlib.sha256((OLD/'install'/rel).read_bytes()).hexdigest()!=h]
(OUT/'after.json').write_text(json.dumps(current,indent=2)+'\n'); print('COMPLETE',flush=True)
