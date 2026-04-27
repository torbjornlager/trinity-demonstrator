/*  Statechart profile tests */

:- module(test_statechart_profile,
          [ test_statechart_profile/0,
            test_statechart_profile_semantics/0,
            test_statechart_profile_runtime/0
          ]).

:- use_module(library(plunit)).
:- use_module('../statechart_actor.pl').
:- use_module('../actor.pl', [
    spawn/2,
    spawn/3,
    self/1,
    monitor/2,
    send/2,
    receive/1,
    receive/2,
    whereis/2,
    unregister/1,
    exit/2
]).
:- use_module('../toplevel_actor.pl', [
    toplevel_spawn/2,
    toplevel_call/3
]).

:- dynamic statechart_tests_directory/1.
:- prolog_load_context(directory, StatechartTestsDirectory),
   asserta(statechart_tests_directory(StatechartTestsDirectory)).


test_statechart_profile :-
    run_tests([statechart_profile]).

test_statechart_profile_semantics :-
    run_tests([statechart_profile_semantics]).

test_statechart_profile_runtime :-
    run_tests([statechart_profile_runtime]).


:- begin_tests(statechart_profile).

test(parse_simple_root, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-simple.statechart'),
    statechart_actor:state(statechart_actor, null),
    statechart_actor:initial(s1).

test(parse_initial_element, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-initial-element.statechart'),
    statechart_actor:state(Root, null),
    statechart_actor:transition(init(Root), '', true, [Initial|_], _),
    Initial == s1.

test(parse_spawn, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-spawn-toplevel.statechart'),
    statechart_actor:to_be_invoked('spawn-ask-collect', toplevel, Options),
    memberchk(load_list(_), Options).

:- end_tests(statechart_profile).


:- begin_tests(statechart_profile_runtime).

test(runtime_simple) :-
    init_interpreter('test_statecharts/statechart-simple.statechart'),
    statechart_actor:configuration(Config0),
    memberchk(s1, Config0),
    \+ memberchk(s2, Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk(s2, Config1),
    step_event(reset),
    statechart_actor:configuration(Config2),
    memberchk(s1, Config2).

test(runtime_history) :-
    init_interpreter('test_statecharts/statechart-history.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('Play', Config0),
    memberchk('S1', Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    step_event(pause),
    statechart_actor:configuration(Config2),
    memberchk('Interrupted', Config2),
    \+ memberchk('Play', Config2),
    step_event(resume),
    statechart_actor:configuration(Config3),
    memberchk('Play', Config3),
    memberchk('S2', Config3).

test(runtime_parallel_entry) :-
    init_interpreter('test_statecharts/statechart-parallel-idle.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('Start', Config0),
    memberchk('Left', Config0),
    memberchk('Right', Config0).

test(runtime_gcd_finishes) :-
    init_interpreter('test_statecharts/statechart-gcd.statechart'),
    run_eventless(50),
    statechart_actor:configuration(Config1),
    memberchk('Stop', Config1),
    findall(X, statechart_actor:int(X), Xs),
    Xs \= [],
    sort(Xs, [5]).

test(runtime_gcd_output) :-
    init_interpreter('test_statecharts/statechart-gcd.statechart'),
    with_output_to(string(Output), run_eventless(50)),
    sub_string(Output, _, _, _, "5"),
    !.

test(runtime_spawn_toplevel_finishes, [setup(start_statechart_actor('test_statecharts/statechart-spawn-toplevel.statechart', Pid)),
                                      cleanup(stop_statechart_actor(Pid)),
                                      condition((current_predicate(toplevel_actor:toplevel_spawn/2),
                                                 current_predicate(actor:make_id/1)))]) :-
    await_down(Pid, 3.0).

test(runtime_statechart_spawn_load_uri_relative_game) :-
    statechart_tests_directory(TestsDir),
    file_directory_name(TestsDir, RepoDir),
    working_directory(Old, RepoDir),
    setup_call_cleanup(
        true,
        (
            statechart_spawn(Pid, [
                monitor(true),
                load_uri('examples/statecharts/game.xml')
            ]),
            await_output(Pid, 'IDLE', 1.0),
            send(Pid, play),
            await_output(Pid, 'PLAYING', 1.0),
            exit(Pid, stop),
            await_down(Pid, 2.0)
        ),
        working_directory(_, Old)
    ).


test(runtime_statechart_spawn_from_toplevel_load_text) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "    <go to=\"Running\" on=\"play\"/>\n",
        "  </state>\n",
        "  <state id=\"Running\">\n",
        "    <onentry>output('RUNNING')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        toplevel_spawn(ToplevelPid, [session(true), monitor(true)]),
        (
            toplevel_call(ToplevelPid,
                          statechart_spawn(StatechartPid,
                                           [load_text(Text), monitor(true)]),
                          [template(StatechartPid), limit(1)]),
            await_messages([success(ToplevelPid, [StatechartPid], false)], 2.0),
            sleep(0.05),
            toplevel_call(ToplevelPid,
                          flush,
                          [template(true), limit(1)]),
            await_messages([
                terminal_output(ToplevelPid, FlushMsg),
                success(ToplevelPid, [true], false)
            ], 2.0),
            sub_string(FlushMsg, _, _, _, "Shell got output("),
            sub_string(FlushMsg, _, _, _, ",'IDLE')"),
            catch(exit(StatechartPid, stop), _, true),
            !
        ),
        catch((exit(ToplevelPid, stop),
               await_down(ToplevelPid, 2.0)),
              _,
              true)
    ).

test(runtime_statechart_spawn_name_registers_pid) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [
            load_text(Text),
            monitor(true),
            name(test_named_statechart)
        ]),
        (
            whereis(test_named_statechart, Visible),
            assertion(Pid =@= Visible)
        ),
        (
            unregister(test_named_statechart),
            catch(exit(Pid, stop), _, true),
            catch(await_down(Pid, 2.0), _, true)
        )
    ).

test(runtime_statechart_halt_reply_and_shutdown) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [load_text(Text), monitor(true)]),
        (
            statechart_halt(Pid, Reply, 1),
            assertion(Reply == true),
            await_down(Pid, 2.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

test(runtime_statechart_halt_timeout_defaults_reply_true) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>sleep(2)</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [load_text(Text), monitor(true)]),
        (
            statechart_halt(Pid, Reply, 0.1),
            assertion(Reply == killed)
        ),
        (
            catch(exit(Pid, kill), _, true),
            catch(await_down(Pid, 2.0), _, true)
        )
    ).

test(runtime_statechart_halt_timeout_honors_custom_on_timeout) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>sleep(2)</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [load_text(Text), monitor(true)]),
        (
            statechart_halt(Pid, Reply, 0.1),
            assertion(Reply == killed)
        ),
        (
            catch(exit(Pid, kill), _, true),
            catch(await_down(Pid, 2.0), _, true)
        )
    ).

test(runtime_statechart_writeln_uses_actor_io_path) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>writeln('IDLE')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        toplevel_spawn(ToplevelPid, [session(true), monitor(true)]),
        (
            toplevel_call(ToplevelPid,
                          statechart_spawn(StatechartPid,
                                           [load_text(Text), monitor(true)]),
                          [template(StatechartPid), limit(1)]),
            await_messages([
                success(ToplevelPid, [StatechartPid], false),
                terminal_output(StatechartPid, 'IDLE')
            ], 2.0),
            catch(exit(StatechartPid, stop), _, true)
        ),
        catch((exit(ToplevelPid, stop),
               await_down(ToplevelPid, 2.0)),
              _,
              true)
    ).

