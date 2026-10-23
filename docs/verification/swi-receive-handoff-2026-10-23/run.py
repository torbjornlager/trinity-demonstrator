#!/usr/bin/env python3
"""Run the candidate only on the separate SWI build containing Jan's fix."""
import hashlib,json,os,signal,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
exe=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swipl-09b6299/build/src/swipl')
records={}
def run(label,cmd,limit=120,marker=None):
 start=time.monotonic();p=subprocess.Popen(cmd,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try:stdout,stderr=p.communicate(timeout=limit);expired=False
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGKILL);stdout,stderr=p.communicate();expired=True
 log=stdout+stderr
 (out/(label+'.log')).write_text(log)
 row=dict(command=cmd,exit_code=p.returncode,timeout=expired,seconds=round(time.monotonic()-start,3),passed=p.returncode==0 and not expired and (marker is None or marker in log))
 records[label]=row;(out/'results.json').write_text(json.dumps(records,indent=2)+'\n');print(label,row,flush=True)
 return row['passed']
run('t0',[str(exe),'-q','-s','tests/tiers/t0_actors.pl','-g','run_tier','-t','halt'])
run('t3',[str(exe),'-q','-s','tests/tiers/t3_behaviours.pl','-g','run_tier','-t','halt'])
run('node-worker-accounting',[str(exe),'-q','-s','tests/tiers/t4_node.pl','-g','run_tests([worker_scope,worker_ownership_cleanup,zero_poll_accounting]),actors:receive({Msg -> throw(error(unexpected_message_in_shell(Msg),_))},[timeout(0)])','-t','halt'])
run('worker-fixed-batch',[str(exe),'-q','-s','tests/tiers/t3_behaviours.pl','-g',"forall(between(1,30,_),(run_tests(worker_scope),ensure_mailbox_empty)),writeln(worker_batch_complete)",'-t','halt'],limit=120,marker='worker_batch_complete')
run('handoff-fixed-batch',[str(exe),'-q','-s','tests/tiers/receive_handoff_tests.pl','-g',"forall(between(1,10,_),run_tests(receive_handoff)),writeln(handoff_batch_complete)",'-t','halt'],limit=45,marker='handoff_batch_complete')
print('Summary',sum(r['passed'] for r in records.values()),'/',len(records),flush=True)
