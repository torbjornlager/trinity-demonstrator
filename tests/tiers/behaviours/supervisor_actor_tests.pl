:- module(test_supervisor, [
       
       run_tests/0

   ]).



%% ===================================================================
%% supervisor_actor_tests.pl — Test suite for supervisor_actor.pl on actor.pl
%% ===================================================================
%%
%% Usage:
%%   $ swipl -g run_tests -g halt actor.pl server.pl supervisor_actor.pl supervisor_actor_tests.pl
%%
%% Or interactively:
%%   ?- [actor, server, supervisor, supervisor_actor_tests].
%%   ?- run_tests.



:- use_module('../../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../../prolog/web_prolog/actors.pl', [receive/1, receive/2, monitor/2, exit/1, exit/2]).
:- use_module('../../../prolog/web_prolog/server_actor.pl', [server_request/3, server_halt/2]).

:- use_module(library(debug)).
:- use_module(library(plunit), [run_tests/1]).

%% Uncomment to see supervisor debug messages:
%% :- debug(supervisor).


%% -------------------------------------------------------------------
%% Worker processes used by tests
%% -------------------------------------------------------------------

%% A worker that blocks forever until killed.
forever :- receive({}).

%% A worker that crashes after Delay seconds.
crasher(Delay) :-
    sleep(Delay),
    exit(crash).

%% A worker that terminates normally after Delay seconds.
finisher(Delay) :-
    sleep(Delay).

%% A fridge server callback (from Chapter 5).
test_fridge(store(F), Fs, ok, [F|Fs]).
test_fridge(take(F), Fs, ok(F), Rs) :- select(F, Fs, Rs), !.
test_fridge(take(_), Fs, not_found, Fs).


%% -------------------------------------------------------------------
%% Test infrastructure
%% -------------------------------------------------------------------

assert_true(Cond, Msg) :-
    (   Cond
    ->  true
    ;   format("  ASSERT FAILED: ~w~n", [Msg]),
        fail
    ).

assert_eq(X, Y, Msg) :-
    (   X == Y
    ->  true
    ;   format("  ASSERT FAILED: ~w~n    expected: ~w~n    got:      ~w~n",
               [Msg, Y, X]),
        fail
    ).

%% Extract pid for a given Id from which_children result.
get_child_pid(Id, Infos, Pid) :-
    member(info(Id, Pid, _, _), Infos), !.
get_child_pid(Id, _, _) :-
    format("  Child ~w not found in children list~n", [Id]),
    fail.

%% Safe cleanup — stop supervisor, ignore errors.
cleanup(SupName) :-
    catch(supervisor_halt(SupName), _, true),
    sleep(0.3).


%% -------------------------------------------------------------------
%% Test runner
%% -------------------------------------------------------------------

run_tests :-
    run_tests([supervisor]).


%% -------------------------------------------------------------------
%% PL-Unit suite
%% -------------------------------------------------------------------

:- begin_tests(supervisor).

test(basic_startup) :-
    test_basic_startup.

test(one_for_one_restart) :-
    test_one_for_one_restart.

test(temporary_not_restarted) :-
    test_temporary_not_restarted.

test(transient_normal_exit) :-
    test_transient_normal_exit.

test(one_for_all) :-
    test_one_for_all.

test(rest_for_one) :-
    test_rest_for_one.

test(dynamic_start_child) :-
    test_dynamic_start_child.

test(dynamic_terminate_and_delete) :-
    test_dynamic_terminate_and_delete.

test(dynamic_restart_child) :-
    test_dynamic_restart_child.

test(server_child) :-
    test_server_child.

test(count_children) :-
    test_count_children.

test(restart_intensity) :-
    test_restart_intensity.

test(nested_supervision) :-
    test_nested_supervision.

test(server_halt_permanent) :-
    test_server_halt_permanent.

test(server_halt_transient) :-
    test_server_halt_transient.

test(cascade_cleanup) :-
    test_cascade_cleanup.