test(runtime_statechart_trace_true_emits_terminal_trace_messages) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "    <go to=\"Running\" on=\"play\"/>\n",
        "  </state>\n",
        "  <state id=\"Running\">\n",
        "    <onentry>output('RUNNING')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    once(statechart_spawn(Pid, [load_text(Text), monitor(true), trace(true)])),
    once(receive({
        terminal_output(Pid, statechart_trace(_Trace0)) -> true
    }, [timeout(2), on_timeout(fail)])),
    once(send(Pid, play)),
    once(receive({
        terminal_output(Pid, statechart_trace(transition('Idle', ['Running'], _, _))) -> true
    }, [timeout(2), on_timeout(fail)])),
    once(exit(Pid, stop)),
    await_down(Pid, 2.0).

test(runtime_statechart_trace_follows_client_session_setting) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Idle\">\n",
        "  <state id=\"Idle\">\n",
        "    <onentry>output('IDLE')</onentry>\n",
        "    <go to=\"Running\" on=\"play\"/>\n",
        "  </state>\n",
        "  <state id=\"Running\">\n",
        "    <onentry>output('RUNNING')</onentry>\n",
        "  </state>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        toplevel_spawn(ToplevelPid, [session(true), monitor(true)]),
        (
            toplevel_call(ToplevelPid,
                          statechart_actor:set_client_trace(true),
                          [template(true), limit(1)]),
            await_messages([success(ToplevelPid, [true], false)], 2.0),
            toplevel_call(ToplevelPid,
                          statechart_spawn(StatechartPid,
                                           [load_text(Text), monitor(true)]),
                          [template(StatechartPid), limit(1)]),
            await_messages([
                success(ToplevelPid, [StatechartPid], false),
                terminal_output(StatechartPid, statechart_trace(_))
            ], 2.0),
            catch(exit(StatechartPid, stop), _, true)
        ),
        catch((exit(ToplevelPid, stop),
               await_down(ToplevelPid, 2.0)),
              _,
              true)
    ).

