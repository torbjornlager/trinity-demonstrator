:- module(test_server_promise_cleanup, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/server_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- thread_local send_error/3.
:- multifile actors:hook_check_send/2.
actors:hook_check_send(Pid, '$call'(_, _, Request)) :-
    test_server_promise_cleanup:send_error(Pid, Request, Error), throw(Error).

% A unification exception exercises reference setup after monitor installation
% without replacing the runtime's reference allocator.
attr_unify_hook(Error, _) :- throw(Error).

promise_cleanup_echo(Request, State, Request, State).
:- meta_predicate with_actor(-,0), failing_send(+,+,+,0).
with_actor(Pid, Goal) :-
    setup_call_cleanup(spawn(receive({}),Pid,[link(false)]),Goal,stop_actor(Pid)).
stop_actor(Pid) :-
    monitor(Pid,Ref),exit(Pid,true),
    receive({down(Pid,Ref,_)->true},[timeout(2),on_timeout(throw(missing_cleanup_down))]).
failing_send(Pid, Request, Error, Goal) :-
    setup_call_cleanup(asserta(send_error(Pid,Request,Error),Row),Goal,erase(Row)).
monitor_refs(Pid, Refs) :- self(Self),findall(Ref,actors:monitor(Self,Pid,Ref),Refs).

:- begin_tests(server_promise_cleanup).

test(send_exception_removes_only_new_monitor_and_preserves_error) :-
    with_actor(Pid,
      (monitor(Pid,Existing),
       Expected=error(test_send_failed,context(test_transport,'original details')),
       failing_send(Pid,ping,Expected,catch(server_promise(Pid,ping,_,_),Caught,true)),
       assertion(Caught==Expected),monitor_refs(Pid,Refs),assertion(Refs==[Existing]),
       stop_actor(Pid),
       receive({down(Pid,Existing,true)->true},[timeout(2),on_timeout(throw(missing_existing_down))]),
       receive({down(Pid,_,_)->fail},[timeout(0)]))).

test(reference_setup_exception_removes_monitor_and_preserves_error) :-
    with_actor(Pid,
      (Expected=error(test_reference_failed,context(test_setup,'original details')),
       put_attr(Ref,test_server_promise_cleanup,Expected),
       catch(server_promise(Pid,ping,Ref,_),Caught,true),
       assertion(Caught==Expected),monitor_refs(Pid,Refs),assertion(Refs==[]),
       stop_actor(Pid),receive({down(Pid,_,_)->fail},[timeout(0)]))).

test(missing_name_flushes_down_and_preserves_unrelated_message) :-
    gensym(missing_server_promise_,Name),self(Self),
    send(Self,down(unrelated_server,unrelated_ref,unrelated_reason)),
    catch(server_promise(Name,ping,_,_),Caught,true),
    assertion(Caught==error(existence_error(actor_name,Name),
                           context(actor:send/2,'no actor registered under name'))),
    receive({down(Name,_,_)->fail},[timeout(0)]),
    receive({down(unrelated_server,unrelated_ref,unrelated_reason)->true},
            [timeout(0),on_timeout(throw(missing_unrelated_message))]).

test(success_keeps_monitor_until_yield) :-
    setup_call_cleanup(server_spawn(promise_cleanup_echo,[],Pid),
      (server_promise(Pid,ping,Ref,MonRef),
       monitor_refs(Pid,Before),assertion(Before==[MonRef]),
       server_yield(Ref,MonRef,Answer,[timeout(2),on_timeout(throw(missing_reply))]),
       assertion(Answer==ping),monitor_refs(Pid,After),assertion(After==[])),
      server_halt(Pid,_)).

:- end_tests(server_promise_cleanup).