%% -------------------------------------------------------------------
%% Tests
%% -------------------------------------------------------------------

%% 1. Basic startup: start two workers, query, stop.
test_basic_startup :-
    supervisor_spawn([
        child(w1, [start(forever)]),
        child(w2, [start(forever)])
    ], _Pid, [name(t1_sup)]),
    sleep(0.2),
    supervisor_which_children(t1_sup, Children),
    length(Children, 2),
    get_child_pid(w1, Children, P1),
    get_child_pid(w2, Children, P2),
    assert_true(P1 \= undefined, 'w1 should be running'),
    assert_true(P2 \= undefined, 'w2 should be running'),
    assert_true(P1 \= P2, 'w1 and w2 should have different pids'),
    cleanup(t1_sup).


%% 2. One-for-one: crashed child restarts, sibling unchanged.
test_one_for_one_restart :-
    supervisor_spawn([
        child(stable, [start(forever)]),
        child(flaky,  [start(crasher(0.3)), restart(permanent)])
    ], _Pid, [strategy(one_for_one), intensity(5), period(10),
              name(t2_sup)]),
    sleep(0.1),
    supervisor_which_children(t2_sup, C1),
    get_child_pid(stable, C1, StablePid),
    get_child_pid(flaky,  C1, FlakyPid1),
    assert_true(FlakyPid1 \= undefined, 'flaky should be running'),
    %% Wait for crash and restart
    sleep(0.8),
    supervisor_which_children(t2_sup, C2),
    get_child_pid(stable, C2, StablePid2),
    get_child_pid(flaky,  C2, FlakyPid2),
    assert_eq(StablePid2, StablePid, 'stable pid unchanged'),
    assert_true(FlakyPid2 \= FlakyPid1, 'flaky should have new pid'),
    assert_true(FlakyPid2 \= undefined, 'flaky should be running again'),
    cleanup(t2_sup).


%% 3. Temporary child: removed after crash, not restarted.
test_temporary_not_restarted :-
    supervisor_spawn([
        child(keeper, [start(forever)]),
        child(temp,   [start(crasher(0.3)), restart(temporary)])
    ], _Pid, [strategy(one_for_one), intensity(5), period(10),
              name(t3_sup)]),
    sleep(0.1),
    supervisor_which_children(t3_sup, C1),
    length(C1, 2),
    %% Wait for temp to crash
    sleep(0.8),
    supervisor_which_children(t3_sup, C2),
    length(C2, N),
    assert_eq(N, 1, 'only keeper should remain'),
    get_child_pid(keeper, C2, _),
    cleanup(t3_sup).


%% 4. Transient child: not restarted on normal exit.
test_transient_normal_exit :-
    supervisor_spawn([
        child(keeper,  [start(forever)]),
        child(runner,  [start(finisher(0.3)), restart(transient)])
    ], _Pid, [strategy(one_for_one), intensity(5), period(10),
              name(t4_sup)]),
    sleep(0.1),
    supervisor_which_children(t4_sup, C1),
    length(C1, 2),
    %% Wait for runner to finish normally
    sleep(0.8),
    supervisor_which_children(t4_sup, C2),
    get_child_pid(runner, C2, RunnerPid),
    assert_eq(RunnerPid, undefined, 'runner should not be restarted'),
    cleanup(t4_sup).


%% 5. One-for-all: one crash restarts all children.
test_one_for_all :-
    supervisor_spawn([
        child(a, [start(forever)]),
        child(b, [start(forever)]),
        child(c, [start(crasher(0.3)), restart(permanent)])
    ], _Pid, [strategy(one_for_all), intensity(5), period(10),
              name(t5_sup)]),
    sleep(0.1),
    supervisor_which_children(t5_sup, C1),
    get_child_pid(a, C1, Pa1),
    get_child_pid(b, C1, Pb1),
    get_child_pid(c, C1, Pc1),
    %% Wait for c to crash — all should restart
    sleep(0.8),
    supervisor_which_children(t5_sup, C2),
    get_child_pid(a, C2, Pa2),
    get_child_pid(b, C2, Pb2),
    get_child_pid(c, C2, Pc2),
    assert_true(Pa2 \= Pa1, 'a should have new pid'),
    assert_true(Pb2 \= Pb1, 'b should have new pid'),
    assert_true(Pc2 \= Pc1, 'c should have new pid'),
    assert_true(Pa2 \= undefined, 'a should be running'),
    assert_true(Pb2 \= undefined, 'b should be running'),
    assert_true(Pc2 \= undefined, 'c should be running'),
    cleanup(t5_sup).


