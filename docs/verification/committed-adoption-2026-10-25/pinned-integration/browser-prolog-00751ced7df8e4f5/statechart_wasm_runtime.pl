:- module(statechart_wasm_runtime, [
    clean/0,
    root_state/1,
    initial_state/2,
    exit_interpreter/0,
    schedule_after_transitions/1,
    cancel_after_transitions/1,
    execute_content/1,
    enqueue_internal_event/1,
    dequeue_internal_event/1,
    initialise_event_processing/0,
    begin_macrostep/0,
    ensure_macrostep/0,
    postpone_event/1,
    reoffer_postponed_events/1,
    update_eventdata/1,
    configuration_add/1,
    configuration_delete/1,
    states_to_invoke_add/1,
    states_to_invoke_delete/1,
    update_history_value/2,
    ordered_add/3,
    entry_order/3,
    exit_order/3,
    is_parallel/1,
    is_compound/1,
    is_atomic/1,
    is_history/1,
    is_final/1,
    is_statechart_element/1,
    is_in_final_state/1,
    find_LCCA/2,
    proper_ancestor/3,
    ancestor/3,
    is_descendant/2,
    has_parent/2,
    has_descendant_in_set/2,
    invoke/1,
    cancel_invoked_child/1,
    raise/1,
    in/1,
    log/1,
    script/1,
    check_chart_goal/1,
    call_chart_goal/1
]).

/** <module> Statechart Runtime Helpers (SWI-WASM port)

Runtime bookkeeping, ancestry helpers, and built-in predicates for the
SWI-WASM statechart interpreter. The runtime state itself lives as
dynamic facts in `statechart_wasm`.

Differences from the desktop `statechart_runtime`:

  - The internal event queue is a list held in a dynamic fact instead of
    a SWI message queue (no threads in WASM).
  - `invoke/1` spawns browser worker actors and behaviours through
    swi_wasm_actor_bridge (a no-op only when that bridge is absent);
    cancel_invoked_child/1 terminates them when their owning state exits.
  - No dependency on `actor` or `toplevel_actor`; the bridge is reached
    by module-qualified calls so this file still loads without it.
*/

:- use_module(library(lists)).
:- use_module(library(option), [select_option/3]).


%!  clean is det.
clean :-
    cancel_all_after_transitions,
    %  Terminate any children spawned via <spawn>, consuming each invoked/2
    %  record (retract, not just iterate) so a child is cancelled exactly
    %  once across process_states_to_exit, exit_interpreter and here.  Covers
    %  statechart_start replacing a chart that was never explicitly stopped,
    %  so workers never outlive their chart (cf. the desktop runtime, which
    %  exits invoked children).
    forall(retract(statechart_wasm:invoked(_, Pid)), cancel_invoked_child(Pid)),
    %  Abolish predicates a previous <datamodel> contributed, so its data
    %  and rules do not leak into the next chart.
    forall(retract(statechart_wasm:datamodel_predicate(F/N)),
           catch(abolish(statechart_wasm:F/N), _, true)),
    retractall(statechart_wasm:state(_, _)),
    retractall(statechart_wasm:to_be_invoked(_, _, _)),
    retractall(statechart_wasm:initial(_)),
    retractall(statechart_wasm:transition(_, _, _, _, _)),
    retractall(statechart_wasm:after_transition(_, _, _, _, _, _)),
    retractall(statechart_wasm:defer(_, _, _)),
    retractall(statechart_wasm:parallel(_, _)),
    retractall(statechart_wasm:history(_, _, _)),
    retractall(statechart_wasm:final(_, _)),
    retractall(statechart_wasm:onexit(_, _)),
    retractall(statechart_wasm:onentry(_, _)),
    retractall(statechart_wasm:n(_, _)),
    retractall(statechart_wasm:num(_)),
    retractall(statechart_wasm:event(_)),
    retractall(statechart_wasm:historyValue(_, _)),
    retractall(statechart_wasm:configuration(_)),
    retractall(statechart_wasm:states_to_invoke(_)),
    retractall(statechart_wasm:invoked(_, _)),
    retractall(statechart_wasm:after_timer(_, _, _)),
    retractall(statechart_wasm:internal_queue(_)),
    retractall(statechart_wasm:postponed_queue(_)),
    retractall(statechart_wasm:macrostep_start(_)),
    retractall(statechart_wasm:running).


