"""Repeat the separate, explicitly controlled after-flush interleaving."""
from pathlib import Path
import os,subprocess,json
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2]
EXE=str(Path.home()/'.local/share/trinity-runtime-tests/swipl-09b6299-pcre-2026-10-23/build/src/swipl')
goal='plunit_cross_node_lifecycle:enable_lifecycle_diagnostics,setup_call_cleanup(plunit_cross_node_lifecycle:start_lifecycle_schedule_control,run_tests([cross_node_lifecycle:down_event_preserves_custom_exit_reason,cross_node_lifecycle:explicit_monitor_2_carries_user_ref]),plunit_cross_node_lifecycle:stop_lifecycle_schedule_control)'
cmd=[EXE,'-q','-s','tests/tiers/t4_node.pl','-g',goal,'-t','halt'];results=[]
for i in range(1,4):
 tag=f'schedule-{i:02}';env=dict(os.environ,WP_LIFECYCLE_DIAGNOSTICS='1',WP_LIFECYCLE_LOG=str(OUT/(tag+'.events')))
 with (OUT/(tag+'.log')).open('w') as log:r=subprocess.run(cmd,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=20)
 results.append(dict(trial=i,exit_code=r.returncode,expected_exit_code=1,command=cmd));print(tag,r.returncode,flush=True)
(OUT/'schedule-results.json').write_text(json.dumps(results,indent=2)+'\n')