%% 6. Rest-for-one: crash restarts crashed child and those after it.
test_rest_for_one :-
    supervisor_spawn([
        child(first,  [start(forever)]),
        child(middle, [start(crasher(0.3)), restart(permanent)]),
        child(last,   [start(forever)])
    ], _Pid, [strategy(rest_for_one), intensity(5), period(10),
              name(t6_sup)]),
    sleep(0.1),
    supervisor_which_children(t6_sup, C1),
    get_child_pid(first,  C1, Pf1),
    get_child_pid(middle, C1, Pm1),
    get_child_pid(last,   C1, Pl1),
    %% Wait for middle to crash — middle and last should restart
    sleep(0.8),
    supervisor_which_children(t6_sup, C2),
    get_child_pid(first,  C2, Pf2),
    get_child_pid(middle, C2, Pm2),
    get_child_pid(last,   C2, Pl2),
    assert_eq(Pf2, Pf1, 'first should be unchanged'),
    assert_true(Pm2 \= Pm1, 'middle should have new pid'),
    assert_true(Pl2 \= Pl1, 'last should have new pid'),
    assert_true(Pm2 \= undefined, 'middle should be running'),
    assert_true(Pl2 \= undefined, 'last should be running'),
    cleanup(t6_sup).


%% 7. Dynamic: spawn_child adds a new child.
test_dynamic_start_child :-
    supervisor_spawn([], _Pid, [name(t7_sup)]),
    sleep(0.1),
    supervisor_spawn_child(t7_sup,
        child(dyn1, [start(forever)]),
        Reply1),
    assert_eq(Reply1, ok, 'spawn_child should succeed'),
    sleep(0.1),
    supervisor_which_children(t7_sup, C1),
    length(C1, 1),
    get_child_pid(dyn1, C1, P1),
    assert_true(P1 \= undefined, 'dyn1 should be running'),
    %% Duplicate should fail
    supervisor_spawn_child(t7_sup,
        child(dyn1, [start(forever)]),
        Reply2),
    assert_eq(Reply2, error(already_present), 'duplicate should fail'),
    cleanup(t7_sup).


%% 8. Dynamic: terminate then delete a child.
test_dynamic_terminate_and_delete :-
    supervisor_spawn([
        child(w1, [start(forever)])
    ], _Pid, [name(t8_sup)]),
    sleep(0.1),
    %% Terminate
    supervisor_terminate_child(t8_sup, w1, R1),
    assert_eq(R1, ok, 'terminate should succeed'),
    sleep(0.1),
    supervisor_which_children(t8_sup, C1),
    get_child_pid(w1, C1, Pid1),
    assert_eq(Pid1, undefined, 'w1 should be stopped'),
    %% Delete
    supervisor_delete_child(t8_sup, w1, R2),
    assert_eq(R2, ok, 'delete should succeed'),
    supervisor_which_children(t8_sup, C2),
    length(C2, 0),
    %% Delete non-existent
    supervisor_delete_child(t8_sup, w1, R3),
    assert_eq(R3, error(not_found), 'delete again should fail'),
    cleanup(t8_sup).


