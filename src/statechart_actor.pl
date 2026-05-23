:- module(statechart_actor, [
    statechart_spawn/1,
    statechart_spawn/2,
    statechart_halt/2,
    statechart_halt/3,
    interpret/1,
    interpret_text/1,
    interpret_example/1
]).

/** <module> Statechart Actor Interpreter

Interpreter facade for the Web Prolog statechart profile.

The module keeps the thread-local model/runtime facts that define one running
interpreter instance. Parsing, runtime bookkeeping, and execution are split out
into dedicated helper modules to keep the public actor module compact.
*/

:- use_module(actor).
:- use_module(toplevel_actor).

:- use_module(library(debug)).
:- use_module(library(error)).
:- use_module(library(option)).
:- use_module(actor_io_support, [actor_io_prelude_text/1]).
:- use_module(statechart_model, [statechart_spawn_source/3]).
:- use_module(statechart_runtime, [
    raise/1,
    in/1,
    log/1
]).
:- use_module(statechart_exec, []).
:- use_module(source_loader, [load_source_text/3]).
:- use_module(node_session, [
    set_isotope_session_trace/2,
    isotope_session_trace_enabled/1,
    is_client_session_pid/1
]).

:- op(800, xfx, !).
:- op(200, xfx, @).
:- op(1000, xfy, if).

/* Profile deviations (Web Prolog statechart-actor profile)
   - Root element is <statechart>.
   - Transitions are written as <go> with attributes on/if/to.
   - Executable content and datamodel are Prolog, not ECMAScript.
   - <spawn> invokes a child actor tied to the state lifetime.
*/

% Model
:- thread_local
        state/2,
        to_be_invoked/3,
        parallel/2,
        history/3,
        final/2,
        initial/1,
        initial/2,
        transition/5,
        onexit/2,
        onentry/2,
        n/2.

% Global "variables"
:- thread_local
        running/0,
        event/1,
        internal_queue/1,
        historyValue/2,
        configuration/1,
        states_to_invoke/1,
        invoked/2.

:- thread_local trace_force/1.
:- thread_local trace_client/1.
:- thread_local trace_hook/1.

% Debugging topics exist, but are disabled by default.
:- nodebug(statechart_actor(_)).
:- nodebug(http(_)).

inject_statechart_io_prelude :-
    actor_io_prelude_text(Text),
    load_source_text(Text, statechart_actor, statechart_actor_io_prelude).

:- initialization(inject_statechart_io_prelude, now).


%!  statechart_spawn(-Pid) is det.
%!  statechart_spawn(-Pid, +Options) is det.
%
%   Spawn a statechart interpreter actor.
%
%   Exactly one source option must be supplied:
%
%     - `load_uri(URI)`  or
%     - `load_text(Text)`
statechart_spawn(Pid) :-
    statechart_spawn(Pid, []).

statechart_spawn(Pid, Options0) :-
    exclude(is_statechart_spawn_local_option, Options0, Options1),
    statechart_spawn_source(Options1, SourceGoal, SpawnOptions),
    spawn(SourceGoal, Pid, SpawnOptions),
    maybe_register_statechart_name(Options0, Pid).

is_statechart_spawn_local_option(name(_)).

maybe_register_statechart_name(Options, Pid) :-
    (   option(name(Name), Options)
    ->  register(Name, Pid)
    ;   true
    ).


%!  statechart_halt(+Pid, -Reply) is det.
%!  statechart_halt(+Pid, -Reply, +Timeout) is det.
%
%   Ask a statechart actor to stop gracefully and wait for its
%   acknowledgement. Sends `'$stop'(Self)` so the interpreter
%   runs exit actions for every active state, then replies with
%   `reply(true)`.
%
%   The two-argument form waits indefinitely. Use this when
%   you know the actor is idle (sitting in its receive loop).
%
%   The three-argument form waits at most Timeout seconds.
%   If the actor does not reply in time (e.g. it is stuck in a
%   non-terminating computation), it is forcibly killed with
%   `exit(Pid, kill)` and Reply is unified with `killed`.
%
%   When the actor is supervised, the supervisor's shutdown
%   strategy provides the same escalation automatically — see
%   the `shutdown` option in the child specification.
statechart_halt(To, Reply) :-
    self(Self),
    To ! '$stop'(Self),
    receive({
        reply(Reply) -> true
    }).

statechart_halt(To, Reply, Timeout) :-
    self(Self),
    monitor(To, Ref),
    To ! '$stop'(Self),
    receive({
        reply(Reply) ->
            demonitor(Ref) ;
        down(Ref, To, _Reason) ->
            Reply = killed
    }, [timeout(Timeout), on_timeout((
            exit(To, kill),
            receive({ down(Ref, To, _) -> Reply = killed })
        ))]).


%!  clean is det.
clean :-
    statechart_runtime:clean.


%!  statechart_actor_parse(+Source) is det.
statechart_actor_parse(Source) :-
    statechart_model:statechart_actor_parse(Source).


%!  interpret(+Source) is det.
interpret(Source) :-
    statechart_exec:interpret(Source).


