:- module(ws_smoke,[run/0]).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).
:- use_module(library(time)).
send(WS,D) :- atom_json_dict(A,D,[]),ws_send(WS,text(A)).
read_json(WS,D) :- ws_receive(WS,F,[]),atom_json_dict(F.data,D,[]).
await(WS,Type,D) :- read_json(WS,R),(R.type==Type -> D=R ; await(WS,Type,D)).
answer(WS,P,D) :- read_json(WS,R),(get_dict(pid,R,P),memberchk(R.type,["success","failure","error"]) -> D=R ; answer(WS,P,D)).
run :- getenv('WS_SMOKE_GOAL',Goal),
 setup_call_cleanup(http_open_websocket('http://localhost:51855/ws',WS,[]),
  call_with_time_limit(15,
   (send(WS,_{command:toplevel_spawn,options:"[session(true)]"}),await(WS,"spawned",Spawn),
    send(WS,_{command:toplevel_call,pid:Spawn.pid,goal:Goal,options:"[limit(10)]"}),answer(WS,Spawn.pid,Answer),
    send(WS,_{command:toplevel_halt,pid:Spawn.pid}),json_write_dict(current_output,Answer,[]),nl)),
  catch(ws_close(WS,1000,done),_,true)).
