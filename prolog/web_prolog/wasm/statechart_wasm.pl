:- module(statechart_wasm, [
    statechart_start/1,
    statechart_stop/0,
    statechart_send/1,
    statechart_running/0,
    statechart_configuration/1,
    statechart_in/1,
    statechart_halt_reason/1,
    emit_trace/1,
    set_trace_hook/1,
    clear_trace_hook/0
]).

/** <module> Statechart Interpreter Facade (SWI-WASM port)

A step-style statechart interpreter intended to run inside SWI-Prolog
compiled to WebAssembly.  The host (JS, or a desktop test harness)
loads a chart with `statechart_start/1`, then drives execution one
event at a time with `statechart_send/1`.

Unlike the desktop statechart actor:

  - There is no actor mailbox, no `receive/1`, no thread.  Each call
    is synchronous and runs to quiescence before returning.  The chart is
    addressed as the pid `statechart`: a spawned child's replies route back
    in as external events rather than being read from a mailbox.
  - `<spawn>` IS executed: invoke/1 spawns a browser worker actor/toplevel
    through swi_wasm_actor_bridge (locally or on a remote node) and the chart
    drives it with the full actor/toplevel API (Pid ! Msg, toplevel_call,
    monitor, ...).  Children are cancelled when their owning state exits.
  - I/O (write, writeln, format) goes to the default user_output
    stream, which the WASM runtime captures via its on_output callback.

There is only ever one interpreter alive at a time in a given Prolog
instance; calling `statechart_start/1` twice resets state.
*/

% Pull library(wasm) into this module's namespace when available so
% that `:=/2`, `await/2`, and the `#/1` form are looked up here rather
% than only in the user module.  Silently no-op on desktop where the
% library doesn't exist (sleep/1 below detects the absence at runtime
% and degrades to a trace event).
:- catch(use_module(library(wasm)), _, true).

:- use_module(library(option)).
:- use_module(statechart_wasm_model, [
    statechart_wasm_parse_text/1
]).
:- use_module(statechart_wasm_runtime, [
    clean/0 as runtime_clean,
    exit_interpreter/0,
    raise/1,
    in/1,
    log/1
]).
:- use_module(statechart_wasm_exec, [
    start_parsed/1,
    send_event/1
]).

