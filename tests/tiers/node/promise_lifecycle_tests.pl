:- module(test_promise_lifecycle, []).

:- use_module('../../../prolog/web_prolog/rpc.pl').
:- use_module(library(plunit)).
:- use_module(library(http/thread_httpd)).

:- meta_predicate with_pending(-,-,-,0), with_collector(+,-,-,0), with_server(-,-,-,0).
with_pending(Ref, Key, Queue, Goal) :-
    setup_call_cleanup(
      (rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
       with_mutex(promise_lifecycle,rpc:new_promise_state(Key,Queue))),
      Goal,promise_cleanup(Ref)).

collector(Ref, Events) :-
    catch((yield(Ref,Answer),Result=answer(Answer)),Error,Result=error(Error)),
    thread_send_message(Events,Result).
with_collector(Ref, Thread, Events, Goal) :-
    setup_call_cleanup(message_queue_create(Events),
      setup_call_cleanup(thread_create(collector(Ref,Events),Thread,[]),Goal,
        (promise_cleanup(Ref),catch(thread_join(Thread,_),_,true))),
      message_queue_destroy(Events)).

wait_until(Goal) :- call_with_time_limit(3,wait_loop(Goal)).
wait_loop(Goal) :- (call(Goal) -> true; sleep(0.002),wait_loop(Goal)).
:- meta_predicate wait_until(0), wait_loop(0).
claimed(Key) :-
    with_mutex(promise_lifecycle,(rpc:promise_state(Key,_,_,_,Claim,_,_),Claim\==none)).
thread_stopped(Thread) :-
    \+ catch(thread_property(Thread,status(running)),error(existence_error(thread,_),_),fail).
queue_gone(Q) :-
    \+ catch(message_queue_property(Q,size(_)),error(existence_error(message_queue,_),_),fail).
invalid_error(Error,Ref) :-
    assertion(nonvar(Error)),assertion(Error=error(existence_error(promise,Ref),_)).

with_server(URI, Events, Gate, Goal) :-
    setup_call_cleanup(message_queue_create(Events),
      setup_call_cleanup(message_queue_create(Gate),
        setup_call_cleanup(http_server(serve(Events,Gate),[port(Port),workers(1)]),
          (format(atom(URI),'http://localhost:~w',[Port]),Goal),
          (thread_send_message(Gate,reply),http_stop_server(Port,[]))),
        message_queue_destroy(Gate)),message_queue_destroy(Events)).
serve(Events, Gate, _) :-
    thread_send_message(Events,request_started),thread_get_message(Gate,reply),
    catch(format('Content-type: application/x-prolog~n~nsuccess([ok],false).~n'),_,true).
resources(Ref,Key,Q,W,T) :-
    rpc:promise_queue_key(Ref,Key),
    with_mutex(promise_lifecycle,rpc:promise_state(Key,Q,Worker,Timer,_,_,_)),
    arg(1,Worker,W),arg(1,Timer,T).
assert_disposed(Key,Q,W,T) :-
    assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),assertion(queue_gone(Q)),
    wait_until(thread_stopped(W)),wait_until(thread_stopped(T)).

:- begin_tests(promise_lifecycle).

test(collection_reclaims_queue) :-
    with_pending(Ref,Key,Q,
      (rpc:deliver_promise_answer(Key,failure),yield(Ref,Answer),assertion(Answer==failure),
       assertion(queue_gone(Q)),assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)))).

test(competing_collector_rejected_without_disturbing_first) :-
    with_pending(Ref,Key,_,
      with_collector(Ref,_,Events,
        (wait_until(claimed(Key)),catch(yield(Ref,_),Error,true),
         assertion(Error=error(permission_error(collect,promise,Ref),_)),
         assertion(nonvar(Error)),rpc:deliver_promise_answer(Key,failure),
         thread_get_message(Events,Result,[timeout(3)]),assertion(Result==answer(failure))))).

test(disposal_wakes_waiting_collector,
     [forall(member(Action,[cleanup,expiry]))]) :-
    with_pending(Ref,Key,Q,
      with_collector(Ref,_,Events,
        (wait_until(claimed(Key)),
         (Action==cleanup -> promise_cleanup(Ref);rpc:promise_auto_cleanup_thread(Key,0)),
         thread_get_message(Events,Result,[timeout(3)]),
         assertion(Result=error(_)),Result=error(Error),invalid_error(Error,Ref),
         assertion(queue_gone(Q)),promise_cleanup(Ref)))).

