from pathlib import Path
import urllib.request,urllib.parse,json,time,subprocess,os
OUT=Path(__file__).resolve().parent;ROWS=[]
def call(label,goal,expected='success',**options):
 params=dict(goal=goal,limit=10,format='json',**options);url='http://localhost:51857/call?'+urllib.parse.urlencode(params);start=time.monotonic()
 if label in ['worker-combinators','worker-cleanup','synchronous-toplevel','supervisor','statechart-text','statechart-uri']:
  exe='/Users/torbjorn.lager/.local/share/trinity-runtime-tests/swi-default-startup-2026-10-24/runtime/bin/swipl'
  proc=subprocess.run([str(exe),'-f','none','-q','-s',str(OUT/'legacy-ws-smoke.pl'),'-g','ws_smoke:run','-t','halt'],env=dict(os.environ,WS_SMOKE_GOAL=goal),capture_output=True,text=True,timeout=25)
  (OUT/(label+'-legacy-client.log')).write_text(proc.stdout+'\nSTDERR\n'+proc.stderr);assert proc.returncode==0,proc.stderr
  answer=json.loads(proc.stdout)
 else:
  with urllib.request.urlopen(url,timeout=20) as r:answer=json.load(r)
 row={'label':label,'goal':goal,'options':options,'answer':answer,'seconds':round(time.monotonic()-start,3),'passed':answer.get('type')==expected and (expected!='success' or bool(answer.get('data')))};ROWS.append(row);(OUT/'legacy-smoke-results.json').write_text(json.dumps(ROWS,indent=2,ensure_ascii=False)+'\n');print(label,row['passed'],json.dumps(answer,ensure_ascii=False));assert row['passed']
call('runtime','runtime_property(implementation(swi_native)),runtime_property(actor_isolation(native_thread))')
call('shared-database','authorized(alice),owns(alice,Printer),online(Printer)')
call('unicode',"member(X,['räksmörgås','日本語'])")
call('private-source','private_smoke(ok)',src_text='private_smoke(ok).')
call('private-source-isolation','private_smoke(ok)',expected='error')
call('worker-combinators','parallel([(sleep(0.02),X=slow),Y=fast]),X==slow,Y==fast,first_solution(Z,[(sleep(0.1),Z=slow),Z=fast]),Z==fast')
call('worker-cleanup','actors(B),catch(parallel([receive({never->true}),throw(smoke_error)]),E,true),E==smoke_error,actors(A),sort(B,S),sort(A,S)')
call('synchronous-toplevel',"setup_call_cleanup(toplevel_spawn(P,[src_text('mortal(socrates). mortal(plato).')]),(toplevel_call_synch(P,mortal(X),A,[template(X),limit(1)]),A=success(P,[socrates],true),toplevel_next_synch(P,B),B=success(P,[plato],false)),toplevel_halt(P))")
call('supervisor','setup_call_cleanup(supervisor_spawn([],S),supervisor_count_children(S,[specs-0,active-0,supervisors-0,workers-0]),supervisor_halt(S))')
call('statechart-text',"statechart_spawn(P,[src_text('<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"/></statechart>'),monitor(true)]),statechart_halt(P,true),receive({down(P,P,_)->true},[timeout(2)])")
call('statechart-uri',"statechart_spawn(P,[src_uri('http://localhost:51857/examples/statecharts/01%20pause-and-resume.xml'),monitor(true)]),statechart_halt(P,true),receive({down(P,P,_)->true},[timeout(2)])")
call('promise-timeout-retry',"promise('http://localhost:51857',(sleep(0.2),X=ok),R,[template(X)]),yield(R,E,[timeout(0),on_timeout(E=waiting)]),E==waiting,yield(R,A),A=success([ok],false),var(X)")
call('sandbox','nb_getval(secret,_)',expected='error')
print('COMPLETE',len(ROWS))