:- op(800, xfx, !).
:- op(200, xfx, @).
:- op(1000, xfy, if).
% library(wasm) operators.  Declared locally so this file parses on
% desktop (where library(wasm) doesn't exist) as well as inside SWI-
% WASM (where library(wasm) redeclares them with the same fixity).
:- op(990, xfx, :=).
:- op(100, fx,  #).

% Model facts (mirrors statechart_actor's layout, but owned here).
:- dynamic
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

% Runtime state.
:- dynamic
        running/0,
        event/1,
        internal_queue/1,
        historyValue/2,
        configuration/1,
        states_to_invoke/1,
        invoked/2,
        num/1,
        last_halt_reason/1,
        % Indicators of predicates a <datamodel> asserted, so clean/0 can
        % abolish them and not leak one chart's data/rules into the next.
        datamodel_predicate/1.

% Trace hook (a callable; called with one argument: the event).
:- dynamic trace_hook/1.


% Chart scripts run in this module's namespace (see script/1 in the
% runtime).  In SWI-WASM, library(wasm) already provides a sleep/1
% that yields to the JS event loop via promise_sleep/await when the
% engine is in an async context — exactly what we want.  Importing
% library(wasm) above makes that visible as `statechart_wasm:sleep/1`,
% so chart actions that call `sleep(N)` simply work.
%
% On desktop (no library(wasm)), we install a no-op fallback so the
% microstep budget can bound runaway time-driven charts instead of
% getting an existence_error at every tick.  Decision made at load
% time so we don't shadow the imported sleep when it exists.
:- catch(redefine_system_predicate(sleep(_)), _, true).
:- dynamic sleep/1.
:- (   catch(current_predicate(wasm:sleep/1), _, fail)
   ->  % SWI-WASM: delegate to library(wasm)'s sleep/1, which yields
       % to the JS event loop via promise_sleep + await when the
       % engine is in async context (e.g. inside Prolog.forEach).
       assertz((sleep(N) :- wasm:sleep(N)))
   ;   % Desktop / no library(wasm): install a no-op so script(sleep(N))
       % returns immediately and the microstep budget can bound time-
       % driven charts.
       assertz((sleep(_) :- emit_trace(sleep_skipped)))
   ).


%!  statechart_start(+Source) is det.
%
%   Parse a statechart and run the interpreter to quiescence.
%   Source is one of:
%
%     - `text(Text)`: literal XML in an atom or string.
%     - `stream(Stream)`: an open input stream (the caller closes it).
%
%   Any previously-installed chart is discarded first.

statechart_start(text(Text)) :-
    !,
    cancel_delayed_events,
    runtime_clean,
    retractall(last_halt_reason(_)),
    statechart_wasm_parse_text(Text),
    start_parsed(_Root),
    record_natural_halt_reason,
    flush_user_streams.
statechart_start(stream(Stream)) :-
    !,
    cancel_delayed_events,
    runtime_clean,
    retractall(last_halt_reason(_)),
    statechart_wasm_model:statechart_wasm_parse_stream(Stream),
    start_parsed(_Root),
    record_natural_halt_reason,
    flush_user_streams.
statechart_start(Source) :-
    throw(error(domain_error(statechart_source, Source),
                context(statechart_start/1,
                        'expected text(Text) or stream(Stream)'))).


%!  statechart_stop is det.
%
%   Run exit actions for the current configuration and clear state.
%   Safe to call when no chart is running.

statechart_stop :-
    cancel_delayed_events,
    (   running
    ->  retractall(running),
        catch(exit_interpreter, _, true)
    ;   true
    ),
    runtime_clean,
    retractall(last_halt_reason(_)),
    assertz(last_halt_reason(stopped)).


% Browser-statechart equivalents of the actor calls used by chart scripts.
% A delayed event is scheduled by the hosting page and is cancelled by its
% stable id on state exit.  The host callback re-enters statechart_send/1.
self(statechart).

send(statechart, Event) :-
    !,
    statechart_send(Event).
%  Any other target is a spawned child actor/toplevel: forward to the
%  actor bridge (loaded in the main engine when a chart that spawns runs;
%  see preloadSwiWasmStatechart).  Lets chart scripts do `Pid ! Msg` to a
%  worker, e.g. `ponger ! ping(Self)`.
send(Pid, Message) :-
    swi_wasm_actor_bridge:send(Pid, Message).
send(statechart, Event, Options) :-
    !,
    option(delay(Delay), Options, 0),
    (   Delay =:= 0
    ->  statechart_send(Event)
    ;   option(id(Id), Options, delayed_event),
        term_string(Event, EventText),
        term_string(Id, IdText),
        Scheduled := wasmStatechartSchedule(#EventText, #Delay, #IdText),
        Scheduled == true
    ).
send(Pid, Message, Options) :-
    swi_wasm_actor_bridge:send(Pid, Message, Options).

%  `Pid ! Message` stays local: send/2 routes the `statechart` target into
%  the chart's own event queue (and forwards every other target to the
%  bridge), so a child told `ping(Self)` with self/1 = statechart replies
%  back into the chart.
Pid ! Message :-
    send(Pid, Message).

cancel(Id) :-
    term_string(Id, IdText),
    Cancelled := wasmStatechartCancel(#IdText),
    Cancelled == true.

cancel_delayed_events :-
    catch((Cancelled := wasmStatechartCancelAll(),
           Cancelled == true),
          _,
          true).


%  monitor/2 and demonitor must record the chart (pid `statechart`) as the
%  watcher, not `main` (the bridge's default), so a monitored child's
%  down(Ref, Pid, Reason) routes back into the chart as an external event
%  (deliverSwiWasmActorDown -> sendSwiWasmActorMessage -> chart event).
%  Kept local so the delegation directive below skips them.
monitor(Pid, Ref) :-
    swi_wasm_actor_bridge:make_ref(Ref),
    term_string(Pid, PidText),
    term_string(Ref, RefText),
    Promise := swiWasmStatechartMonitor(#PidText, #RefText),
    await(Promise, Monitored),
    Monitored == true.

demonitor(Ref) :-
    demonitor(Ref, []).
demonitor(Ref, _Options) :-
    term_string(Ref, RefText),
    Promise := swiWasmStatechartDemonitor(#RefText),
    await(Promise, _).


%  Expose the full actor / toplevel / server / supervisor / rpc API to chart
%  scripts, delegated to the bridge -- matching the desktop chart actor,
%  which imports `actors` + `toplevel_actors` wholesale.  Generated as one
%  passthrough clause per PI rather than written out; anything already
%  defined locally (self/1, send/2,3, (!)/2, cancel/1) is skipped so its
%  chart-specific behaviour wins.  Clause bodies resolve
%  swi_wasm_actor_bridge:Goal at call time, so loading is fine on desktop
%  where the bridge module is absent (the goal simply errors if reached).
%
%  Deliberately NOT delegated: receive/1,2 (the WASM chart is event-driven,
%  not a threaded actor with a mailbox, so an in-script blocking receive is
%  meaningless) and with_io_target/2 (a meta-predicate that call/1's its
%  goal locally — delegating would run it in the wrong module).
:- forall( member(Name/Arity,
               [ spawn/1, spawn/2, spawn/3, spawn_worker_actor/2,
                 actors/1, make_ref/1, canonical_pid/2,
                 monitor/2, demonitor/1, demonitor/2,
                 exit/1, exit/2,
                 register/2, register_service/2,
                 unregister/1, unregister_service/1,
                 whereis/2, whereis_service/2, respond/2,
                 toplevel_spawn/1, toplevel_spawn/2,
                 toplevel_call/2, toplevel_call/3,
                 toplevel_next/1, toplevel_next/2,
                 toplevel_halt/2, toplevel_stop/1, toplevel_abort/1,
                 statechart_spawn/1, statechart_spawn/2,
                 output/1, output/2, terminal_output/1, terminal_output/2,
                 input/2, input/3, flush/0,
                 server_spawn/3, server_spawn/4,
                 server_request/3, server_request/4,
                 server_promise/3, server_promise/4,
                 server_yield/2, server_yield/3, server_yield/4,
                 server_upgrade/2, server_halt/2, server_stop/2,
                 supervisor_spawn/2, supervisor_spawn/3,
                 supervisor_spawn_child/3, supervisor_terminate_child/3,
                 supervisor_delete_child/3, supervisor_respawn_child/3,
                 supervisor_which_children/2, supervisor_count_children/2,
                 supervisor_halt/1, supervisor_stop/1,
                 rpc/2, rpc/3, promise/3, promise/4, yield/2, yield/3 ]),
           ( functor(Head, Name, Arity),
             (   predicate_property(Head, defined)
             ->  true
             ;   assertz((Head :- swi_wasm_actor_bridge:Head))
             )
           ) ).


%!  statechart_send(+Event) is det.
%
%   Inject one external event and run to quiescence.  No-op if the
%   chart has terminated, and a true no-op (halt reason stays `idle`)
%   if no chart has been started yet.

statechart_send(_Event) :-
    \+ running,
    \+ last_halt_reason(_),
    !.
statechart_send(Event) :-
    send_event(Event),
    record_natural_halt_reason,
    flush_user_streams.


%!  statechart_running is semidet.
%
%   True iff the chart has not reached a top-level final state and has
%   not been stopped.

statechart_running :-
    running.


%!  statechart_configuration(-Configuration) is det.
%
%   Configuration is the current set of active states (a list).

statechart_configuration(Configuration) :-
    (   configuration(C)
    ->  Configuration = C
    ;   Configuration = []
    ).


%!  statechart_in(+State) is semidet.
%
%   True iff State is in the current configuration.

statechart_in(State) :-
    in(State).


%!  statechart_halt_reason(-Reason) is det.
%
%   Reason explains why the interpreter is no longer running.  Values:
%
%     - `running`           — the chart is still alive
%     - `final`             — reached a top-level <final> normally
%     - `budget_exhausted`  — the microstep budget tripped
%     - `stopped`           — host called statechart_stop/0
%     - `idle`              — no chart has been started

statechart_halt_reason(Reason) :-
    (   running
    ->  Reason = running
    ;   last_halt_reason(R)
    ->  Reason = R
    ;   Reason = idle
    ).


%!  set_trace_hook(:Goal) is det.
%!  clear_trace_hook is det.
%
%   Install or remove a hook that receives every trace event the
%   interpreter emits (transitions, microsteps, configuration
%   updates, external/internal events, unmatched events,
%   `script` executions, `log` messages).  Goal is called as
%   `call(Goal, Event)`.  Errors/failures in the hook are
%   swallowed.

set_trace_hook(Goal) :-
    retractall(trace_hook(_)),
    assertz(trace_hook(Goal)).

clear_trace_hook :-
    retractall(trace_hook(_)).


%!  emit_trace(+Event) is det.
%
%   Called from the runtime/exec layers as `statechart_wasm:emit_trace/1`.
%   Forwards to the installed trace hook, if any.

emit_trace(Event) :-
    (   trace_hook(Goal)
    ->  catch(call(Goal, Event), _, true)
    ;   true
    ).


% Charts may emit output via writeln/format/print etc.  In the SWI-WASM
% host, the on_output callback only fires when SWI's stdio buffer is
% flushed; format/2 without an explicit ~n at end-of-string can leave
% the message stranded.  Call this at every host-visible boundary
% (statechart_start, statechart_send) so the buffer reaches JS before
% the synchronous query returns.
flush_user_streams :-
    catch(flush_output(user_output), _, true),
    catch(flush_output(user_error), _, true).


% After run_to_quiescence finishes, decide why we stopped.  The
% interpreter is no longer running because either:
%   - It reached a top-level <final>, OR
%   - The microstep budget tripped (which retracts running too).
% The exec layer asserts `last_halt_reason(budget_exhausted)` in that
% case; we leave it alone.  Otherwise the natural outcome is `final`.
record_natural_halt_reason :-
    (   running
    ->  true
    ;   last_halt_reason(_)
    ->  true
    ;   assertz(last_halt_reason(final))
    ).