%% 9. Dynamic: respawn a terminated child.
test_dynamic_restart_child :-
    supervisor_spawn([
        child(w1, [start(forever)])
    ], _Pid, [name(t9_sup)]),
    sleep(0.1),
    supervisor_which_children(t9_sup, C1),
    get_child_pid(w1, C1, Pid1),
    %% Terminate
    supervisor_terminate_child(t9_sup, w1, _),
    sleep(0.1),
    %% Restart
    supervisor_respawn_child(t9_sup, w1, R1),
    assert_true(R1 = ok(_), 'respawn should succeed'),
    sleep(0.1),
    supervisor_which_children(t9_sup, C2),
    get_child_pid(w1, C2, Pid2),
    assert_true(Pid2 \= undefined, 'w1 should be running'),
    assert_true(Pid2 \= Pid1, 'w1 should have new pid'),
    cleanup(t9_sup).


%% 10. Server child: fridge server under supervision.
test_server_child :-
    supervisor_spawn([
        child(fridge, [
            start(server(test_fridge, [initial_state([])])),
            restart(permanent),
            shutdown(5)
        ])
    ], _Pid, [name(t10_sup)]),
    sleep(0.2),
    %% Send requests to the server via its registered name
    server_request(fridge, store(milk), R1),
    assert_eq(R1, ok, 'store should succeed'),
    server_request(fridge, store(eggs), R2),
    assert_eq(R2, ok, 'store should succeed'),
    server_request(fridge, take(milk), R3),
    assert_eq(R3, ok(milk), 'take should return milk'),
    server_request(fridge, take(bread), R4),
    assert_eq(R4, not_found, 'take bread should be not_found'),
    cleanup(t10_sup).


%% 11. Count children.
test_count_children :-
    supervisor_spawn([
        child(w1, [start(forever)]),
        child(w2, [start(forever)]),
        child(w3, [start(forever)])
    ], _Pid, [name(t11_sup)]),
    sleep(0.1),
    supervisor_count_children(t11_sup, Counts),
    memberchk(specs-3, Counts),
    memberchk(active-3, Counts),
    memberchk(workers-3, Counts),
    memberchk(supervisors-0, Counts),
    cleanup(t11_sup).


%% 12. Restart intensity: supervisor shuts down when exceeded.
test_restart_intensity :-
    %% Allow only 2 restarts per 10 seconds.
    %% The crasher crashes every 0.2s, so restarts will exceed intensity.
    supervisor_spawn([
        child(bomb, [start(crasher(0.2)), restart(permanent)])
    ], SupPid, [strategy(one_for_one), intensity(2), period(10),
                name(t12_sup), monitor(true)]),
    %% Wait for the intensity to be exceeded and supervisor to die.
    GotDown = got(false),
    receive({
        down(_, SupPid, _Reason) ->
            nb_setarg(1, GotDown, true)
    }, [timeout(5)]),
    arg(1, GotDown, DownReceived),
    assert_eq(DownReceived, true, 'should receive down from supervisor').


%% 13. Nested supervision: outer supervisor manages inner supervisor.
test_nested_supervision :-
    InnerSpecs = [
        child(iw1, [start(forever)]),
        child(iw2, [start(forever)])
    ],
    InnerOpts = [strategy(one_for_one), intensity(3), period(10)],
    supervisor_spawn([
        child(inner, [
            start(start_sub_supervisor(InnerSpecs, InnerOpts)),
            type(supervisor),
            restart(permanent),
            shutdown(infinity)
        ]),
        child(outer_worker, [start(forever)])
    ], _Pid, [strategy(one_for_one), intensity(5), period(10),
              name(t13_sup)]),
    sleep(0.3),
    %% Verify outer supervisor has both children
    supervisor_which_children(t13_sup, C1),
    length(C1, 2),
    get_child_pid(inner, C1, InnerPid1),
    get_child_pid(outer_worker, C1, OuterW1),
    assert_true(InnerPid1 \= undefined, 'inner sup should be running'),
    assert_true(OuterW1 \= undefined, 'outer worker should be running'),
    %% Kill the inner supervisor — outer should restart it
    exit(InnerPid1, kill),
    sleep(0.5),
    supervisor_which_children(t13_sup, C2),
    get_child_pid(inner, C2, InnerPid2),
    get_child_pid(outer_worker, C2, OuterW2),
    assert_true(InnerPid2 \= undefined, 'inner sup should be restarted'),
    assert_true(InnerPid2 \= InnerPid1, 'inner sup should have new pid'),
    assert_eq(OuterW2, OuterW1, 'outer worker should be unchanged'),
    cleanup(t13_sup).


