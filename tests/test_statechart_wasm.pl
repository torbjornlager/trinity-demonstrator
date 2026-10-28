/* Consumer example coverage for the pinned SWI-WASM statechart runtime.
   Runtime unit and spawn tests are loaded from the external package. */

:- module(test_statechart_wasm,
          [ test_statechart_wasm/0
          ]).

:- use_module(library(plunit)).

:- getenv('SWI_WASM_PACKAGE_ROOT', BrowserPackage),
   directory_file_path(BrowserPackage, 'tests/test_statechart_wasm.pl', RuntimeTests),
   use_module(RuntimeTests, []).

:- use_module(browser_prolog(statechart_wasm)).

:- dynamic test_dir/1.
:- prolog_load_context(directory, ThisDir),
   asserta(test_dir(ThisDir)).


test_statechart_wasm :-
    swi_wasm_statechart_tests:run,
    run_tests([statechart_wasm_examples]).


example_path(Name, Path) :-
    test_dir(Dir),
    file_directory_name(Dir, RepoDir),
    directory_file_path(RepoDir, 'examples/statecharts', ExDir),
    directory_file_path(ExDir, Name, Path).

start_example(Name) :-
    example_path(Name, Path),
    setup_call_cleanup(
        open(Path, read, Stream),
        statechart_start(stream(Stream)),
        close(Stream)).

config(C) :-
    statechart_configuration(C).

setup_statechart_shared_db :-
    ignore(catch(delete_import_module(statechart_wasm, wasm_shared_db), _, true)),
    ignore(catch(abolish(wasm_shared_db:shared_fact/1), _, true)),
    ignore(catch(abolish(wasm_shared_db:local_label/1), _, true)),
    ignore(catch(abolish(wasm_shared_db:shared_transition_enabled/0), _, true)),
    assertz(wasm_shared_db:shared_fact(browser_shared_db)),
    assertz(wasm_shared_db:local_label(browser_shared_db)),
    assertz(wasm_shared_db:shared_transition_enabled).

cleanup_statechart_shared_db :-
    statechart_stop,
    ignore(catch(delete_import_module(statechart_wasm, wasm_shared_db), _, true)),
    ignore(catch(abolish(wasm_shared_db:shared_fact/1), _, true)),
    ignore(catch(abolish(wasm_shared_db:local_label/1), _, true)),
    ignore(catch(abolish(wasm_shared_db:shared_transition_enabled/0), _, true)).



collect_trace(Event) :-
    nb_getval(trace_collected, L),
    nb_setval(trace_collected, [Event|L]).


:- begin_tests(statechart_wasm_examples).

test(deferred_commands_are_replayed, [cleanup(statechart_stop)]) :-
    start_example('07 deferred-events.xml'),
    statechart_send(command(open)),
    statechart_send(command(close)),
    assertion(statechart_wasm:postponed_queue(
        [command(open), command(close)])),
    statechart_send(initialised),
    assertion(statechart_in(ready)),
    assertion(statechart_wasm:postponed_queue([])).

% 01 pause-and-resume.xml — hierarchy + history.
test(pause_and_resume, [cleanup(statechart_stop)]) :-
    start_example('01 pause-and-resume.xml'),
    config(C0),
    assertion(memberchk(s1, C0)),
    assertion(memberchk(play, C0)),
    assertion(memberchk(game, C0)),
    statechart_send(play),
    assertion(statechart_in(s2)),
    statechart_send(pause),
    assertion(statechart_in(interrupted)),
    \+ statechart_in(play),
    statechart_send(resume),
    assertion(statechart_in(play)),
    assertion(statechart_in(s2)),
    statechart_send(stop),
    \+ statechart_running.

% 03 emotions.xml — nested <parallel> regions.
test(emotions_initial_configuration, [cleanup(statechart_stop)]) :-
    start_example('03 emotions.xml'),
    forall(member(S, [agent, emotions, 'AF-dimension', anger,
                      'AS-dimension', anticipation, behavior, attacking]),
           assertion(statechart_in(S))).