test(interrupted_collector_releases_claim_and_answer_remains_collectable) :-
    with_pending(Ref,Key,_,
      with_collector(Ref,Thread,Events,
        (wait_until(claimed(Key)),thread_signal(Thread,throw(test_collector_cancelled)),
         thread_get_message(Events,Result,[timeout(3)]),
         assertion(Result==error(test_collector_cancelled)),
         rpc:deliver_promise_answer(Key,success([ready],false)),
         yield(Ref,Answer),assertion(Answer==success([ready],false))))).

test(expiry_and_collection_have_one_winner,
     [forall(between(1,20,_))]) :-
    with_pending(Ref,Key,Q,
      with_collector(Ref,_,Events,
        (wait_until(claimed(Key)),
         thread_create(rpc:deliver_promise_answer(Key,failure),Completer,[]),
         thread_create(rpc:promise_auto_cleanup_thread(Key,0),Expirer,[]),
         thread_join(Completer,CompleteStatus),assertion(CompleteStatus==true),
         thread_join(Expirer,ExpireStatus),assertion(ExpireStatus==true),
         thread_get_message(Events,Result,[timeout(3)]),
         (Result==answer(failure) -> true;Result=error(Error),invalid_error(Error,Ref)),
         assertion(queue_gone(Q))))).

test(timeout_callback_can_retry_after_claim_release) :-
    with_pending(Ref,Key,_,
      (yield(Ref,Answer,[timeout(0),on_timeout(
          (rpc:deliver_promise_answer(Key,failure),yield(Ref,Answer)))]),
       assertion(Answer==failure))).

test(expiry_thread_reclaims_its_own_resources) :-
    with_pending(_Ref,Key,Q,
      (with_mutex(promise_lifecycle,
         (thread_create(rpc:promise_thread(Key,timer,rpc:promise_auto_cleanup_thread(Key,0)),Timer,[detached(true)]),
          retract(rpc:promise_state(Key,Q,W,none,C,R,Owner)),
          assertz(rpc:promise_state(Key,Q,W,starting(Timer),C,R,Owner)))),
       wait_until(thread_stopped(Timer)),assertion(queue_gone(Q)),
       assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)))).

test(initialisation_failure_rolls_back_state_and_queue) :-
    findall(Q,message_queue_property(Q,size(_)),Before),
    rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
    catch(rpc:start_promise(Ref,17),Error,true),
    assertion(nonvar(Error)),assertion(Error=error(type_error(callable,17),_)),
    assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),
    findall(Q,message_queue_property(Q,size(_)),After),
    sort(Before,BeforeSet),sort(After,AfterSet),assertion(AfterSet==BeforeSet).

test(immediate_disposal_before_thread_activation) :-
    with_mutex(promise_lifecycle,
      (promise('http://127.0.0.1:1',true,Ref),resources(Ref,Key,Q,W,T),promise_cleanup(Ref))),
    assert_disposed(Key,Q,W,T).

test(collection_stops_expiry_task_and_reclaims_worker_resources) :-
    with_server(URI,Events,Gate,
      (promise(URI,true,Ref),resources(Ref,Key,Q,W,T),
       setup_call_cleanup(true,
         (thread_get_message(Events,request_started,[timeout(3)]),thread_send_message(Gate,reply),
          yield(Ref,Answer,[timeout(3)]),assertion(Answer==success([ok],false)),
          assert_disposed(Key,Q,W,T)),promise_cleanup(Ref)))).

test(disposal_interrupts_active_local_http_worker,
     [forall(member(Action,[cleanup,expiry]))]) :-
    with_server(URI,Events,_Gate,
      (promise(URI,true,Ref),resources(Ref,Key,Q,W,T),
       setup_call_cleanup(true,
         (thread_get_message(Events,request_started,[timeout(3)]),
          (Action==cleanup -> promise_cleanup(Ref);rpc:promise_auto_cleanup_thread(Key,0)),
          assert_disposed(Key,Q,W,T)),promise_cleanup(Ref)))).

:- end_tests(promise_lifecycle).
