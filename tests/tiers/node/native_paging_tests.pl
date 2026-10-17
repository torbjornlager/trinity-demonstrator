:- module(test_native_paging, []).

:- use_module('../../../prolog/web_prolog/rpc.pl').
:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/node_engine.pl', []).
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl', [toplevel_halt/2]).
:- use_module('../../../prolog/web_prolog/actors.pl', []).
:- use_module(library(plunit)).
:- use_module(library(gensym)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_parameters)).
:- use_module(library(prolog_wrap)).
:- use_module(library(time)).

:- meta_predicate with_pages(-,-,0), with_query_queue(-,0), with_cached_goal(+,+,-,0).
:- meta_predicate with_paging_fault(+,+,0), with_paging_thread(+,-,+,0).
:- thread_local paging_fault/2, paging_alarm/1, paging_actor/1, paging_reply_queue/1.

% Inject faults inside the existing handoffs, without production test hooks.
% The wrappers are inert in other threads and are removed after each test.
with_paging_fault(Point, Action, Goal) :-
    setup_call_cleanup(
        (asserta(test_native_paging:paging_fault(Point,Action)),
         wrap_predicate(toplevel_actors:toplevel_spawn(P,_S), paging_cleanup, W1,
             (W1,test_native_paging:paging_step(spawn,P))),
         wrap_predicate(node_engine:cache_take(G,N,P,_Timer), paging_cleanup, W2,
             (W2,test_native_paging:paging_step(checkout,P))),
         wrap_predicate(node_engine:cache_update(G,N,P), paging_cleanup, W3,
             (W3,test_native_paging:paging_step(publish,P))),
         wrap_predicate(node_engine:schedule_cache_alarm(_T,_TTL,G,N,P), paging_cleanup, W4,
             (test_native_paging:paging_step(schedule,P),W4)),
         wrap_predicate(node_engine:wait_for_compute_answer(_,_,_,P,_,_,_,_,_), paging_cleanup, W5,
             (test_native_paging:paging_step(wait,P),W5)),
         wrap_predicate(node_engine:acquire_request_actor(_,_,_,_,_,Q,_,_), paging_cleanup, W6,
             (test_native_paging:paging_track_queue(Q),W6))),
        Goal,
        (unwrap_predicate(toplevel_actors:toplevel_spawn/2,paging_cleanup),
         unwrap_predicate(node_engine:cache_take/4,paging_cleanup),
         unwrap_predicate(node_engine:cache_update/3,paging_cleanup),
         unwrap_predicate(node_engine:schedule_cache_alarm/5,paging_cleanup),
         unwrap_predicate(node_engine:wait_for_compute_answer/9,paging_cleanup),
         unwrap_predicate(node_engine:acquire_request_actor/8,paging_cleanup),
         retractall(test_native_paging:paging_fault(_,_)),
         retractall(test_native_paging:paging_actor(_)),
         retractall(test_native_paging:paging_reply_queue(_)),
         forall(retract(test_native_paging:paging_alarm(A)),catch(remove_alarm(A),_,true)))).

paging_track_queue(Queue) :-
    (paging_fault(_,_) -> assertz(paging_reply_queue(Queue));true).

assert_reply_queue_destroyed :-
    paging_reply_queue(Queue),
    assertion(\+ catch(message_queue_property(Queue,_),
                      error(existence_error(message_queue,_),_),fail)).

paging_step(Point, Pid) :-
    (   retract(paging_fault(Point,Action))
    ->  assertz(paging_actor(Pid)),
        (Action = throw(Error) -> throw(Error)
        ;Action == fail -> fail
        ;alarm(0.001,throw(paging_interrupted),Alarm,[]),
         assertz(paging_alarm(Alarm)),sleep(0.02))
    ;   true
    ).

assert_actor_stopped(Pid) :-
    get_time(Now), Deadline is Now+2,
    wait_actor_stopped(Pid,Deadline),
    setup_call_cleanup(actors:monitor(Pid,Ref),
        actors:receive({down(Pid,Ref,no_process) -> true},
                       [timeout(0),on_timeout(throw(paging_actor_leaked(Pid)))]),
        actors:demonitor(Ref,[flush])).

wait_actor_stopped(Pid, Deadline) :-
    (actors:pid_local(Pid,Local),actors:pid_thread(Local,_)
    -> get_time(Now),
       (Now < Deadline -> sleep(0.001),wait_actor_stopped(Pid,Deadline)
       ;throw(paging_actor_leaked(Pid)))
    ;true).

% Keep the HTTP-like worker alive after catching the interrupt. Its exit must
% not hide a missing request finalizer through parent-child containment.
paging_thread(Goal, Events, Gate) :-
    catch(call(Goal),Error,true),
    thread_send_message(Events,finished(Error)),
    thread_get_message(Gate,finish).

with_paging_thread(Goal, Thread, Events-Gate, Test) :-
    setup_call_cleanup(thread_create(paging_thread(Goal,Events,Gate),Thread,[]),
        Test,
        (catch(thread_signal(Thread,throw(test_paging_cleanup)),_,true),
         thread_send_message(Gate,finish),thread_join(Thread,_))).

