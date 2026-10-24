from pathlib import Path
import os,subprocess,json,time,signal,hashlib
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2];NATIVE=ROOT.parent/'swi-prolog-node';BASE=Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23';EXE=BASE/'install/bin/swipl'
ROWS=[]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def snapshot():
 source={}
 for repo in [ROOT,NATIVE]:
  for rel in subprocess.check_output(['git','ls-files'],cwd=repo,text=True).splitlines():
   p=repo/rel
   if p.is_file()and p.suffix in ['.pl','.sh']:source[str(p)]=sha(p)
 binaries=[Path('/Applications/swipl-win.app/Contents/MacOS/swipl'),Path('/Library/Frameworks/swipl.framework/Versions/A/swipl'),ROOT.parent/'trealla-port/.build/trealla-v3.14.10/tpl',ROOT.parent/'trealla-port/.build/trealla-v3.13.10/tpl',EXE,BASE/'build/src/swipl']
 return {'source_sha256':source,'binary_sha256':{str(p):sha(p)for p in binaries},'live_processes':subprocess.check_output(['ps','-p','55051,42134,97896,97669','-o','pid=,command='],text=True)}
BEFORE=snapshot();(OUT/'gated-before.json').write_text(json.dumps(BEFORE,indent=2)+'\n')
env=dict(os.environ)
for k in ['SWI_HOME_DIR','SWIPL_HOME_DIR','WP_ASSET_ROOT','WP_WASM_SOURCE_DIR']:env.pop(k,None)
for i in range(1,2):
 label=f'gated-{i:02}';goal='http_stop_gated:run';cmd=[str(EXE),'-f','none','-q','-s',str(OUT/'http-stop-gated.pl'),'-g',goal,'-t','halt'];start=time.monotonic();samples=[]
 with (OUT/(label+'.log')).open('w')as log:
  p=subprocess.Popen(cmd,cwd=NATIVE,env=env,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=3)
  except subprocess.TimeoutExpired:
   sample_cmd=['sample',str(p.pid),'1','-file',str(OUT/(label+'-sample.txt'))]
   sample_start=time.monotonic()
   r=subprocess.run(sample_cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=5);(OUT/(label+'-sample-command.log')).write_text(r.stdout);samples.append({'command':sample_cmd,'exit_code':r.returncode})
   try:rc=p.wait(timeout=max(.01,30-(time.monotonic()-start)))
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 row={'trial':i,'command':cmd,'cwd':str(NATIVE),'exit_code':rc,'seconds':round(time.monotonic()-start,3),'samples':samples};ROWS.append(row);(OUT/'gated-results.json').write_text(json.dumps(ROWS,indent=2)+'\n');print(label,rc,row['seconds'],flush=True)
AFTER=snapshot();AFTER['unchanged_from_batch_start']={k:AFTER[k]==BEFORE[k]for k in BEFORE};(OUT/'gated-after.json').write_text(json.dumps(AFTER,indent=2)+'\n');print('COMPLETE','failed',[r['trial']for r in ROWS if r['exit_code']!=0],flush=True)
