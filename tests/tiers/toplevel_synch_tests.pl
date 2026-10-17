:- module(test_toplevel_synch, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/toplevel_actors.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- meta_predicate with_toplevel(-,+,0).

with_toplevel(Pid, Options, Goal) :-
    setup_call_cleanup(toplevel_spawn(Pid,[session(true)|Options]), Goal,
                       (toplevel_halt(Pid,true), drain_answers(Pid))).

drain_answers(Pid) :-
    receive({
        success(P,_,_) if P == Pid -> drain_answers(Pid) ;
        failure(P) if P == Pid -> drain_answers(Pid) ;
        error(P,_) if P == Pid -> drain_answers(Pid)
    },[timeout(0)]).

callback_answer(Answer) :- Answer = waited.

:- begin_tests(toplevel_synch).

test(default_arities_and_paging) :-
    with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,member(X,[a,b]),A,[template(X),limit(1),timeout(2)]),
         assertion(A==success(Pid,[a],true)), assertion(var(X)),
         toplevel_next_synch(Pid,B),assertion(B==success(Pid,[b],false)),
         toplevel_call_synch(Pid,true,C),assertion(C==success(Pid,[true],false)))).
test(overrides_creation_target) :-
    with_toplevel(Pid,[target(some_other_actor)],
        (toplevel_call_synch(Pid,true,A,[timeout(2),on_timeout(throw(misrouted))]),
         assertion(A==success(Pid,[true],false)))).
test(next_overrides_previous_target) :-
    setup_call_cleanup(spawn(sleep(10),Sink,[link(false)]),
      with_toplevel(Pid,[],
        (toplevel_call(Pid,member(X,[a,b,c]),[template(X),limit(1)]),
         receive({success(Pid,[a],true)->true},[timeout(2),on_timeout(throw(missing_first))]),
         % An asynchronous next routes slice b elsewhere; the synchronous
         % next must select this caller rather than inherit that target.
         toplevel_next(Pid,[target(Sink)]),
         toplevel_next_synch(Pid,A,[timeout(2),on_timeout(throw(misrouted))]),
         assertion(A==success(Pid,[c],false)))),
      exit(Sink,true)).
test(explicit_self_target) :-
    self(Self), with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,true,A,[target(Self),timeout(2)]),
         assertion(A==success(Pid,[true],false)))).
test(conflicting_call_target_before_send) :-
    setup_call_cleanup(message_queue_create(Q),
        with_toplevel(Pid,[],
            (catch(toplevel_call_synch(Pid,thread_send_message(Q,ran),_,
                                      [target(other)]),Error,true),
             assertion(Error=error(domain_error(synchronous_toplevel_target,other),_)),
             toplevel_call_synch(Pid,true,A,[timeout(2)]),
             assertion(A==success(Pid,[true],false)),
             assertion(\+ thread_get_message(Q,_,[timeout(0)])))),
        message_queue_destroy(Q)).
test(conflicting_next_target_does_not_advance) :-
    with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,member(X,[a,b]),_,[template(X),limit(1),timeout(2)]),
         catch(toplevel_next_synch(Pid,_,[target(other)]),Error,true),
         assertion(Error=error(domain_error(synchronous_toplevel_target,other),_)),
         toplevel_next_synch(Pid,A,[timeout(2)]),assertion(A==success(Pid,[b],false)))).
test(unbound_target_not_bound) :-
    catch(toplevel_call_synch(nonexistent,true,_,[target(Target)]),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Target)).
test(every_target_checked) :-
    self(Self),catch(toplevel_next_synch(nonexistent,_,[target(Self),target(other)]),Error,true),
    assertion(Error=error(domain_error(synchronous_toplevel_target,other),_)).
test(options_are_separated_without_copying) :-
    self(Self),
    toplevel_actors:synchronous_options(call,
        test_toplevel_synch:[template(X),limit(1),timeout(2),on_timeout(X=waited),target(Self)],
        Module,Query,Wait),
    assertion(Module==test_toplevel_synch),
    assertion(Query==[target(Self),template(X),limit(1)]),
    assertion(Wait==[timeout(2),on_timeout(X=waited)]),assertion(var(X)).
test(unknown_option_before_send,
     [throws(error(domain_error(toplevel_call_synch_option,timout(1)),_))]) :-
    toplevel_call_synch(nonexistent,true,_,[timout(1)]).
test(next_rejects_call_option,
     [throws(error(domain_error(toplevel_next_synch_option,template(_)),_))]) :-
    toplevel_next_synch(nonexistent,_,[template(_)]).
test(invalid_wait_before_send, [throws(error(type_error(number,bad),_))]) :-
    toplevel_call_synch(nonexistent,true,_,[timeout(bad)]).
test(invalid_callback_before_send, [throws(error(type_error(callable,17),_))]) :-
    toplevel_next_synch(nonexistent,_,[on_timeout(17)]).
test(timeout_callback_context_and_binding) :-
    with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,sleep(1),A,[timeout(0.01),on_timeout(callback_answer(A))]),
         assertion(A==waited))).
test(timeout_default_keeps_receive_semantics) :-
    with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,sleep(1),A,[timeout(0.01)]),assertion(var(A)))).