% An independent endpoint returns multiple short pages. Using the same wrong
% increment on both native sides would otherwise conceal the client defect.
with_pages(URI, Requests, Goal) :-
    setup_call_cleanup(message_queue_create(Requests),
        setup_call_cleanup(
            http_server(page_reply(Requests),[port(Port),workers(1)]),
            (format(atom(URI),'http://localhost:~w',[Port]),call(Goal)),
            http_stop_server(Port,[])),
        message_queue_destroy(Requests)).

page_reply(Requests, Request) :-
    http_parameters(Request,[offset(Offset,[integer]),limit(Limit,[integer])]),
    thread_send_message(Requests,request(Offset,Limit)),
    page_answer(Offset,Answer),
    format('Content-type: application/x-prolog~n~n'),
    write_canonical(Answer),write('.'),nl.

page_answer(0,success([v(a)],true)) :- !.
page_answer(1,success([v(b),v(c)],true)) :- !.
page_answer(3,success([v(d)],false)) :- !.
page_answer(Offset,error(unexpected_page_offset(Offset))).

with_query_queue(Alias, Goal) :-
    gensym(native_paging_,Alias),
    setup_call_cleanup(message_queue_create(_,[alias(Alias)]),call(Goal),
                       message_queue_destroy(Alias)).

with_cached_goal(Goal, Template, Gid, Test) :-
    node_engine:goal_id(Goal-Template-''-false,GoalId),
    node_engine:cache_key(GoalId,Gid),
    setup_call_cleanup(true,call(Test),
        forall(node_engine:cache_retract(Gid,_,Pid),toplevel_halt(Pid,true))).

assert_executed_once(Queue) :-
    thread_get_message(Queue,entered,[timeout(0)]),
    assertion(\+ thread_get_message(Queue,_,[timeout(0)])).

:- begin_tests(native_paging).

test(rpc_short_pages_advance_by_returned_count) :-
    with_pages(URI,Requests,
        (findall(X,rpc(URI,value(X),[limit(5)]),Xs),
         assertion(Xs==[a,b,c,d]),
         thread_get_message(Requests,request(0,5),[timeout(0)]),
         thread_get_message(Requests,request(1,5),[timeout(0)]),
         thread_get_message(Requests,request(3,5),[timeout(0)]),
         assertion(\+ thread_get_message(Requests,_,[timeout(0)])))).

test(rpc_once_does_not_request_another_page) :-
    with_pages(URI,Requests,
        (findall(X,rpc(URI,value(X),[limit(5),once(true)]),Xs),
         assertion(Xs==[a]),
         thread_get_message(Requests,request(0,5),[timeout(0)]),
         assertion(\+ thread_get_message(Requests,_,[timeout(0)])))).

% Direct engine calls allow a trusted queue notification to prove that cache
% reuse delivers the pending error without starting the query again.
test(partial_error_page_cache_offset,
     [forall(member(Offset,[0,1])),timeout(3)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),
               (member(X,[a,b,c]);throw(paging_error))),
         with_cached_goal(Goal,X,Gid,
             (node_engine:compute_answer(Goal,X,Offset,5,First),
              (Offset==0 -> Expected=[a,b,c];Expected=[b,c]),
              assertion(First==success(Expected,true)),
              assertion(node_engine:cache(Gid,3,_)),
              node_engine:compute_answer(Goal,X,3,2,Last),
              assertion(Last==error(paging_error)),
              assertion(\+ node_engine:cache(Gid,_,_)),
              assert_executed_once(Queue))))).

test(full_pages_changing_limits_and_final_page, [timeout(3)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),between(1,7,X)),
         with_cached_goal(Goal,X,Gid,
             (node_engine:compute_answer(Goal,X,0,2,A),
              assertion(A==success([1,2],true)),
              assertion(node_engine:cache(Gid,2,_)),
              node_engine:compute_answer(Goal,X,2,3,B),
              assertion(B==success([3,4,5],true)),
              assertion(node_engine:cache(Gid,5,_)),
              node_engine:compute_answer(Goal,X,5,4,C),
              assertion(C==success([6,7],false)),
              assertion(\+ node_engine:cache(Gid,_,_)),
              assert_executed_once(Queue))))).

test(interrupted_request_reclaims_new_or_checked_out_actor,
     [forall(member(Mode,[new,resumed])),timeout(5)]) :-
    with_query_queue(Events,with_query_queue(Gate,
        (Block=(self(P),thread_send_message(Events,ready(P)),
                thread_get_message(Gate,continue)),
         (Mode == new -> Goal=(Block,member(X,[a,b])), Offset=0
         ; Goal=(X=a;Block,member(X,[b,c])), Offset=1),
         with_cached_goal(Goal,X,Gid,
             ((Mode == resumed
               -> node_engine:compute_answer(Goal,X,0,1,success([a],true))
               ; true),
              with_paging_thread(node_engine:compute_answer(Goal,X,Offset,1,_),
                  Thread,Events-Gate,
                  (thread_get_message(Events,ready(Pid),[timeout(2)]),
                   thread_signal(Thread,throw(paging_interrupted)),
                   thread_get_message(Events,finished(Error),[timeout(2)]),
                   assertion(Error==paging_interrupted),
                   assert_actor_stopped(Pid),
                   assertion(\+ node_engine:cache(Gid,_,_))))))))).

