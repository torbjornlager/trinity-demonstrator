/*  Statechart WASM-port tests

    Exercises the step-style statechart interpreter served to SWI-WASM.
    Loads existing XML examples and asserts configurations after event
    sequences.  The statechart_wasm_spawn block drives <spawn> (actor and
    toplevel) with a mocked actor bridge, since the real bridge needs Web
    Workers that only exist in the browser.
*/

:- module(test_statechart_wasm,
          [ test_statechart_wasm/0
          ]).

:- use_module(library(plunit)).
:- use_module('../prolog/web_prolog/wasm/statechart_wasm.pl').

:- dynamic test_dir/1.
:- prolog_load_context(directory, ThisDir),
   asserta(test_dir(ThisDir)).


test_statechart_wasm :-
    run_tests([statechart_wasm_unit, statechart_wasm_examples,
               statechart_wasm_spawn]).


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

% statechart_send/1 before any statechart_start/1 is a true no-op: the
% halt reason stays `idle`, not `final`.  Force a clean idle state
% first since earlier tests' cleanup(statechart_stop) leaves
% last_halt_reason(stopped) behind.
test(send_before_start_stays_idle) :-
    retractall(statechart_wasm:running),
    retractall(statechart_wasm:last_halt_reason(_)),
    assertion(statechart_halt_reason(idle)),
    statechart_send(go),
    assertion(statechart_halt_reason(idle)).

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


/*  <spawn> execution.

    invoke/1 spawns browser worker actors/toplevels through
    swi_wasm_actor_bridge and addresses the chart as the pid `statechart`,
    so replies route back in as external events.  The real bridge needs
    Web Workers (browser only); here a mock records the calls invoke/1 and
    the chart scripts make, binds a deterministic pid, and lets the test
    inject the replies a real child would send.
*/

:- dynamic mock_call/1.

%   Record a bridge call.  Asserted clauses run in the swi_wasm_actor_bridge
%   module, so qualify mock_call back to this test module.
record_mock_call(Term) :-
    assertz(test_statechart_wasm:mock_call(Term)).

setup_mock_bridge :-
    retractall(mock_call(_)),
    assertz((swi_wasm_actor_bridge:toplevel_spawn(worker_actor(1), Opts) :-
                test_statechart_wasm:record_mock_call(toplevel_spawn(Opts)))),
    assertz((swi_wasm_actor_bridge:spawn(Goal, worker_actor(1), _Opts) :-
                test_statechart_wasm:record_mock_call(spawn(Goal)))),
    assertz((swi_wasm_actor_bridge:register(Name, Pid) :-
                test_statechart_wasm:record_mock_call(register(Name, Pid)))),
    assertz((swi_wasm_actor_bridge:send(To, Msg) :-
                test_statechart_wasm:record_mock_call(send(To, Msg)))),
    assertz((swi_wasm_actor_bridge:send(To, Msg, _) :-
                test_statechart_wasm:record_mock_call(send(To, Msg)))),
    assertz((swi_wasm_actor_bridge:toplevel_call(Pid, Goal, Opts) :-
                test_statechart_wasm:record_mock_call(toplevel_call(Pid, Goal, Opts)))),
    assertz((swi_wasm_actor_bridge:toplevel_next(Pid) :-
                test_statechart_wasm:record_mock_call(toplevel_next(Pid)))).

teardown_mock_bridge :-
    catch(abolish(swi_wasm_actor_bridge:toplevel_spawn/2), _, true),
    catch(abolish(swi_wasm_actor_bridge:spawn/3), _, true),
    catch(abolish(swi_wasm_actor_bridge:register/2), _, true),
    catch(abolish(swi_wasm_actor_bridge:send/2), _, true),
    catch(abolish(swi_wasm_actor_bridge:send/3), _, true),
    catch(abolish(swi_wasm_actor_bridge:toplevel_call/3), _, true),
    catch(abolish(swi_wasm_actor_bridge:toplevel_next/1), _, true),
    retractall(mock_call(_)),
    statechart_stop.


:- begin_tests(statechart_wasm_spawn).