test(runtime_statechart_raise_onentry_triggers_internal_transition) :-
    atomics_to_string([
        "<statechart datamodel=\"web-prolog\" initial=\"Start\">\n",
        "  <parallel id=\"Start\">\n",
        "    <state id=\"Pinger\">\n",
        "      <onentry>raise(hello)</onentry>\n",
        "      <go on=\"hello\">writeln('PING')</go>\n",
        "    </state>\n",
        "    <state id=\"Ponger\"/>\n",
        "  </parallel>\n",
        "</statechart>\n"
    ], Text),
    setup_call_cleanup(
        statechart_spawn(Pid, [load_text(Text), monitor(true)]),
        (
            actor:receive({
                terminal_output(Pid, 'PING') -> true
            }, [timeout(2), on_timeout(fail)]),
            catch(exit(Pid, stop), _, true),
            await_down(Pid, 2.0)
        ),
        catch(exit(Pid, stop), _, true)
    ).

:- end_tests(statechart_profile_runtime).


:- begin_tests(statechart_profile_semantics).

test(exit_set_pause, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-history.statechart'),
    Config = ['Play','S2'],
    Transition = t('Play', ['Interrupted'], []),
    statechart_actor:compute_exit_set([Transition], Config, ExitSet),
    sort(ExitSet, Sorted),
    sort(['Play','S2'], Expected),
    Sorted == Expected.

test(entry_set_resume_history, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-history.statechart'),
    statechart_actor:retractall(statechart_actor:historyValue(_,_)),
    statechart_actor:assertz(statechart_actor:historyValue('H', ['S2'])),
    Transition = t('Interrupted', ['H'], []),
    statechart_actor:compute_entry_set([Transition], EntrySet),
    sort(EntrySet, Sorted),
    sort(['Play','S2'], Expected),
    Sorted == Expected.

test(entry_set_parallel_initial, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-parallel-idle.statechart'),
    statechart_actor:state(Root, null),
    statechart_actor:assertz(statechart_actor:state(dummy, Root)),
    Transition = t(dummy, ['Start'], []),
    statechart_actor:compute_entry_set([Transition], EntrySet),
    sort(EntrySet, Sorted),
    sort(['Start','Left','Right'], Expected),
    Sorted == Expected.

test(exit_set_parallel_exit, [setup(statechart_actor:clean), cleanup(statechart_actor:clean)]) :-
    parse_statechart_fixture('test_statecharts/statechart-parallel-exit.statechart'),
    Config = ['Start','Left','Right'],
    Transition = t('Left', ['Done'], []),
    statechart_actor:compute_exit_set([Transition], Config, ExitSet),
    sort(ExitSet, Sorted),
    sort(['Start','Left','Right'], Expected),
    Sorted == Expected.

test(trace_golden_simple, [setup(enable_trace_capture),
                           cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('S1', Config0),
    step_event(go),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    collected_trace(Traces),
    memberchk(microstep(Exit, Entry), Traces),
    same_set(Exit, ['S1']),
    same_set(Entry, ['S2']),
    !.

test(trace_golden_history_pause_resume, [setup(enable_trace_capture),
                                         cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-history.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('S1', Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    step_event(pause),
    statechart_actor:configuration(Config2),
    memberchk('Interrupted', Config2),
    step_event(resume),
    statechart_actor:configuration(Config3),
    memberchk('S2', Config3),
    collected_trace(Traces0),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces0), Steps),
    length(Steps, 3),
    nth1(2, Steps, microstep(ExitPause, EntryPause)),
    same_set(ExitPause, ['Play','S2']),
    same_set(EntryPause, ['Interrupted']),
    nth1(3, Steps, microstep(ExitResume, EntryResume)),
    same_set(ExitResume, ['Interrupted']),
    same_set(EntryResume, ['Play','S2']),
    !.

test(trace_golden_parallel_exit, [setup(enable_trace_capture),
                                  cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-parallel-exit.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('Left', Config0),
    step_event(x),
    statechart_actor:configuration(Config1),
    memberchk('Done', Config1),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    last(Steps, microstep(ExitSet, EntrySet)),
    same_set(ExitSet, ['Start','Left','Right']),
    same_set(EntrySet, ['Done']),
    !.

test(trace_golden_deep_history, [setup(enable_trace_capture),
                                 cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-deep-history.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('S1', Config0),
    step_event(play),
    statechart_actor:configuration(Config1),
    memberchk('S2', Config1),
    step_event(pause),
    statechart_actor:configuration(Config2),
    memberchk('Interrupted', Config2),
    step_event(resume),
    statechart_actor:configuration(Config3),
    memberchk('S2', Config3),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    length(Steps, 3),
    nth1(3, Steps, microstep(ExitResume, EntryResume)),
    same_set(ExitResume, ['Interrupted']),
    same_set(EntryResume, ['Play','Inner','S2']),
    !.

test(trace_golden_parallel_conflict, [setup(enable_trace_capture),
                                      cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-parallel-conflict.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('A1', Config0),
    memberchk('B1', Config0),
    step_event(x),
    statechart_actor:configuration(Config1),
    memberchk('Done', Config1),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    last(Steps, microstep(ExitSet, EntrySet)),
    same_set(ExitSet, ['Start','A','A1','B','B1']),
    same_set(EntrySet, ['Done']),
    !.

test(trace_golden_parallel_compatible, [setup(enable_trace_capture),
                                        cleanup(disable_trace_capture)]) :-
    init_interpreter('test_statecharts/statechart-trace-parallel-compatible.statechart'),
    statechart_actor:configuration(Config0),
    memberchk('L1', Config0),
    memberchk('R1', Config0),
    step_event(x),
    statechart_actor:configuration(Config1),
    memberchk('L2', Config1),
    memberchk('R2', Config1),
    collected_trace(Traces),
    findall(microstep(Exit, Entry), member(microstep(Exit, Entry), Traces), Steps),
    last(Steps, microstep(ExitSet, EntrySet)),
    same_set(ExitSet, ['L1','R1']),
    same_set(EntrySet, ['L2','R2']),
    !.

:- end_tests(statechart_profile_semantics).

start_statechart_actor(File, Pid) :-
    resolve_statechart_fixture(File, Source),
    spawn(statechart_actor:interpret(Source), Pid, [monitor(true)]),
    sleep(0.05).

stop_statechart_actor(Pid) :-
    exit(Pid, stop),
    sleep(0.05).

start_statechart_actor_with_stdout(File, Pid, OldStdout) :-
    self(Self),
    set_stdout_capture(Self, OldStdout),
    resolve_statechart_fixture(File, Source),
    spawn(statechart_actor:interpret(Source), Pid, [monitor(true)]),
    sleep(0.05).

parse_statechart_fixture(File) :-
    resolve_statechart_fixture(File, Source),
    statechart_actor:statechart_actor_parse(Source).

resolve_statechart_fixture(File, Source) :-
    (   statechart_tests_directory(TestDir),
        absolute_file_name(File, Source, [
            relative_to(TestDir),
            access(read),
            file_errors(fail)
        ])
    ->  true
    ;   Source = File
    ).

stop_statechart_actor_with_stdout(Pid, OldStdout) :-
    exit(Pid, stop),
    reset_stdout_capture(OldStdout),
    sleep(0.05).

await_down(Pid, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_down_until(Pid, Deadline).

await_down_until(Pid, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        down(Pid, _) -> true;
        down(_, Pid, _) -> true;
        after(Remaining) -> fail;
        _ -> test_statechart_profile:await_down_until(Pid, Deadline)
    }).

await_echo(Expected, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_echo_until(Expected, Deadline).

await_echo_until(Expected, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        echo(Expected) -> true;
        after(Remaining) -> fail;
        _ -> test_statechart_profile:await_echo_until(Expected, Deadline)
    }).

await_output(Pid, Data, Timeout) :-
    get_time(Now),
    Deadline is Now + Timeout,
    await_output_until(Pid, Data, Deadline).

await_output_until(Pid, Data, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    receive({
        output(Pid, Data) -> true;
        terminal_output(Pid, Data) -> true;
        output(_, _) -> test_statechart_profile:await_output_until(Pid, Data, Deadline);
        terminal_output(_, _) -> test_statechart_profile:await_output_until(Pid, Data, Deadline);
        after(Remaining) -> fail;
        _ -> test_statechart_profile:await_output_until(Pid, Data, Deadline)
    }).

await_messages(Patterns, Timeout) :-
    thread_self(Self),
    get_time(Now),
    Deadline is Now + Timeout,
    await_messages_until(Self, Patterns, Deadline).

await_messages_until(_, [], _) :-
    !.
await_messages_until(Self, Patterns0, Deadline) :-
    get_time(Now),
    Remaining is max(0.0, Deadline - Now),
    thread_get_message(Self, Message, [timeout(Remaining)]),
    (   select(Pattern, Patterns0, Patterns),
        Message = Pattern
    ->  await_messages_until(Self, Patterns, Deadline)
    ;   await_messages_until(Self, Patterns0, Deadline)
    ).

set_stdout_capture(Self, OldStdout) :-
    (   actors:stdout(OldStdout)
    ->  true
    ;   OldStdout = none
    ),
    retractall(actors:stdout(_)),
    assertz(actors:stdout(Self)).

reset_stdout_capture(OldStdout) :-
    retractall(actors:stdout(_)),
    (   OldStdout \= none
    ->  assertz(actors:stdout(OldStdout))
    ;   true
    ).

:- dynamic collected_trace/1.

enable_trace_capture :-
    retractall(collected_trace(_)),
    asserta(collected_trace([])),
    retractall(statechart_actor:trace_hook(_)),
    assertz(statechart_actor:trace_hook(test_statechart_profile:capture_trace)).

disable_trace_capture :-
    retractall(statechart_actor:trace_hook(_)),
    retractall(collected_trace(_)).

capture_trace(microstep(Exit, Entry)) :-
    append_trace(microstep(Exit, Entry)).
capture_trace(_).

append_trace(Trace) :-
    retract(collected_trace(Traces)),
    append(Traces, [Trace], NewTraces),
    assertz(collected_trace(NewTraces)).

same_set(A, B) :-
    sort(A, SA),
    sort(B, SB),
    SA == SB.

step_event(Event) :-
    statechart_actor:update_eventdata(Event),
    statechart_actor:select_transitions(Event, EnabledTransitions),
    statechart_actor:microstep(EnabledTransitions).

init_interpreter(File) :-
    statechart_actor:clean,
    parse_statechart_fixture(File),
    statechart_actor:root_state(Root),
    assertz(statechart_actor:configuration([])),
    assertz(statechart_actor:states_to_invoke([])),
    assertz(statechart_actor:running),
    assertz(statechart_actor:state(dummy, Root)),
    statechart_actor:initial_state(Root, Initial),
    message_queue_create(Internal),
    assertz(statechart_actor:internal_queue(Internal)),
    statechart_actor:enter_states([t(dummy, [Initial], [])]).

run_eventless(0) :- !.
run_eventless(Limit) :-
    (   statechart_actor:select_transitions(null, Enabled)
    ->  statechart_actor:microstep(Enabled),
        Limit1 is Limit - 1,
        run_eventless(Limit1)
    ;   true
    ).