test(callback_once, true(Answers==[first])) :-
    with_toplevel(Pid,[],findall(A,
        toplevel_call_synch(Pid,sleep(1),A,
                            [timeout(0.01),on_timeout(member(A,[first,second]))]),Answers)).
test(callback_failure, [fail]) :-
    with_toplevel(Pid,[],toplevel_call_synch(Pid,sleep(1),_,[timeout(0.01),on_timeout(fail)])).
test(callback_exception, [throws(wait_expired)]) :-
    with_toplevel(Pid,[],toplevel_call_synch(Pid,sleep(1),_,
                                          [timeout(0.01),on_timeout(throw(wait_expired))])).
test(logical_failure_answer) :-
    with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,fail,A,[timeout(2)]),assertion(A==failure(Pid)))).
test(error_answer) :-
    with_toplevel(Pid,[],
        (toplevel_call_synch(Pid,throw(query_error),A,[timeout(2)]),
         assertion(A==error(Pid,query_error)))).
test(unrelated_and_io_messages_preserved) :-
    with_toplevel(Pid,[],
        (self(Self),send(Self,unrelated(X)),send(Self,output(Pid,hello)),
         toplevel_call_synch(Pid,true,A,[timeout(2)]),
         assertion(A==success(Pid,[true],false)),assertion(var(X)),
         receive({unrelated(Y)->assertion(var(Y))},[timeout(0),on_timeout(throw(lost_unrelated))]),
         receive({output(Pid,hello)->true},[timeout(0),on_timeout(throw(lost_io))]))).
test(preinstantiated_answer_mismatch_consumes_answer) :-
    with_toplevel(Pid,[],
        (\+ toplevel_call_synch(Pid,true,failure(Pid),[timeout(2)]),
         receive({success(Pid,_,_)->throw(answer_not_consumed)},[timeout(0)]))).

test(call_detects_termination_without_timeout,
     [timeout(3),throws(toplevel_down(synchronous_call_exit))]) :-
    with_toplevel(Pid,[],toplevel_call_synch(Pid,exit(synchronous_call_exit),_)).

test(next_detects_termination_without_timeout,
     [timeout(3),throws(toplevel_down(synchronous_next_exit))]) :-
    with_toplevel(Pid,[],
      (toplevel_call_synch(Pid,
         (member(X,[a,b]),(X==b -> exit(synchronous_next_exit);true)),First,
         [template(X),limit(1)]),
       assertion(First==success(Pid,[a],true)),toplevel_next_synch(Pid,_))).

test(termination_preserves_existing_monitor_and_unrelated_down) :-
    with_toplevel(Pid,[],
      (self(Self),monitor(Pid,Existing),send(Self,down(other_pid,other_ref,other_reason)),
       catch(toplevel_call_synch(Pid,exit(synchronous_exit),_),Error,true),
       assertion(Error==toplevel_down(synchronous_exit)),
       receive({down(Pid,Existing,synchronous_exit)->true},
               [timeout(2),on_timeout(throw(missing_existing_monitor))]),
       receive({down(other_pid,other_ref,other_reason)->true},
               [timeout(0),on_timeout(throw(missing_unrelated_down))]),
       receive({down(Pid,_,_)->throw(leaked_private_down)},[timeout(0)]))).

test(timeout_paths_clean_only_private_monitor,
     [forall(member(Callback,[true,fail,throw(test_wait_exception)]))]) :-
    with_toplevel(Pid,[],
      (self(Self),monitor(Pid,Existing),
       catch(ignore(toplevel_call_synch(Pid,sleep(1),_,
                    [timeout(0),on_timeout(Callback)])),test_wait_exception,true),
       findall(Ref,actors:monitor(Self,Pid,Ref),Refs),assertion(Refs==[Existing]),
       toplevel_halt(Pid,true),
       receive({down(Pid,Existing,true)->true},[timeout(2),on_timeout(throw(missing_existing_down))]),
       receive({down(Pid,_,_)->throw(leaked_wait_monitor)},[timeout(0)]))).

test(success_preserves_existing_monitor_without_leaking_private_monitor) :-
    with_toplevel(Pid,[],
      (self(Self),monitor(Pid,Existing),toplevel_call_synch(Pid,true,Answer),
       assertion(Answer==success(Pid,[true],false)),
       findall(Ref,actors:monitor(Self,Pid,Ref),Refs),assertion(Refs==[Existing]),
       demonitor(Existing,[flush]))).

test(reply_mismatch_cleans_private_monitor) :-
    with_toplevel(Pid,[],
      (self(Self),monitor(Pid,Existing),
       \+toplevel_call_synch(Pid,true,failure(Pid),[timeout(2)]),
       findall(Ref,actors:monitor(Self,Pid,Ref),Refs),assertion(Refs==[Existing]),
       demonitor(Existing,[flush]))).

test(send_exception_flushes_private_down,
     [forall(member(Kind,[call,next]))]) :-
    gensym(missing_sync_toplevel_,Name),
    catch((Kind==call -> toplevel_call_synch(Name,true,_);toplevel_next_synch(Name,_)),Error,true),
    assertion(Error=error(existence_error(actor_name,Name),_)),assertion(nonvar(Error)),
    receive({down(Name,_,_)->throw(leaked_send_down)},[timeout(0)]).

:- end_tests(toplevel_synch).