test(acquisition_interrupt_cannot_lose_actor,
     [forall(member(Point,[spawn,checkout])),timeout(5)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),between(1,4,X)),
         with_cached_goal(Goal,X,Gid,
             ((Point==checkout
               -> node_engine:compute_answer(Goal,X,0,1,success([1],true)),Offset=1
               ; Offset=0),
              with_paging_fault(Point,interrupt,
                  (catch(node_engine:compute_answer(Goal,X,Offset,1,_),Error,true),
                   assertion(Error==paging_interrupted),
                   test_native_paging:paging_actor(Pid),assert_actor_stopped(Pid),
                   test_native_paging:assert_reply_queue_destroyed,
                   assertion(\+ node_engine:cache(Gid,_,_)))))))).

test(interrupt_after_publication_preserves_resumable_cache, [timeout(5)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),between(1,4,X)),
         with_cached_goal(Goal,X,Gid,
             (with_paging_fault(publish,interrupt,
                  (catch(node_engine:compute_answer(Goal,X,0,2,_),Error,true),
                   assertion(Error==paging_interrupted),
                   test_native_paging:paging_actor(Pid),
                   assertion(node_engine:cache(Gid,2,Pid)),
                   assertion(node_engine:cache_alarm(Gid,2,Pid,_)),
                   test_native_paging:assert_reply_queue_destroyed)),
              node_engine:compute_answer(Goal,X,2,3,Answer),
              assertion(Answer==success([3,4],false)),
              assert_executed_once(Queue))))).

test(failure_or_exception_after_send_reclaims_actor,
     [forall(member(Action,[throw(paging_send_error),fail])),timeout(5)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),between(1,4,X)),
         with_cached_goal(Goal,X,Gid,
             with_paging_fault(wait,Action,
                 ((catch(node_engine:compute_answer(Goal,X,0,1,_),Error,true)
                   -> Outcome=success ; Outcome=failure),
                  (Action=throw(Expected) -> assertion(Error==Expected)
                  ;assertion(Outcome==failure)),
                  test_native_paging:paging_actor(Pid),assert_actor_stopped(Pid),
                  test_native_paging:assert_reply_queue_destroyed,
                  assertion(\+ node_engine:cache(Gid,_,_))))))).

test(timer_setup_error_rolls_back_cache_and_reclaims_actor, [timeout(5)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),between(1,4,X)),
         with_cached_goal(Goal,X,Gid,
             with_paging_fault(schedule,throw(paging_timer_error),
                 (catch(node_engine:compute_answer(Goal,X,0,1,_),Error,true),
                  assertion(Error==paging_timer_error),
                  test_native_paging:paging_actor(Pid),assert_actor_stopped(Pid),
                  test_native_paging:assert_reply_queue_destroyed,
                  assertion(\+ node_engine:cache(Gid,_,_)),
                  assertion(\+ node_engine:cache_alarm(Gid,_,Pid,_))))))).

test(timeout_answer_and_cleanup_are_preserved, [timeout(5)]) :-
    with_query_queue(Events,with_query_queue(Gate,
        (Goal=(self(P),thread_send_message(Events,ready(P)),thread_get_message(Gate,_)),
         node_engine:compute_answer(Goal,true,0,1,'',0.02,Answer),
         assertion(Answer=error(error(resource_error(time),_))),
         thread_get_message(Events,ready(Pid),[timeout(0)]),
         assert_actor_stopped(Pid)))).

test(cleanup_preserves_unrelated_cache_monitor_and_messages, [timeout(5)]) :-
    with_query_queue(Queue,
        (CachedGoal=(thread_send_message(Queue,entered),between(1,4,X)),
         with_cached_goal(CachedGoal,X,Gid,
             (node_engine:compute_answer(CachedGoal,X,0,2,success([1,2],true)),
              node_engine:cache(Gid,2,CachedPid),
              setup_call_cleanup(actors:monitor(CachedPid,Ref),
                  (actors:self(Self),actors:send(Self,paging_unrelated),
                   with_paging_fault(wait,throw(paging_send_error),
                       catch(node_engine:compute_answer(receive({}),true,0,1,_),
                             paging_send_error,true)),
                   assertion(actors:monitor(Self,CachedPid,Ref)),
                   assertion(node_engine:cache(Gid,2,CachedPid)),
                   actors:receive({paging_unrelated -> true},[timeout(0),on_timeout(fail)]),
                   node_engine:compute_answer(CachedGoal,X,2,3,success([3,4],false)),
                   actors:receive({down(CachedPid,Ref,_) -> true},[timeout(2),on_timeout(fail)]),
                   assert_executed_once(Queue)),
                  actors:demonitor(Ref,[flush])))))).

:- end_tests(native_paging).
