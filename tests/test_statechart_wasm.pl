/*  Statechart WASM-port tests

    Exercises the step-style statechart interpreter in src/wasm/.
    Loads existing XML examples that do not rely on <spawn> (which is
    deferred in the WASM port) and asserts configurations after event
    sequences.
*/

:- module(test_statechart_wasm,
          [ test_statechart_wasm/0
          ]).

:- use_module(library(plunit)).
:- use_module('../src/wasm/statechart_wasm.pl').

:- dynamic test_dir/1.
:- prolog_load_context(directory, ThisDir),
   asserta(test_dir(ThisDir)).


test_statechart_wasm :-
    run_tests([statechart_wasm_unit, statechart_wasm_examples]).


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

start_text(Text) :-
    statechart_start(text(Text)).

config(C) :-
    statechart_configuration(C).


:- begin_tests(statechart_wasm_unit).

% A bare-minimum chart: one state, no transitions.
test(minimal_chart, [cleanup(statechart_stop)]) :-
    start_text("<statechart initial=\"s\"><state id=\"s\"/></statechart>"),
    config(C),
    memberchk(s, C),
    assertion(statechart_running).

% External event drives a single transition.
test(simple_transition, [cleanup(statechart_stop)]) :-
    join_lines([
        "<statechart initial=\"a\">",
        "  <state id=\"a\"><go to=\"b\" on=\"go\"/></state>",
        "  <state id=\"b\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    statechart_in(a),
    \+ statechart_in(b),
    statechart_send(go),
    statechart_in(b),
    \+ statechart_in(a).

% Eventless transition guarded by condition fires automatically.
test(eventless_with_condition, [cleanup(statechart_stop)]) :-
    join_lines([
        "<statechart initial=\"a\">",
        "  <datamodel>:- dynamic(ready/0).\nready.\n</datamodel>",
        "  <state id=\"a\"><go to=\"b\" if=\"ready\"/></state>",
        "  <state id=\"b\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    statechart_in(b).

% raise/1 from <onentry> enqueues an internal event.
test(internal_event_via_raise, [cleanup(statechart_stop)]) :-
    join_lines([
        "<statechart initial=\"a\">",
        "  <state id=\"a\">",
        "    <onentry>raise(go)</onentry>",
        "    <go to=\"b\" on=\"go\"/>",
        "  </state>",
        "  <state id=\"b\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    statechart_in(b).

% Reaching the top-level <final> stops the interpreter.
test(top_level_final_stops_interpreter, [cleanup(statechart_stop)]) :-
    join_lines([
        "<statechart initial=\"a\">",
        "  <state id=\"a\"><go to=\"done\" on=\"end\"/></state>",
        "  <final id=\"done\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    assertion(statechart_running),
    statechart_send(end),
    \+ statechart_running.

% Trace hook receives external_event/internal_event/transition events.
test(trace_hook_receives_events, [cleanup((clear_trace_hook, statechart_stop))]) :-
    nb_setval(trace_collected, []),
    set_trace_hook(test_statechart_wasm:collect_trace),
    join_lines([
        "<statechart initial=\"a\">",
        "  <state id=\"a\"><go to=\"b\" on=\"go\"/></state>",
        "  <state id=\"b\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    statechart_send(go),
    nb_getval(trace_collected, RevEvents),
    reverse(RevEvents, Events),
    assertion(memberchk(external_event(go), Events)),
    assertion(memberchk(transition(_, [b], _, _), Events)).

% Datamodel clauses are visible to <go if=...> conditions and actions.
test(datamodel_dynamic_facts_visible, [cleanup(statechart_stop)]) :-
    join_lines([
        "<statechart initial=\"a\">",
        "  <datamodel>:- dynamic(n/1).\nn(0).\n</datamodel>",
        "  <state id=\"a\">",
        "    <go to=\"a\" on=\"inc\">",
        "      n(X), Y is X+1, retract(n(X)), assertz(n(Y))",
        "    </go>",
        "    <go to=\"done\" on=\"check\" if=\"n(3)\"/>",
        "  </state>",
        "  <state id=\"done\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    statechart_send(inc),
    statechart_send(inc),
    statechart_send(inc),
    statechart_send(check),
    statechart_in(done).

:- end_tests(statechart_wasm_unit).


collect_trace(Event) :-
    nb_getval(trace_collected, L),
    nb_setval(trace_collected, [Event|L]).


join_lines(Lines, Text) :-
    atomic_list_concat(Lines, '\n', Text).


:- begin_tests(statechart_wasm_examples).

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

% 08 gcd.xml — datamodel + eventless transitions with conditions.
test(gcd_input_runs_to_completion, [cleanup(statechart_stop)]) :-
    start_example('08 gcd.xml'),
    assertion(statechart_in(init)),
    statechart_send(input([25, 10, 15, 30])),
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