% <spawn type="toplevel"> (cf. examples/statecharts/10 spawn-toplevel.xml):
% invoke spawns a toplevel addressed to the chart, spawned(Pid) drives a
% transition that calls toplevel_call, and success(...) replies streamed
% back as external events drive the chart through to its final state.
test(toplevel_spawn_drives_chart,
     [setup(setup_mock_bridge), cleanup(teardown_mock_bridge)]) :-
    join_lines([
        "<statechart initial=\"sac\">",
        "  <state id=\"sac\" initial=\"ask\">",
        "    <spawn type=\"toplevel\" exit=\"false\">",
        "      q(X) :- p(X).  p(a). p(b).",
        "    </spawn>",
        "    <state id=\"ask\">",
        "      <go to=\"collect\" on=\"spawned(Pid)\">toplevel_call(Pid, q(X), [limit(1)])</go>",
        "    </state>",
        "    <state id=\"collect\">",
        "      <go to=\"collect\" on=\"success(Pid, _Data, true)\">toplevel_next(Pid)</go>",
        "      <go to=\"final\" on=\"success(_, _Data, false)\"/>",
        "    </state>",
        "  </state>",
        "  <final id=\"final\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    % invoke/1 spawned a toplevel and addressed it to the chart.
    assertion(mock_call(toplevel_spawn(Opts))),
    assertion(memberchk(target(statechart), Opts)),
    % spawned(worker_actor(1)) fired ask -> collect and ran toplevel_call.
    assertion(mock_call(toplevel_call(worker_actor(1), q(_), [limit(1)]))),
    assertion(statechart_in(collect)),
    % Stream the toplevel's answers back as it would over the bridge.
    statechart_send(success(worker_actor(1), a, true)),
    assertion(mock_call(toplevel_next(worker_actor(1)))),
    assertion(statechart_in(collect)),
    statechart_send(success(worker_actor(1), b, false)),
    \+ statechart_running.

% <spawn type="actor" goal="..."> (cf. examples/statecharts/09 spawn-actor.xml):
% invoke spawns the actor, spawned(Pid) registers it, <onentry> sends it a
% ping addressed to `statechart` (self/1), and the actor's pong reply --
% injected here as an external event -- advances the chart.
test(actor_spawn_register_ping_pong,
     [setup(setup_mock_bridge), cleanup(teardown_mock_bridge)]) :-
    join_lines([
        "<statechart initial=\"p\">",
        "  <state id=\"p\" initial=\"init\">",
        "    <spawn type=\"actor\" goal=\"ponger\">ponger :- true.</spawn>",
        "    <state id=\"init\">",
        "      <go to=\"pinger\" on=\"spawned(Pid)\">register(ponger, Pid)</go>",
        "    </state>",
        "    <state id=\"pinger\">",
        "      <onentry>self(Self), ponger ! ping(Self)</onentry>",
        "      <go to=\"done\" on=\"pong\"/>",
        "    </state>",
        "  </state>",
        "  <final id=\"done\"/>",
        "</statechart>"
    ], Text),
    start_text(Text),
    assertion(mock_call(spawn(ponger))),
    assertion(mock_call(register(ponger, worker_actor(1)))),
    % self/1 is `statechart`, so the ping is addressed to the chart and the
    % pong reply will route back as an external event.
    assertion(mock_call(send(ponger, ping(statechart)))),
    assertion(statechart_in(pinger)),
    statechart_send(pong),
    \+ statechart_running.

% Without the actor bridge loaded, <spawn> degrades to a no-op (invoke/1's
% current_predicate guard), exactly as before -- no error, chart just lacks
% the child.  Guards the desktop/no-runtime path.
test(spawn_without_bridge_is_a_noop, [cleanup(statechart_stop)]) :-
    join_lines([
        "<statechart initial=\"s\">",
        "  <state id=\"s\">",
        "    <spawn type=\"actor\" goal=\"child\">child :- true.</spawn>",
        "  </state>",
        "</statechart>"
    ], Text),
    start_text(Text),
    assertion(statechart_in(s)),
    assertion(statechart_running).

:- end_tests(statechart_wasm_spawn).
