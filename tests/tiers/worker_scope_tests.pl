:- module(test_worker_scope, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/parallel.pl').
:- use_module('../../prolog/web_prolog/first_solution.pl').
:- use_module('../../prolog/web_prolog/worker_cleanup.pl', []).
:- use_module(library(plunit)).
:- use_module(library(time)).

% Hooks affect only the thread running a controlled invocation. Workers and
% other suites never inherit the injected admission failures or commit alarms.
:- thread_local spawn_plan/3, spawn_count/1, scope_spawned/1, scope_alarm/1.
:- multifile actors:hook_check_spawn/1, actors:hook_spawn_commit/2.
actors:hook_check_spawn(_) :- test_worker_scope:check_scope_spawn.
actors:hook_spawn_commit(_, Pid) :- test_worker_scope:record_scope_spawn(Pid).

check_scope_spawn :-
    spawn_plan(Mode, Nth, _),
    retract(spawn_count(N)), N1 is N+1, assertz(spawn_count(N1)),
    (Mode = reject(Error), N1 =:= Nth -> throw(Error); true).

record_scope_spawn(Pid) :-
    spawn_plan(Mode, Nth, _),
    assertz(scope_spawned(Pid)),
    spawn_plan(_,_,Events),
    (Events == none -> true;thread_send_message(Events,registered(Pid))),
    (   spawn_count(Nth), memberchk(Mode,[interrupt_wait,interrupt_commit])
    ->  (Mode == interrupt_wait -> Delay=0.05;Delay=0.001),
        alarm(Delay,throw(worker_scope_interrupted),Alarm,[]),
        assertz(scope_alarm(Alarm)),
        % Hold the protected creation step until its alarm is due. Delivery
        % must wait until spawn_worker/3 has also recorded ownership.
        (Mode == interrupt_commit -> sleep(0.02);true)
    ;   true
    ).

:- meta_predicate with_spawn_plan(+,+,+,0).
with_spawn_plan(Mode, Nth, Events, Goal) :-
    setup_call_cleanup(
        (asserta(test_worker_scope:spawn_plan(Mode,Nth,Events),Plan),assertz(test_worker_scope:spawn_count(0))),
        Goal,
        (erase(Plan),retractall(test_worker_scope:spawn_count(_)),retractall(test_worker_scope:scope_spawned(_)),
         forall(retract(test_worker_scope:scope_alarm(Alarm)),
                catch(remove_alarm(Alarm),_,true)))).

invoke(parallel, Goals) :- parallel(Goals).
invoke(first_short, Goals) :- first_solution(_, Goals).
invoke(first_options, Goals) :- first_solution(_, Goals,[on_error(continue)]).

assert_stopped(Pids) :-
    self(Self),
    forall(member(Pid,Pids),
        (assertion(\+ actors:monitor(Self,Pid,_)),
         monitor(Pid,Ref),
         receive({down(Pid,Ref,no_process) -> true},
                 [timeout(0),on_timeout(throw(worker_still_alive(Pid)))]))).

assert_no_worker_messages(Pids) :-
    receive({
        Pid-_ if memberchk(Pid,Pids) -> throw(leaked_worker_result(Pid));
        down(Pid,_,_) if memberchk(Pid,Pids) -> throw(leaked_worker_down(Pid))
    },[timeout(0)]).

% Keep the interrupted caller alive after its catch, so parent containment
% cannot hide a failure to reclaim workers before propagating the exception.
signal_caller(Kind, Events, Gate) :-
    with_spawn_plan(observe,2,Events,
        (catch(invoke(Kind,[receive({}),receive({})]),Error,true),
         findall(P,test_worker_scope:scope_spawned(P),Pids),
         assert_stopped(Pids),assert_no_worker_messages(Pids),
         thread_send_message(Events,finished(Error,Pids)),
         thread_get_message(Gate,finish))).

:- meta_predicate with_signal_caller(+,-,-,-,0).
with_signal_caller(Kind, Thread, Events, Gate, Goal) :-
    setup_call_cleanup(message_queue_create(Events),
        setup_call_cleanup(message_queue_create(Gate),
            setup_call_cleanup(thread_create(signal_caller(Kind,Events,Gate),Thread,[]),
                Goal,
                (thread_send_message(Gate,finish),
                 catch(thread_signal(Thread,throw(test_scope_cleanup)),_,true),
                 thread_join(Thread,_))),
            message_queue_destroy(Gate)),
        message_queue_destroy(Events)).

scope_exit_block(Events) :- self(Pid),thread_send_message(Events,ready(Pid)),receive({}).
stop_test_caller(Pid) :-
    demonitor(Pid,[flush]),monitor(Pid,Ref),exit(Pid,kill),
    receive({down(Pid,Ref,_) -> true},[timeout(2),on_timeout(fail)]).

wait_workers_stopped(Pids) :-
    (member(Pid,Pids),actors:pid_local(Pid,Local),actors:pid_thread(Local,_)
    -> sleep(0.002),wait_workers_stopped(Pids)
    ; true).

:- begin_tests(worker_scope).

test(partial_startup_preserves_error_and_cleans_workers,
     [forall((member(Kind,[parallel,first_short,first_options]),
              member(Goals,[[receive({}),receive({}),true],[true,receive({}),true]]))),
      timeout(3)]) :-
    Expected=error(resource_error(test_worker_limit),context(worker_scope,startup)),
    self(Self),send(Self,scope_unrelated),
    with_spawn_plan(reject(Expected),3,none,
        (catch(invoke(Kind,Goals),Error,true),assertion(Error==Expected),
         findall(P,test_worker_scope:scope_spawned(P),Pids),assertion(length(Pids,2)),
         assert_stopped(Pids),assert_no_worker_messages(Pids),
         receive({scope_unrelated -> true},[timeout(0),on_timeout(fail)]))).

% Catch in the same live caller: parent-exit containment cannot conceal a
% missing explicit cleanup. The alarm is armed after the second spawn commits.
test(interrupted_wait_cleans_workers_while_caller_survives,
     [forall(member(Kind,[parallel,first_short,first_options])),timeout(3)]) :-
    with_spawn_plan(interrupt_wait,2,none,
        (catch(invoke(Kind,[receive({}),receive({})]),Error,true),
         assertion(Error==worker_scope_interrupted),
         findall(P,test_worker_scope:scope_spawned(P),Pids),assertion(length(Pids,2)),
         assert_stopped(Pids),assert_no_worker_messages(Pids))).

test(interruption_at_spawn_commit_cannot_lose_worker,
     [forall(member(Kind,[parallel,first_short,first_options])),timeout(3)]) :-
    with_spawn_plan(interrupt_commit,2,none,
        (catch(invoke(Kind,[receive({}),receive({})]),Error,true),
         assertion(Error==worker_scope_interrupted),
         findall(P,test_worker_scope:scope_spawned(P),Pids),assertion(length(Pids,2)),
         assert_stopped(Pids),assert_no_worker_messages(Pids))).

test(thread_signal_cleanup_finishes_before_rethrow,
     [forall(member(Kind,[parallel,first_short,first_options])),timeout(3)]) :-
    with_signal_caller(Kind,Thread,Events,_,
        (thread_get_message(Events,registered(_),[timeout(1)]),
         thread_get_message(Events,registered(_),[timeout(1)]),
         thread_signal(Thread,throw(worker_scope_interrupted)),
         thread_get_message(Events,finished(Error,Pids),[timeout(1)]),
         assertion(Error==worker_scope_interrupted),assertion(length(Pids,2)),
         assert_stopped(Pids))).

test(actor_termination_reclaims_workers,
     [forall(member(Kind,[parallel,first_short,first_options])),timeout(3)]) :-
    setup_call_cleanup(message_queue_create(Events),
        setup_call_cleanup(
            spawn(test_worker_scope:invoke(Kind,[scope_exit_block(Events),scope_exit_block(Events)]),
                  Caller,[monitor(true),link(false)]),
            (thread_get_message(Events,ready(A),[timeout(1)]),
             thread_get_message(Events,ready(B),[timeout(1)]),
             exit(Caller,scope_cancelled),
             receive({down(Caller,Caller,Reason) -> assertion(Reason==scope_cancelled)},
                     [timeout(1),on_timeout(throw(missing_caller_down))]),
             call_with_time_limit(1,wait_workers_stopped([A,B])),
             assert_stopped([A,B])),
            stop_test_caller(Caller)),
        message_queue_destroy(Events)).

test(unrelated_actor_monitor_and_messages_are_preserved,
     [forall(member(Kind,[parallel,first_short,first_options])),timeout(3)]) :-
    self(Self),
    setup_call_cleanup(
        spawn(receive({ping(From) -> send(From,scope_pong),receive({})}),Other,
              [monitor(true),link(false)]),
        with_spawn_plan(reject(scope_startup_error),2,none,
            (send(Self,scope_unrelated),
             catch(invoke(Kind,[receive({}),receive({})]),Error,true),
             assertion(Error==scope_startup_error),
             assertion(actors:monitor(Self,Other,Other)),
             send(Other,ping(Self)),
             receive({scope_pong -> true},[timeout(1),on_timeout(fail)]),
             receive({scope_unrelated -> true},[timeout(0),on_timeout(fail)]))),
        stop_test_caller(Other)).

test(scope_cut_reclaims_owned_worker, [timeout(3)]) :-
    once(worker_cleanup:with_worker_scope(Scope,
        (worker_cleanup:spawn_worker(Scope,receive({}),Pid),member(_,[first,second])))),
    assert_stopped([Pid]),assert_no_worker_messages([Pid]).

:- end_tests(worker_scope).
