from pathlib import Path
import sys,json,hashlib,subprocess
from urllib.request import urlopen
from urllib.parse import urlencode
sys.path[:0]=['/Users/torbjorn.lager/Documents/GitHub/trinity-conformance/runner','/Users/torbjorn.lager/Documents/GitHub/trinity-conformance/adapters']
import run as wire
from cyclic_boundaries import quote
OUT=Path(__file__).resolve().parent;rows=[]
def http(url,goal,template='Outcome',limit=1):
 params=dict(goal='('+goal+')',template='('+template+')',format='prolog',limit=str(limit))
 with urlopen(url+'/call?'+urlencode(params),timeout=12) as r:return r.read(16384).decode()
def check(label,fn,test):
 value=fn();passed=test(value);rows.append(dict(label=label,passed=passed,result=value));print(label,passed,flush=True)
 (OUT/'smoke.json').write_text(json.dumps(rows,indent=2)+'\n');assert passed,(label,value)
def ws_query(h,goal):
 h.call(goal,'[template(Outcome),format(prolog),limit(1)]')
 for _ in range(16):
  event=h.recv()
  if event.get('type')=='io_request':
   h.send({'command':'browser_io_reply','request_id':event['request_id'],'status':'ok'})
  if event.get('type') in ['success','failure','error']:return event
 raise RuntimeError('no terminal answer')
for name,url in [('n3','http://localhost:3053'),('n5','http://localhost:3060')]:
 check(name+' portal',lambda:urlopen(url+'/portal',timeout=8).read(900000).decode(),lambda s:'Web Prolog' in s)
 # Keep full HTML out of the stored smoke record.
 rows[-1]['result']='portal contains Web Prolog';(OUT/'smoke.json').write_text(json.dumps(rows,indent=2)+'\n')
 check(name+' implementation',lambda:http(url,'runtime_property(implementation(Outcome))'),lambda s:('swi_native' if name=='n3' else 'trealla_native') in s)
 check(name+' cyclic answer',lambda:http(url,'X=f(X)','X'),lambda s:'representation_error(cyclic_term)' in s)
 if name=='n3':check(name+' cyclic exception',lambda:http(url,'X=f(X),throw(error(probe(X),ctx))','X'),lambda s:'representation_error(cyclic_term)' in s)
 check(name+' local cycle finite result',lambda:http(url,'X=f(X),\\+acyclic_term(X),Outcome=ok'),lambda s:'success([ok],false)' in s)
 check(name+' shared database',lambda:http(url,'once((authorized(alice),owns(alice,P),online(P))),Outcome=ok'),lambda s:'success([ok],false)' in s)
 candidate=wire.Candidate(url.replace('http:','ws:')+'/ws','actor',10,None,url,False,())
 with wire.Harness(candidate) as h:
  h.spawn_shell()
  try:
   check(name+' websocket session',lambda:ws_query(h,'Outcome=ok'),lambda e:e.get('data')==['ok'])
   goal="toplevel_spawn(P,[session(true)]),toplevel_call_synch(P,member(X,[a,b,c]),A,[template(X),limit(1),timeout(2)]),toplevel_next_synch(P,B,[limit(2),timeout(2)]),toplevel_halt(P),A=success(P,[a],true),B=success(P,[b,c],false),Outcome=ok"
   check(name+' synchronous paging cleanup',lambda:ws_query(h,goal),lambda e:e.get('data')==['ok'])
   xml='<statechart version="0.2" initial="idle"><state id="idle"/></statechart>'
   expected_reply='true'
   goal='statechart_spawn(P,[src_text('+quote(xml)+'),trace(false),monitor(true)]),statechart_halt(P,Reply),receive({down(P,_,_) -> true},[timeout(2),on_timeout(throw(missing_chart_down))]),Reply=='+expected_reply+',Outcome=ok'
   check(name+' statechart monitor cleanup',lambda:ws_query(h,goal),lambda e:e.get('data')==['ok'])
  finally:h.halt()
for caller,url in [('n3','http://localhost:3053'),('n5','http://localhost:3060')]:
 for peer in ['http://localhost:3053','http://localhost:3060']:
  label=caller+' to '+peer
  check(label+' RPC paging',lambda:http(url,f'findall(X,rpc({quote(peer)},member(X,[a,b,c]),[limit(2)]),Xs),Xs=[a,b,c],Outcome=ok'),lambda s:'success([ok],false)' in s)
  goal=f'promise({quote(peer)},(sleep(0.2),X=pair(Y,Y)),Ref,[template(X),limit(1),once(true)]),yield(Ref,Early,[timeout(0),on_timeout(Early=waiting)]),Early==waiting,yield(Ref,success([pair(A,B)],false),[timeout(3)]),var(A),A==B,Outcome=ok'
  check(label+' promise callback retry sharing',lambda:http(url,goal),lambda s:'success([ok],false)' in s)
  goal=f'promise({quote(peer)},X=f(X),Ref,[template(X),limit(1),once(true)]),yield(Ref,error(error(representation_error(cyclic_term),_)),[timeout(3)]),Outcome=ok'
  check(label+' promise cycle rejection',lambda:http(url,goal),lambda s:'success([ok],false)' in s)
(OUT/'interop-checks.json').write_text(json.dumps(dict(smoke_passed=len(rows),all_passed=all(r['passed'] for r in rows)),indent=2)+'\n')