test(emotions_event_e_advances_all_three_regions, [cleanup(statechart_stop)]) :-
    start_example('03 emotions.xml'),
    statechart_send(e),
    assertion(statechart_in(fear)),
    assertion(statechart_in(surprise)),
    assertion(statechart_in(fleeing)).

% 06 parallel.xml — both regions must finish before done(p) fires.
test(parallel_both_regions_must_finish, [cleanup(statechart_stop)]) :-
    start_example('06 parallel.xml'),
    assertion(statechart_in(s1c1)),
    assertion(statechart_in(s2c1)),
    statechart_send(e),
    assertion(statechart_in(s1c2)),
    assertion(statechart_in(s2c2)),
    statechart_send(e),
    statechart_send(e),
    % After three e's both regions have entered their <final> children
    % (s1c4 and s2c4); the parallel's done(p) internal event then drives
    % the chart to the top-level final, stopping the interpreter.
    \+ statechart_running.

% 02 spaghetti.xml — hierarchy + many transitions, including exits.
test(spaghetti_g_exits_via_lcca, [cleanup(statechart_stop)]) :-
    start_example('02 spaghetti.xml'),
    assertion(statechart_in(s11)),
    statechart_send(g),
    assertion(statechart_in(s211)),
    statechart_send(g),
    % from s211, on g -> s0, which re-enters s11 via its initials.
    assertion(statechart_in(s11)).

test(spaghetti_h_reaches_top_final, [cleanup(statechart_stop)]) :-
    start_example('02 spaghetti.xml'),
    statechart_send(g),
    statechart_send(h),
    \+ statechart_running.

% 09 gcd.xml — datamodel + eventless transitions with conditions.
test(gcd_integers_runs_to_completion, [cleanup(statechart_stop)]) :-
    start_example('09 gcd.xml'),
    assertion(statechart_in(init)),
    statechart_send(integers([25, 10, 15, 30])),
    % The 'run' state's eventless transitions chew through the list,
    % then move to the final 'stop'.
    \+ statechart_running,
    findall(X, statechart_wasm:int(X), Xs),
    sort(Xs, [5]).

% 04 clock.xml — time-driven, infinite raise/sleep loop.  Under the
% actor runtime each tick is paced by sleep(1) on its own thread; in
% the WASM port sleep/1 is a no-op so the chart degenerates into an
% unbounded internal-event loop.  The microstep budget must halt it.
test(clock_loop_is_halted_by_budget,
     [setup(statechart_wasm_exec:set_microstep_budget(50)),
      cleanup((statechart_wasm_exec:set_microstep_budget(default),
               statechart_stop))]) :-
    start_example('04 clock.xml'),
    % start_parsed already drained run_to_quiescence; the chart is
    % no longer running because the budget tripped.
    \+ statechart_running.

% 05 pingpong.xml — same hazard as clock: parallel regions trade
% raise(ping)/raise(pong) through sleep(1).  Budget must halt it.
test(pingpong_loop_is_halted_by_budget,
     [setup(statechart_wasm_exec:set_microstep_budget(50)),
      cleanup((statechart_wasm_exec:set_microstep_budget(default),
               statechart_stop))]) :-
    start_example('05 pingpong.xml'),
    \+ statechart_running.

% Trace hook sees the budget_exhausted event when the cap trips.
test(budget_exhausted_emits_trace_event,
     [setup(statechart_wasm_exec:set_microstep_budget(20)),
      cleanup((statechart_wasm_exec:set_microstep_budget(default),
               clear_trace_hook,
               statechart_stop))]) :-
    nb_setval(trace_collected, []),
    set_trace_hook(test_statechart_wasm:collect_trace),
    start_example('04 clock.xml'),
    nb_getval(trace_collected, RevEvents),
    reverse(RevEvents, Events),
    assertion(memberchk(budget_exhausted, Events)).

:- end_tests(statechart_wasm_examples).
