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
    is synchronous and runs to quiescence before returning.
  - `<spawn>` elements parse but do not execute (deferred).
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
        last_halt_reason/1.

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
    runtime_clean,
    retractall(last_halt_reason(_)),
    statechart_wasm_parse_text(Text),
    start_parsed(_Root),
    record_natural_halt_reason,
    flush_user_streams.
statechart_start(stream(Stream)) :-
    !,
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
    (   running
    ->  retractall(running),
        catch(exit_interpreter, _, true)
    ;   true
    ),
    runtime_clean,
    retractall(last_halt_reason(_)),
    assertz(last_halt_reason(stopped)).


%!  statechart_send(+Event) is det.
%
%   Inject one external event and run to quiescence.  No-op if the
%   chart has terminated.

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