root_state(Root) :-
    statechart_wasm:state(Root, null),
    !.

initial_state(Root, Initial) :-
    (   statechart_wasm:initial(Initial)
    ->  true
    ;   throw(error(missing_initial_state(Root), _))
    ).

exit_interpreter :-
    statechart_wasm:configuration(Configuration),
    predsort(exit_order, Configuration, StatesToExit),
    exit_interpreter(StatesToExit).

exit_interpreter([]).
exit_interpreter([State|States]) :-
    cancel_after_transitions(State),
    forall(statechart_wasm:onexit(State, Content), execute_content(Content)),
    forall(retract(statechart_wasm:invoked(State, Pid)), cancel_invoked_child(Pid)),
    configuration_delete(State),
    (   is_final(State),
        has_parent(State, Parent),
        is_statechart_element(Parent)
    ->  true
    ;   exit_interpreter(States)
    ).


%!  schedule_after_transitions(+State) is det.
%
%   Arm every timed transition whose source is State.  Browser timers call
%   statechart_send/1 with a private event.  A zero delay is queued locally
%   so it still runs after the current microstep rather than re-entering the
%   interpreter during state entry.
schedule_after_transitions(State) :-
    forall(statechart_wasm:after_transition(State, Key, Delay, _, _, _),
           schedule_after_transition(State, Key, Delay)).

schedule_after_transition(State, Key, Delay) :-
    fresh_after_ref(Ref),
    Event = '$statechart_after'(State, Key, Ref),
    assertz(statechart_wasm:after_timer(State, Key, Ref)),
    catch(schedule_after_event(Delay, Event, Ref),
          Error,
          ( retractall(statechart_wasm:after_timer(State, Key, Ref)),
            throw(Error)
          )).

schedule_after_event(0, Event, _Ref) :-
    !,
    enqueue_internal_event(Event).
schedule_after_event(Delay, Event, Ref) :-
    statechart_wasm:self(Self),
    statechart_wasm:send(Self, Event, [delay(Delay), id(Ref)]).

fresh_after_ref(Ref) :-
    catch(once(statechart_wasm:make_ref(Ref)), _, fail),
    !.
fresh_after_ref(ref(N)) :-
    flag(wp_wasm_after_ref_counter, N, N + 1).


%!  cancel_after_transitions(+State) is det.
%
%   Invalidate first, then ask the host scheduler to cancel.  A callback
%   already queued by the host carries the old reference and is ignored.
cancel_after_transitions(State) :-
    forall(retract(statechart_wasm:after_timer(State, _Key, Ref)),
           catch(statechart_wasm:cancel(Ref), _, true)).

cancel_all_after_transitions :-
    forall(retract(statechart_wasm:after_timer(_State, _Key, Ref)),
           catch(statechart_wasm:cancel(Ref), _, true)).

execute_content(Content) :-
    maplist(call, Content).

enqueue_internal_event(Event) :-
    retract(statechart_wasm:internal_queue(Q)),
    append(Q, [Event], Q1),
    assertz(statechart_wasm:internal_queue(Q1)).

dequeue_internal_event(Event) :-
    retract(statechart_wasm:internal_queue([Event|Q])),
    assertz(statechart_wasm:internal_queue(Q)).

initialise_event_processing :-
    retractall(statechart_wasm:postponed_queue(_)),
    assertz(statechart_wasm:postponed_queue([])),
    retractall(statechart_wasm:macrostep_start(_)),
    assertz(statechart_wasm:macrostep_start([])).

