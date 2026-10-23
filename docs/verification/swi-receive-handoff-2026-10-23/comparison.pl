:- module(receive_handoff_swi_gated,[run/0,owner/1,gate/0]).

:- use_module(library(prolog_wrap)).
run :-
 current_prolog_flag(argv,[Adapter]),load_files(Adapter,[imports([])]),
 (current_predicate(actors:receive_message/4) ->
   Head=actors:receive_message(_,_,_,_),PI=actors:receive_message/4
 ; Head=actors:receive_message(_,_,_),PI=actors:receive_message/3),
 setup_call_cleanup(
   wrap_predicate(Head,handoff_probe,Wrapped,
                  (call(Wrapped),receive_handoff_swi_gated:gate)),
   (thread_self(P),forall(between(1,20,_),trial(P))),
   unwrap_predicate(PI,handoff_probe)).
trial(P) :-
 thread_create(receive_handoff_swi_gated:owner(P),T,[]),
 bounded(acquired(T)),thread_signal(T,throw('$abort_goal')),
 bounded(result(T,R)),thread_join(T,S),
 (S==true->true;throw(status(S))),writeq(R),nl.
owner(P) :-
 nb_setval(probe_parent,P),thread_self(Self),
 thread_send_message(Self,down(unrelated,probe,killed)),
 catch(actors:receive({never->true}),E,true),
 nb_delete(probe_parent),
 (thread_peek_message(Self,down(unrelated,probe,killed))->Native=present;Native=absent),
 (clause(actors:deferred(down(unrelated,probe,killed)),true,_)->Deferred=present;Deferred=absent),
 catch(((E=='$abort_goal'->true;throw(wrong_exception(E))),
   actors:receive({down(unrelated,probe,killed)->true},
      [timeout(0),on_timeout(throw(missing_unrelated))]),R=ok),
   Failure,R=failed(Failure,Native,Deferred)),
 thread_send_message(P,result(Self,R)).
gate :-
 (nb_current(probe_parent,P)->thread_self(Self),
   thread_send_message(P,acquired(Self)),thread_get_message(Self,continue)
 ;true).
bounded(M) :- thread_self(Self),get_time(Now),D is Now+5,
 (thread_get_message(Self,M,[deadline(D)])->true;throw(wait_timeout(M))).

