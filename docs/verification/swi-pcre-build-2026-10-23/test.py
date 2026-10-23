import os,subprocess,json,time,signal
from pathlib import Path
OUT=Path(__file__).resolve().parent;ROOT=OUT.parents[2]
BASE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests');NEW=BASE/'swipl-09b6299-pcre-2026-10-23';EXE=NEW/'build/src/swipl'
ENV=dict(os.environ,SWIPL=str(EXE));results=[]
def run(label,cmd,cwd=ROOT,timeout=180,marker=None):
 start=time.time();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen([str(x) for x in cmd],cwd=cwd,env=ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 text=(OUT/(label+'.log')).read_text();passed=rc==0 and (marker is None or marker in text)
 r=dict(label=label,command=[str(x) for x in cmd],cwd=str(cwd),SWIPL=ENV['SWIPL'],exit_code=rc,passed=passed,seconds=round(time.time()-start,3));results.append(r)
 (OUT/'test-results.json').write_text(json.dumps(results,indent=2)+'\n');print('END',label,rc,passed,flush=True)
def prolog(label,file,goal,timeout=180,marker=None):run(label,[EXE,'-f','none','-q','-s',file,'-g',goal,'-t','halt'],timeout=timeout,marker=marker)
run('swipl-pcre',[BASE/'swipl-09b6299/build-tools/bin/ctest','--test-dir',NEW/'build','-R','^pcre:pcre$','--output-on-failure','--timeout','120'])
probe='use_module(library(pcre)),re_config(version(V)),re_config(jit(J)),re_config(unicode(U)),format(\'pcre_version(~q), jit(~q), unicode(~q).~n\',[V,J,U]),absolute_file_name(library(pcre),P,[file_type(prolog),access(read)]),format(\'pcre_library(~q).~n\',[P]),re_matchsub(\'(?<word>.+)\',\'räksmörgås\',D,[]),get_dict(word,D,"räksmörgås"),re_replace(\'[0-9]+\'/g,\'#\',\'pid=123 ref=456\',"pid=# ref=#"),writeln(pcre_unicode_and_replacement_ok),halt'
run('pcre-feature-probe',[EXE,'-f','none','-q','-g',probe],marker='pcre_unicode_and_replacement_ok')
prolog('t0','tests/tiers/t0_actors.pl','run_tier')
prolog('t3','tests/tiers/t3_behaviours.pl','run_tier')
prolog('t5','tests/tiers/t5_interop.pl','run_tier')
prolog('node-worker-accounting','tests/tiers/t4_node.pl',"run_tests([worker_scope,worker_ownership_cleanup,zero_poll_accounting]),actors:receive({Msg -> throw(error(unexpected_message_in_shell(Msg),_))},[timeout(0)])")
prolog('worker-fixed-batch','tests/tiers/t3_behaviours.pl',"forall(between(1,30,_),(run_tests(worker_scope),ensure_mailbox_empty)),writeln(worker_batch_complete)",marker='worker_batch_complete')
prolog('handoff-fixed-batch','tests/tiers/receive_handoff_tests.pl',"forall(between(1,10,_),run_tests(receive_handoff)),writeln(handoff_batch_complete)",marker='handoff_batch_complete')
print('FINISHED',sum(r['passed'] for r in results),'/',len(results),flush=True)