begin_macrostep :-
    statechart_wasm:configuration(Configuration),
    retractall(statechart_wasm:macrostep_start(_)),
    assertz(statechart_wasm:macrostep_start(Configuration)).

ensure_macrostep :-
    (   statechart_wasm:macrostep_start(_)
    ->  true
    ;   begin_macrostep
    ).

postpone_event(Event) :-
    retract(statechart_wasm:postponed_queue(Events)),
    append(Events, [Event], NewEvents),
    assertz(statechart_wasm:postponed_queue(NewEvents)).

reoffer_postponed_events(Events) :-
    retract(statechart_wasm:macrostep_start(StartConfiguration)),
    statechart_wasm:configuration(Configuration),
    Configuration \== StartConfiguration,
    statechart_wasm:postponed_queue(Events),
    Events \= [],
    retractall(statechart_wasm:postponed_queue(_)),
    assertz(statechart_wasm:postponed_queue([])),
    maplist(enqueue_internal_event, Events),
    assertz(statechart_wasm:macrostep_start(Configuration)).

update_eventdata(Event) :-
    retractall(statechart_wasm:event(_)),
    assertz(statechart_wasm:event(Event)).

configuration_add(State) :-
    statechart_wasm:configuration(Configuration),
    ordered_add(State, Configuration, NewConfiguration),
    (   NewConfiguration == Configuration
    ->  true
    ;   retractall(statechart_wasm:configuration(_)),
        assertz(statechart_wasm:configuration(NewConfiguration))
    ).

configuration_delete(State) :-
    statechart_wasm:configuration(Configuration),
    subtract(Configuration, [State], NewConfiguration),
    retractall(statechart_wasm:configuration(_)),
    assertz(statechart_wasm:configuration(NewConfiguration)).

states_to_invoke_add(State) :-
    statechart_wasm:states_to_invoke(StatesToInvoke),
    ordered_add(State, StatesToInvoke, NewStatesToInvoke),
    (   NewStatesToInvoke == StatesToInvoke
    ->  true
    ;   retractall(statechart_wasm:states_to_invoke(_)),
        assertz(statechart_wasm:states_to_invoke(NewStatesToInvoke))
    ).

states_to_invoke_delete(State) :-
    statechart_wasm:states_to_invoke(StatesToInvoke),
    subtract(StatesToInvoke, [State], NewStatesToInvoke),
    retractall(statechart_wasm:states_to_invoke(_)),
    assertz(statechart_wasm:states_to_invoke(NewStatesToInvoke)).

update_history_value(H, SS) :-
    retractall(statechart_wasm:historyValue(H, _)),
    assertz(statechart_wasm:historyValue(H, SS)).

ordered_add(State, States, NewStates) :-
    (   memberchk(State, States)
    ->  NewStates = States
    ;   predsort(entry_order, [State|States], NewStates)
    ).

entry_order(=, State, State).
entry_order(>, State1, State2) :-
    statechart_wasm:n(N1, State1),
    statechart_wasm:n(N2, State2),
    N1 > N2,
    !.
entry_order(<, _State1, _State2).

exit_order(=, State, State).
exit_order(<, State1, State2) :-
    statechart_wasm:n(N1, State1),
    statechart_wasm:n(N2, State2),
    N1 > N2,
    !.
exit_order(>, _State1, _State2).

is_parallel(State) :-
    statechart_wasm:parallel(State, _).

is_compound(State) :-
    has_parent(_Child, State).

is_atomic(State) :-
    \+ has_parent(_Child, State).

is_history(State) :-
    statechart_wasm:history(State, _, _).

is_final(State) :-
    statechart_wasm:final(State, _).

is_statechart_element(State) :-
    statechart_wasm:state(State, null).

is_in_final_state(S) :-
    is_compound(S),
    has_parent(Child, S),
    is_final(Child),
    statechart_wasm:configuration(Configuration),
    memberchk(Child, Configuration).
