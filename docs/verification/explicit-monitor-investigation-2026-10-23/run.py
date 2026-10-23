"""Ten fresh-process lifecycle prefixes and ten isolated controls."""
from pathlib import Path
import os,subprocess,signal,json,time,re
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2]
EXE=str(Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl')
names=re.findall(r'^test\((\w+)',(ROOT/'tests/tiers/node/cross_node_lifecycle_tests.plt').read_text(),re.M)
names=names[:names.index('explicit_monitor_2_carries_user_ref')+1]
selections={'prefix':'['+','.join('cross_node_lifecycle:'+n for n in names)+']','alone':'cross_node_lifecycle:explicit_monitor_2_carries_user_ref'}
results=[]
for i in range(1,11):
 for label,selection in selections.items():
  tag=f'{label}-{i:02}';env=dict(os.environ,WP_LIFECYCLE_DIAGNOSTICS='1',WP_LIFECYCLE_LOG=str(OUT/(tag+'.events')))
  cmd=[EXE,'-q','-s','tests/tiers/t4_node.pl','-g','plunit_cross_node_lifecycle:enable_lifecycle_diagnostics,run_tests('+selection+')','-t','halt']
  t=time.monotonic()
  with (OUT/(tag+'.log')).open('w') as log:
   p=subprocess.Popen(cmd,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   try:rc=p.wait(timeout=90)
   except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='external_timeout'
  results.append(dict(batch=label,trial=i,exit_code=rc,seconds=round(time.monotonic()-t,3),command=cmd))
  (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(tag,rc,flush=True)