%% 16. Cascade cleanup: killing outer supervisor kills inner workers.
test_cascade_cleanup :-
    %% Build a two-level tree and verify that killing the outer
    %% supervisor cascades through the inner supervisor to its workers.
    InnerSpecs = [
        child(deep1, [start(forever)]),
        child(deep2, [start(forever)])
    ],
    InnerOpts = [strategy(one_for_one), intensity(3), period(10)],
    supervisor_spawn([
        child(inner_sup, [
            start(start_sub_supervisor(InnerSpecs, InnerOpts)),
            type(supervisor),
            restart(permanent),
            shutdown(infinity)
        ])
    ], OuterPid, [strategy(one_for_one), intensity(3), period(10),
                  name(t16_sup), monitor(true)]),
    sleep(0.3),
    %% Get the inner supervisor's pid
    supervisor_which_children(t16_sup, C1),
    get_child_pid(inner_sup, C1, InnerPid),
    assert_true(InnerPid \= undefined, 'inner sup should be running'),
    monitor(InnerPid, InnerRef),
    %% Kill the OUTER supervisor
    exit(OuterPid, kill),
    GotDown = got(false),
    receive({
        down(InnerRef, InnerPid, _Reason) ->
            nb_setarg(1, GotDown, true)
    }, [timeout(5)]),
    arg(1, GotDown, InnerDown),
    assert_eq(InnerDown, true, 'inner sup should be down after outer killed').


%% 14. Server child halted via server_halt: permanent restarts.
test_server_halt_permanent :-
    supervisor_spawn([
        child(srv, [
            start(server(test_fridge, [initial_state([milk])])),
            restart(permanent),
            shutdown(5)
        ])
    ], _Pid, [strategy(one_for_one), intensity(5), period(10),
              name(t14_sup)]),
    sleep(0.2),
    %% Verify the server is working
    server_request(srv, take(milk), R1),
    assert_eq(R1, ok(milk), 'should take milk'),
    %% Get original pid
    supervisor_which_children(t14_sup, C1),
    get_child_pid(srv, C1, Pid1),
    %% Halt the server via server_halt (normal exit)
    server_halt(srv, _),
    sleep(0.5),
    %% Permanent: should be restarted with a new pid
    supervisor_which_children(t14_sup, C2),
    get_child_pid(srv, C2, Pid2),
    assert_true(Pid2 \= undefined, 'server should be restarted'),
    assert_true(Pid2 \= Pid1, 'server should have new pid'),
    %% The restarted server should be usable (fresh state)
    server_request(srv, store(eggs), R2),
    assert_eq(R2, ok, 'restarted server should accept requests'),
    cleanup(t14_sup).


%% 15. Server child halted via server_halt: transient does NOT restart.
test_server_halt_transient :-
    supervisor_spawn([
        child(srv2, [
            start(server(test_fridge, [initial_state([])])),
            restart(transient),
            shutdown(5)
        ])
    ], _Pid, [strategy(one_for_one), intensity(5), period(10),
              name(t15_sup)]),
    sleep(0.2),
    %% Verify running
    supervisor_which_children(t15_sup, C1),
    get_child_pid(srv2, C1, Pid1),
    assert_true(Pid1 \= undefined, 'server should be running'),
    %% Halt the server via server_halt (normal exit)
    server_halt(srv2, _),
    sleep(0.5),
    %% Transient + normal exit: should NOT be restarted
    supervisor_which_children(t15_sup, C2),
    get_child_pid(srv2, C2, Pid2),
    assert_eq(Pid2, undefined, 'transient server should not restart on normal exit'),
    cleanup(t15_sup).

:- end_tests(supervisor).