is_in_final_state(S) :-
    is_parallel(S),
    forall(has_parent(Child, S), is_in_final_state(Child)).

find_LCCA([S|Ss], Ancestor) :-
    proper_ancestor(S, null, Ancestor),
    forall(member(S0, Ss), is_descendant(S0, Ancestor)),
    !.

proper_ancestor(StateID, RootID, ParentID) :-
    has_parent(StateID, ParentID),
    ParentID \= RootID.
proper_ancestor(StateID, RootID, AncestorID) :-
    has_parent(StateID, ParentID),
    ParentID \= RootID,
    proper_ancestor(ParentID, RootID, AncestorID).

ancestor(StateID, _RootID, StateID).
ancestor(StateID, RootID, AncestorID) :-
    proper_ancestor(StateID, RootID, AncestorID).

is_descendant(StateID, AncestorID) :-
    proper_ancestor(StateID, null, AncestorID).

has_parent(State, Parent) :-
    statechart_wasm:state(State, Parent).
has_parent(State, Parent) :-
    statechart_wasm:parallel(State, Parent).
has_parent(State, Parent) :-
    statechart_wasm:final(State, Parent).
has_parent(State, Parent) :-
    statechart_wasm:history(State, Parent, _).

has_descendant_in_set(State, States) :-
    member(Active, States),
    (   Active == State
    ;   is_descendant(Active, State)
    ),
    !.