%!  interpret_text(+Text) is det.
interpret_text(Text) :-
    statechart_exec:interpret_text(Text).


%!  interpret_example(+Name) is det.
%
%   Resolve a statechart example from `examples/statecharts/` relative to this
%   module and run it inside the current actor.
interpret_example(Name0) :-
    (   string(Name0)
    ->  atom_string(Name, Name0)
    ;   Name = Name0
    ),
    module_property(statechart_actor, file(ThisFile)),
    file_directory_name(ThisFile, Dir),
    directory_file_path(Dir, '../examples', ExamplesDir),
    directory_file_path(ExamplesDir, 'statecharts', StatechartsDir),
    directory_file_path(StatechartsDir, Name, Source),
    interpret(Source).


%!  with_trace(+Mode, :Goal) is det.
with_trace(logger, Goal) :-
    !,
    setup_call_cleanup(
        assertz(trace_force(true)),
        Goal,
        retractall(trace_force(true))
    ).
with_trace(false, Goal) :-
    !,
    Goal.

%!  set_client_trace(+Enabled) is det.
%
%   Toggle statechart trace emission for the current interactive client
%   session. Intended for UI-side control routed through the owning session.
set_client_trace(Enabled) :-
    must_be(oneof([true, false]), Enabled),
    self(Self),
    set_isotope_session_trace(Self, Enabled).


emit_trace(Event) :-
    (   trace_hook(Goal)
    ->  catch(call(Goal, Event), _, true)
    ;   true
    ),
    (   trace_force(true)
    ->  terminal_output(statechart_trace(Event))
    ;   current_trace_client(ClientPid),
        isotope_session_trace_enabled(ClientPid)
    ->  terminal_output(statechart_trace(Event))
    ;   true
    ).


current_trace_client(ClientPid) :-
    trace_client(ClientPid),
    !.
current_trace_client(ClientPid) :-
    resolve_trace_client(ClientPid),
    assertz(trace_client(ClientPid)).


resolve_trace_client(ClientPid) :-
    self(Self0),
    canonical_pid(Self0, Self),
    (   is_client_session_pid(Self)
    ->  ClientPid = Self
    ;   catch(actor:'$actor_parent'(Parent0), _, fail)
    ->  canonical_pid(Parent0, ClientPid)
    ;   ClientPid = Self
    ).


%!  interpret_parsed(-Root) is det.
interpret_parsed(Root) :-
    statechart_exec:interpret_parsed(Root).


%!  select_transitions(+Event, -Transitions) is semidet.
select_transitions(Event, EnabledTransitions) :-
    statechart_exec:select_transitions(Event, EnabledTransitions).


%!  compute_exit_set(+Transitions, +Configuration, -ExitSet) is det.
compute_exit_set(Transitions, Configuration, StatesToExit) :-
    statechart_exec:compute_exit_set(Transitions, Configuration, StatesToExit).


%!  compute_entry_set(+Transitions, -EntrySet) is det.
compute_entry_set(Transitions, StatesToEnter) :-
    statechart_exec:compute_entry_set(Transitions, StatesToEnter).


%!  root_state(-Root) is semidet.
root_state(Root) :-
    statechart_runtime:root_state(Root).


%!  initial_state(+Root, -Initial) is det.
initial_state(Root, Initial) :-
    statechart_runtime:initial_state(Root, Initial).


%!  update_eventdata(+Event) is det.
update_eventdata(Event) :-
    statechart_runtime:update_eventdata(Event).


%!  microstep(+Transitions) is det.
microstep(EnabledTransitions) :-
    statechart_exec:microstep(EnabledTransitions).


%!  enter_states(+Transitions) is det.
enter_states(EnabledTransitions) :-
    statechart_exec:enter_states(EnabledTransitions).


load_datamodel(Children) :-
    setup_call_cleanup(
        atom_to_memory_file(Children, Handle),
        setup_call_cleanup(
            open_memory_file(Handle, read, Stream),
            read_source(Stream),
            close(Stream)
        ),
        free_memory_file(Handle)
    ).


read_source(Stream) :-
    read(Stream, Term),
    read_source(Term, Stream).

read_source(end_of_file, _Stream) :- !.
read_source(Term, Stream) :-
    expand_and_assert(Term),
    read_source(Stream).


expand_and_assert(Term) :-
    expand_term(Term, ExpandedTerm),
    (   is_list(ExpandedTerm)
    ->  maplist(assert_local, ExpandedTerm)
    ;   assert_local(ExpandedTerm)
    ).


assert_local(:-(Head, Body)) :- !,
    functor(Head, F, N),
    thread_local(F/N),
    assert(:-(Head, Body)).
assert_local(:-Body) :- !,
    call(Body).
assert_local(Fact) :-
    functor(Fact, F, N),
    thread_local(F/N),
    assert(Fact).


:- thread_local num/1.
gennum(N) :-
    (   retract(num(N))
    ->  N1 is N+1,
        assert(num(N1))
    ;   N = 0,
        assert(num(1))
    ).
