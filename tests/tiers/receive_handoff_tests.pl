:- module(test_receive_handoff, []).
:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module(library(plunit)).
:- use_module(library(prolog_wrap)).
:- use_module(library(time)).

:- thread_local handoff_parent/1.

% The wrapper exposes the return from the protected acquisition helper.
% Before the repair this boundary preceded deferred recording; afterwards it
% follows recording. No production hook or public protocol is introduced.
handoff_gate :-
    (handoff_parent(Parent) -> thread_self(Self),
      thread_send_message(Parent,acquired(Self)),thread_get_message(release)
    ;true).

handoff_owner(Parent,Mode) :-
    asserta(handoff_parent(Parent),Gate),
    thread_self(Self),thread_send_message(Self,down(unrelated,probe,killed)),
    wait_options(Mode,Options),
    catch(receive({never -> true},Options),Error,true),
    erase(Gate),
    catch((require(Error=='$abort_goal',wrong_error(Error)),
      receive({down(unrelated,probe,killed) -> true},
              [timeout(0),on_timeout(throw(missing_unrelated))]),
      receive({down(unrelated,probe,killed) -> throw(duplicate_unrelated)},[timeout(0)]),
      Result=ok),Failure,Result=failed(Failure)),
    thread_send_message(Parent,result(Self,Result)).

wait_options(blocking,[]).
wait_options(poll,[timeout(0)]).
wait_options(timed,[timeout(2)]).
wait_options(deadline,[deadline(D)]) :- get_time(Now),D is Now+2.

handoff_case(Mode) :-
    thread_self(Parent),
    setup_call_cleanup(
      thread_create(test_receive_handoff:handoff_owner(Parent,Mode),Thread,[]),
      (timed_message(acquired(Thread)),
       thread_signal(Thread,throw('$abort_goal')),
       timed_message(result(Thread,Result)),
       assertion(Result==ok)),
      join_test_thread(Thread)).

empty_owner(Parent,Mode) :-
    thread_self(Self),wait_options(Mode,Options),
    catch((thread_send_message(Parent,waiting(Self)),receive({never -> true},Options)),Error,true),
    thread_send_message(Parent,interrupted(Self,Error)).

empty_case(Mode) :-
    thread_self(Parent),
    setup_call_cleanup(
      thread_create(test_receive_handoff:empty_owner(Parent,Mode),Thread,[]),
      (timed_message(waiting(Thread)),
       % Let the protected empty wait begin before interrupting it.
       sleep(0.01),get_time(Start),thread_signal(Thread,throw('$abort_goal')),
       timed_message(interrupted(Thread,Error)),
       get_time(End),Elapsed is End-Start,
       assertion(Error=='$abort_goal'),assertion(Elapsed<0.8)),
      join_test_thread(Thread)).

join_test_thread(Thread) :-
    (thread_property(Thread,status(running)) ->
       thread_send_message(Thread,release),
       catch(thread_signal(Thread,throw(test_cleanup)),_,true)
    ;true),
    thread_join(Thread,Status),require(Status==true,thread_status(Status)).

flush_mailbox :-
    receive({_ -> flush_mailbox},[timeout(0)]).
require(Goal,Error) :- (call(Goal)->true;throw(Error)).

:- begin_tests(receive_handoff,[setup(flush_mailbox),cleanup(flush_mailbox)]).

test(record_precedes_interruptible_return,
     [forall(member(Mode,[blocking,poll,timed,deadline])),timeout(3)]) :-
    setup_call_cleanup(
      wrap_predicate(actors:receive_message(_,_,_,_),test_handoff,Wrapped,
                     (call(Wrapped),test_receive_handoff:handoff_gate)),
      forall(between(1,20,_),handoff_case(Mode)),
      unwrap_predicate(actors:receive_message/4,test_handoff)).

test(empty_wait_remains_interruptible,
     [forall(member(Mode,[blocking,timed,deadline])),timeout(3)]) :-
    forall(between(1,5,_),empty_case(Mode)).

test(explicit_host_signals_false_is_retained,[timeout(3)]) :-
    thread_self(Parent),
    setup_call_cleanup(
      thread_create(test_receive_handoff:host_signals_owner(Parent),Thread,[]),
      (timed_message(waiting(Thread)),sleep(0.01),
       thread_signal(Thread,throw('$abort_goal')),sleep(0.08),
       assertion(\+thread_peek_message(Parent,interrupted(Thread,_))),
       thread_send_message(Thread,release),
       timed_message(interrupted(Thread,Error)),assertion(Error=='$abort_goal')),
      join_test_thread(Thread)).

test(original_deadline_and_single_timeout_callback,[timeout(2)]) :-
    nb_setval(handoff_timeouts,0),get_time(Start),D is Start+0.13,
    receive({never -> fail},[deadline(D),on_timeout(
      (nb_getval(handoff_timeouts,N),N1 is N+1,nb_setval(handoff_timeouts,N1)))]),
    get_time(End),Elapsed is End-Start,
    assertion(Elapsed>=0.10),assertion(Elapsed<0.7),nb_getval(handoff_timeouts,1).

test(expired_deadline_and_negative_timeout_leave_native_message,
     [forall(member(Options,[[deadline(-1)],[timeout(-1)]]))]) :-
    thread_self(Self),thread_send_message(Self,untouched),
    receive({untouched -> throw(consumed_expired)},[on_timeout(true)|Options]),
    assertion(thread_peek_message(Self,untouched)),
    receive({untouched -> true},[timeout(0),on_timeout(fail)]).

test(duplicate_native_timeout_precedence_is_retained) :-
    thread_self(Self),thread_send_message(Self,first),
    receive({first -> true},[timeout(-1),timeout(0),on_timeout(fail)]),
    thread_send_message(Self,second),
    receive({second -> throw(consumed_negative)},[timeout(0),timeout(-1)]),
    receive({second -> true},[timeout(0),on_timeout(fail)]).

test(body_failure_consumes_selected_message) :-
    thread_self(Self),thread_send_message(Self,pick),
    assertion(\+receive({pick -> fail},[timeout(1)])),
    receive({pick -> throw(duplicate_pick)},[timeout(0)]).

test(body_exception_consumes_selected_message) :-
    thread_self(Self),thread_send_message(Self,pick),
    catch(receive({pick -> throw(body_error)},[timeout(1)]),Error,true),
    assertion(Error==body_error),receive({pick -> throw(duplicate_pick)},[timeout(0)]).

test(selected_body_keeps_alternatives, Values==[a,b]) :-
    thread_self(Self),thread_send_message(Self,pick),
    findall(V,receive({pick -> member(V,[a,b])},[timeout(1)]),Values).

test(timeout_body_keeps_alternatives, Values==[a,b]) :-
    findall(V,receive({absent -> fail},[timeout(0.07),on_timeout(member(V,[a,b]))]),Values).

:- end_tests(receive_handoff).

timed_message(Message) :- thread_self(Self),thread_get_message(Self,Message,[timeout(1)]).

host_signals_owner(Parent) :-
    thread_self(Self),
    catch((thread_send_message(Parent,waiting(Self)),
           receive({release -> throw(body_should_not_run)},[signals(false)])),Error,true),
    % Even when a pending signal runs immediately after the read, the newly
    % acquired message must already be durable.
    receive({release -> true},[timeout(0),on_timeout(throw(missing_release))]),
    thread_send_message(Parent,interrupted(Self,Error)).