%   Execute deferred <spawn> elements for State.  The desktop engine
%   spawns inside the node's actor system; the WASM port spawns browser
%   worker actors and behaviours through swi_wasm_actor_bridge and addresses
%   the chart itself as the pid `statechart` (so worker replies route back
%   in as external events -- see send(statechart, _) in the bridge and
%   routeSwiWasmActorMessage in the coordinator).  spawned(Pid) is
%   enqueued so the chart can transition on it, mirroring the desktop
%   contract.  Anything past invoke/1 is excluded from the byte-equivalence
%   guard, so this divergence from the desktop runtime is intentional.
%
%   Guarded by current_predicate/1: when the bridge is absent (the chart
%   ran without the actor runtime, or on desktop) invoke stays a no-op
%   and <spawn> is silently skipped, exactly as before.
invoke(State) :-
    statechart_wasm:to_be_invoked(State, toplevel, Options),
    current_predicate(swi_wasm_actor_bridge:toplevel_spawn/2),
    ensure_toplevel_target(Options, EffectiveOptions),
    swi_wasm_actor_bridge:toplevel_spawn(Pid, EffectiveOptions),
    emit_trace(invoked(toplevel, Pid, State)),
    assertz(statechart_wasm:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.

invoke(State) :-
    statechart_wasm:to_be_invoked(State, actor, Options),
    current_predicate(swi_wasm_actor_bridge:spawn/3),
    memberchk(goal(Goal), Options),
    swi_wasm_actor_bridge:spawn(Goal, Pid, Options),
    emit_trace(invoked(actor, Pid, State)),
    assertz(statechart_wasm:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_wasm:to_be_invoked(State, server, Options0),
    current_predicate(swi_wasm_actor_bridge:server_spawn/4),
    select_option(callback(Callback), Options0, Options1),
    select_option(state(ServerState), Options1, Options),
    swi_wasm_actor_bridge:server_spawn(Callback, ServerState, Pid, Options),
    emit_trace(invoked(server, Pid, State)),
    assertz(statechart_wasm:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_wasm:to_be_invoked(State, supervisor, Options0),
    current_predicate(swi_wasm_actor_bridge:supervisor_spawn/3),
    select_option(children(Children), Options0, Options),
    swi_wasm_actor_bridge:supervisor_spawn(Children, Pid, Options),
    emit_trace(invoked(supervisor, Pid, State)),
    assertz(statechart_wasm:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_wasm:to_be_invoked(State, statechart, Options),
    current_predicate(swi_wasm_actor_bridge:statechart_spawn/2),
    swi_wasm_actor_bridge:statechart_spawn(Pid, Options),
    emit_trace(invoked(statechart, Pid, State)),
    assertz(statechart_wasm:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_wasm:to_be_invoked(State, actor, Options),
    \+ memberchk(goal(_), Options),
    throw(error(existence_error(option, goal),
                context(statechart_wasm_runtime:invoke/1,
                        '<spawn type="actor"> requires goal/1'))).
invoke(State) :-
    statechart_wasm:to_be_invoked(State, server, Options),
    (   \+ memberchk(callback(_), Options)
    ->  Missing = callback
    ;   \+ memberchk(state(_), Options),
        Missing = state
    ),
    throw(error(existence_error(option, Missing),
                context(statechart_wasm_runtime:invoke/1,
                        '<spawn type="server"> requires callback/1 and state/1'))).
invoke(State) :-
    statechart_wasm:to_be_invoked(State, supervisor, Options),
    \+ memberchk(children(_), Options),
    throw(error(existence_error(option, children),
                context(statechart_wasm_runtime:invoke/1,
                        '<spawn type="supervisor"> requires children/1'))).
invoke(State) :-
    statechart_wasm:to_be_invoked(State, Type, _),
    \+ memberchk(Type, [actor, toplevel, server, supervisor, statechart]),
    throw(error(domain_error(statechart_spawn_type, Type),
                context(statechart_wasm_runtime:invoke/1,
                        'supported spawn types are actor, toplevel, server, supervisor, and statechart'))).
invoke(_State).

ensure_toplevel_target(Options, Options) :-
    memberchk(target(_), Options),
    !.
ensure_toplevel_target(Options, [target(Target)|Options]) :-
    statechart_wasm:self(Target).

%   Cancel a child spawned by <spawn> when its owning state exits -- the
%   SCXML invoke-cancellation contract.  The desktop runtime exits the
%   child actor (exit(Pid, stop)); the WASM port routes that to the actor
%   bridge, which terminates the browser worker.  A no-op when the bridge
%   is absent (desktop / no actor runtime), mirroring invoke/1's guard.
%   Both the desktop forall and this one are excluded from the
%   byte-equivalence guard as documented host-specific actor shutdown.
cancel_invoked_child(Pid) :-
    (   current_predicate(swi_wasm_actor_bridge:exit/2)
    ->  catch(swi_wasm_actor_bridge:exit(Pid, stop), _, true)
    ;   true
    ).

raise(Event) :-
    enqueue_internal_event(Event).

in(State) :-
    statechart_wasm:configuration(Configuration),
    memberchk(State, Configuration).

log(Message) :-
    emit_trace(log(Message)).

%!  check_chart_goal(+Goal) is det.
%
%   Mirrors statechart_runtime:check_chart_goal/1 in the desktop engine so
%   the two stay byte-equivalent.  In the browser (SWI-WASM) no layer
%   installs hook_check_chart_goal/1, so this is a no-op; the node's
%   sandbox glue is what makes it gate client chart goals server-side.
:- multifile hook_check_chart_goal/1.

check_chart_goal(Goal) :-
    forall(hook_check_chart_goal(Goal), true).

call_chart_goal(Goal) :-
    forall(hook_check_chart_goal(Goal), true),
    call(statechart_wasm:Goal).

script(Goal) :-
    emit_trace(execution(Goal)),
    (   catch(once(call_chart_goal(Goal)),
              Error,
              ( statechart_wasm:rethrow_reserved(Error),
                enqueue_internal_event(error(Error)),
                true
              ))
    ->  true
    ;   enqueue_internal_event(error(failure(Goal)))
    ).


emit_trace(Event) :-
    catch(statechart_wasm:emit_trace(Event), Error,
          (statechart_wasm:rethrow_reserved(Error), true)).
