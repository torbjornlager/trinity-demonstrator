/*  Statechart desktop/WASM conformance tests

    The SWI-WASM statechart port (src/wasm/) is a near-verbatim fork of
    the desktop statechart actor's model/exec/runtime modules
    (src/statechart_{model,exec,runtime}.pl), differing only in queue
    representation, driver, and <spawn> handling (see module docs).

    These tests drive the same example chart through both
    implementations with the same external-event sequence and assert
    that the resulting configurations agree at every step, pinning
    parity between the two forks so future edits to one side don't
    silently diverge from the other.

    Charts are restricted to ones with no <spawn>, <datamodel> script,
    or sleep/1 (raise/1 and parallel-region <done> events are fine —
    both forks process those through their internal queue).
*/

:- module(test_statechart_conformance,
          [ test_statechart_conformance/0
          ]).

:- use_module(library(plunit)).
:- use_module('../src/statechart_model', [
    statechart_actor_parse_text/1
]).
:- use_module('../src/statechart_runtime', [
    clean/0 as desktop_clean,
    root_state/1,
    initial_state/2,
    update_eventdata/1,
    invoke/1
]).
:- use_module('../src/statechart_exec', [
    select_transitions/2,
    microstep/1,
    enter_states/1
]).
:- use_module('../src/wasm/statechart_wasm.pl', [
    statechart_start/1,
    statechart_stop/0,
    statechart_send/1,
    statechart_configuration/1
]).

:- dynamic conformance_dir/1.
:- prolog_load_context(directory, ThisDir),
   asserta(conformance_dir(ThisDir)).

% statechart_model's model_generate/2 calls statechart_actor:gennum/1 to
% mint fresh state ids for synthetic <initial>/<final>/<parallel> nodes.
% Normally defined alongside the actor's other runtime state in
% statechart_actor.pl; provide a standalone copy here so this test
% doesn't have to pull in the whole actor module (and its actor.pl /
% toplevel_actor.pl / node_session.pl dependency chain).
:- dynamic statechart_actor:num/1.

statechart_actor:gennum(N) :-
    (   retract(statechart_actor:num(N))
    ->  N1 is N+1,
        assertz(statechart_actor:num(N1))
    ;   N = 0,
        assertz(statechart_actor:num(1))
    ).


test_statechart_conformance :-
    run_tests([statechart_conformance]).


example_path(Name, Path) :-
    conformance_dir(Dir),
    file_directory_name(Dir, RepoDir),
    directory_file_path(RepoDir, 'examples/statecharts', ExDir),
    directory_file_path(ExDir, Name, Path).

read_example(Name, Text) :-
    example_path(Name, Path),
    read_file_to_string(Path, Text, []).


% ---- Desktop driver -----------------------------------------------
%
% Mirrors statechart_exec's interpret_parsed/main_event_loop, but
% without the blocking actor receive/1: external events are injected
% directly, and quiescence (eventless transitions, internal-event
% drain, pending invokes) is driven by desktop_run_to_quiescence/1
% with a microstep budget, mirroring the WASM port's
% run_to_quiescence/0.

desktop_init(Text) :-
    desktop_clean,
    statechart_actor_parse_text(Text),
    root_state(Root),
    assertz(statechart_actor:configuration([])),
    assertz(statechart_actor:states_to_invoke([])),
    assertz(statechart_actor:running),
    assertz(statechart_actor:state(dummy, Root)),
    initial_state(Root, Initial),
    message_queue_create(Internal),
    assertz(statechart_actor:internal_queue(Internal)),
    enter_states([t(dummy, [Initial], [])]),
    desktop_run_to_quiescence(1000).

desktop_send(Event) :-
    (   \+ statechart_actor:running
    ->  true
    ;   update_eventdata(Event),
        (   select_transitions(Event, EnabledTransitions)
        ->  microstep(EnabledTransitions)
        ;   true
        ),
        desktop_run_to_quiescence(1000)
    ).

desktop_run_to_quiescence(0) :- !.
desktop_run_to_quiescence(N) :-
    (   \+ statechart_actor:running
    ->  true
    ;   select_transitions(null, EnabledTransitions)
    ->  microstep(EnabledTransitions),
        N1 is N - 1,
        desktop_run_to_quiescence(N1)
    ;   statechart_actor:internal_queue(Internal),
        thread_get_message(Internal, Event, [timeout(0)])
    ->  update_eventdata(Event),
        (   select_transitions(Event, EnabledTransitions)
        ->  microstep(EnabledTransitions)
        ;   true
        ),
        N1 is N - 1,
        desktop_run_to_quiescence(N1)
    ;   statechart_actor:states_to_invoke(States),
        States \= []
    ->  maplist(invoke, States),
        retractall(statechart_actor:states_to_invoke(_)),
        assertz(statechart_actor:states_to_invoke([])),
        desktop_run_to_quiescence(N)
    ;   true
    ).

desktop_configuration(C) :-
    (   statechart_actor:configuration(C0)
    ->  C = C0
    ;   C = []
    ).

desktop_running :-
    statechart_actor:running.


% ---- Comparison helper ----------------------------------------------

same_set(A, B) :-
    sort(A, SA),
    sort(B, SB),
    SA == SB.

assert_same_configuration(Step) :-
    desktop_configuration(DC),
    statechart_configuration(WC),
    assertion(same_set(DC, WC)),
    %  Surface the diverging sets in the test failure message.
    (   same_set(DC, WC)
    ->  true
    ;   format("Configuration mismatch after ~w: desktop=~p wasm=~p~n",
               [Step, DC, WC])
    ).


:- begin_tests(statechart_conformance,
                [ setup(true),
                  cleanup((catch(desktop_clean, _, true),
                           catch(statechart_stop, _, true)))
                ]).

% 01 pause-and-resume.xml — hierarchy + history, no datamodel scripts.
test(pause_and_resume_parity) :-
    read_example('01 pause-and-resume.xml', Text),
    desktop_init(Text),
    statechart_start(text(Text)),
    assert_same_configuration(start),

    desktop_send(play), statechart_send(play),
    assert_same_configuration(play),

    desktop_send(pause), statechart_send(pause),
    assert_same_configuration(pause),

    desktop_send(resume), statechart_send(resume),
    assert_same_configuration(resume),

    desktop_send(stop), statechart_send(stop),
    assert_same_configuration(stop),
    \+ desktop_running.

% 06 parallel.xml — both regions must reach <final> before the
% parallel's internal done(p) event fires, draining each fork's
% internal-event queue identically.
test(parallel_done_event_parity) :-
    read_example('06 parallel.xml', Text),
    desktop_init(Text),
    statechart_start(text(Text)),
    assert_same_configuration(start),

    desktop_send(e), statechart_send(e),
    assert_same_configuration(e1),

    desktop_send(e), statechart_send(e),
    assert_same_configuration(e2),

    desktop_send(e), statechart_send(e),
    assert_same_configuration(e3),
    \+ desktop_running,
    !.

:- end_tests(statechart_conformance).
