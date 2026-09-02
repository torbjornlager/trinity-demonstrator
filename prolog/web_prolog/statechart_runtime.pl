:- module(statechart_runtime, [
    clean/0,
    with_internal_queue/1,
    root_state/1,
    initial_state/2,
    exit_interpreter/0,
    schedule_after_transitions/1,
    cancel_after_transitions/1,
    execute_content/1,
    enqueue_internal_event/1,
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
    raise/1,
    in/1,
    log/1,
    script/1,
    check_chart_goal/1,
    call_chart_goal/1
]).

/** <module> Statechart Runtime Helpers

Runtime bookkeeping, ancestry helpers, and built-in predicates for the
statechart actor interpreter. The runtime state itself lives in
`statechart_actor` as thread-local facts.
*/

:- use_module(actors).
:- use_module(toplevel_actors).
:- use_module(server_actor, [server_spawn/4]).
:- use_module(supervisor_actor, [supervisor_spawn/3]).

:- use_module(library(option)).
:- use_module(library(debug)).
:- use_module(isolation, [execution_source_module/2]).
:- use_module(control_guard, []).

:- meta_predicate with_internal_queue(0).


%!  clean is det.
clean :-
    cancel_all_after_transitions,
    destroy_internal_queues,
    retractall(statechart_actor:state(_, _)),
    retractall(statechart_actor:to_be_invoked(_, _, _)),
    retractall(statechart_actor:initial(_)),
    retractall(statechart_actor:transition(_, _, _, _, _)),
    retractall(statechart_actor:after_transition(_, _, _, _, _, _)),
    retractall(statechart_actor:defer(_, _, _)),
    retractall(statechart_actor:parallel(_, _)),
    retractall(statechart_actor:history(_, _, _)),
    retractall(statechart_actor:final(_, _)),
    retractall(statechart_actor:onexit(_, _)),
    retractall(statechart_actor:onentry(_, _)),
    retractall(statechart_actor:n(_, _)),
    retractall(statechart_actor:num(_)),
    retractall(statechart_actor:event(_)),
    retractall(statechart_actor:historyValue(_, _)),
    retractall(statechart_actor:configuration(_)),
    retractall(statechart_actor:states_to_invoke(_)),
    retractall(statechart_actor:invoked(_, _)),
    retractall(statechart_actor:after_timer(_, _, _)),
    retractall(statechart_actor:postponed_queue(_)),
    retractall(statechart_actor:macrostep_start(_)).

destroy_internal_queues :-
    forall(retract(statechart_actor:internal_queue(Internal)),
           catch(message_queue_destroy(Internal), _, true)).

with_internal_queue(Goal) :-
    setup_call_cleanup(
        message_queue_create(Internal),
        setup_call_cleanup(
            assertz(statechart_actor:internal_queue(Internal)),
            Goal,
            retractall(statechart_actor:internal_queue(Internal))
        ),
        catch(message_queue_destroy(Internal), _, true)
    ).

root_state(Root) :-
    statechart_actor:state(Root, null),
    !.

initial_state(Root, Initial) :-
    (   statechart_actor:initial(Initial)
    ->  true
    ;   throw(error(missing_initial_state(Root), _))
    ).

exit_interpreter :-
    statechart_actor:configuration(Configuration),
    predsort(exit_order, Configuration, StatesToExit),
    exit_interpreter(StatesToExit).

exit_interpreter([]).
exit_interpreter([State|States]) :-
    cancel_after_transitions(State),
    forall(statechart_actor:onexit(State, Content), execute_content(Content)),
    forall(statechart_actor:invoked(State, Pid), exit(Pid, stop)),
    configuration_delete(State),
    (   is_final(State),
        has_parent(State, Parent),
        is_statechart_element(Parent)
    ->  true
    ;   exit_interpreter(States)
    ).


%!  schedule_after_transitions(+State) is det.
%
%   Arm every timed transition whose source is State.  The activation
%   reference is both the delayed-send cancellation id and part of the
%   private event, so a message that races with cancellation cannot affect
%   a later activation of the same state.
schedule_after_transitions(State) :-
    forall(statechart_actor:after_transition(State, Key, Delay, _, _, _),
           schedule_after_transition(State, Key, Delay)).

schedule_after_transition(State, Key, Delay) :-
    make_ref(Ref),
    self(Self),
    assertz(statechart_actor:after_timer(State, Key, Ref)),
    catch(send(Self, '$statechart_after'(State, Key, Ref),
               [delay(Delay), id(Ref)]),
          Error,
          ( retractall(statechart_actor:after_timer(State, Key, Ref)),
            throw(Error)
          )).


%!  cancel_after_transitions(+State) is det.
%
%   Invalidate timers before the state's exit actions run.  cancel/1 is
%   best-effort; the private activation reference makes an already queued
%   firing harmless.
cancel_after_transitions(State) :-
    forall(retract(statechart_actor:after_timer(State, _Key, Ref)),
           catch(cancel(Ref), _, true)).

cancel_all_after_transitions :-
    forall(retract(statechart_actor:after_timer(_State, _Key, Ref)),
           catch(cancel(Ref), _, true)).

execute_content(Content) :-
    maplist(call, Content).

enqueue_internal_event(Event) :-
    statechart_actor:internal_queue(Internal),
    thread_send_message(Internal, Event).

initialise_event_processing :-
    retractall(statechart_actor:postponed_queue(_)),
    assertz(statechart_actor:postponed_queue([])),
    retractall(statechart_actor:macrostep_start(_)),
    assertz(statechart_actor:macrostep_start([])).

begin_macrostep :-
    statechart_actor:configuration(Configuration),
    retractall(statechart_actor:macrostep_start(_)),
    assertz(statechart_actor:macrostep_start(Configuration)).

ensure_macrostep :-
    (   statechart_actor:macrostep_start(_)
    ->  true
    ;   begin_macrostep
    ).

postpone_event(Event) :-
    retract(statechart_actor:postponed_queue(Events)),
    append(Events, [Event], NewEvents),
    assertz(statechart_actor:postponed_queue(NewEvents)).

reoffer_postponed_events(Events) :-
    retract(statechart_actor:macrostep_start(StartConfiguration)),
    statechart_actor:configuration(Configuration),
    Configuration \== StartConfiguration,
    statechart_actor:postponed_queue(Events),
    Events \= [],
    retractall(statechart_actor:postponed_queue(_)),
    assertz(statechart_actor:postponed_queue([])),
    maplist(enqueue_internal_event, Events),
    assertz(statechart_actor:macrostep_start(Configuration)).

update_eventdata(Event) :-
    retractall(statechart_actor:event(_)),
    assertz(statechart_actor:event(Event)).

configuration_add(State) :-
    statechart_actor:configuration(Configuration),
    ordered_add(State, Configuration, NewConfiguration),
    (   NewConfiguration == Configuration
    ->  true
    ;   retractall(statechart_actor:configuration(_)),
        assertz(statechart_actor:configuration(NewConfiguration))
    ).

configuration_delete(State) :-
    statechart_actor:configuration(Configuration),
    subtract(Configuration, [State], NewConfiguration),
    retractall(statechart_actor:configuration(_)),
    assertz(statechart_actor:configuration(NewConfiguration)).

states_to_invoke_add(State) :-
    statechart_actor:states_to_invoke(StatesToInvoke),
    ordered_add(State, StatesToInvoke, NewStatesToInvoke),
    (   NewStatesToInvoke == StatesToInvoke
    ->  true
    ;   retractall(statechart_actor:states_to_invoke(_)),
        assertz(statechart_actor:states_to_invoke(NewStatesToInvoke))
    ).

states_to_invoke_delete(State) :-
    statechart_actor:states_to_invoke(StatesToInvoke),
    subtract(StatesToInvoke, [State], NewStatesToInvoke),
    retractall(statechart_actor:states_to_invoke(_)),
    assertz(statechart_actor:states_to_invoke(NewStatesToInvoke)).

update_history_value(H, SS) :-
    retractall(statechart_actor:historyValue(H, _)),
    assertz(statechart_actor:historyValue(H, SS)).

ordered_add(State, States, NewStates) :-
    (   memberchk(State, States)
    ->  NewStates = States
    ;   predsort(entry_order, [State|States], NewStates)
    ).

entry_order(=, State, State).
entry_order(>, State1, State2) :-
    statechart_actor:n(N1, State1),
    statechart_actor:n(N2, State2),
    N1 > N2,
    !.
entry_order(<, _State1, _State2).

exit_order(=, State, State).
exit_order(<, State1, State2) :-
    statechart_actor:n(N1, State1),
    statechart_actor:n(N2, State2),
    N1 > N2,
    !.
exit_order(>, _State1, _State2).

is_parallel(State) :-
    statechart_actor:parallel(State, _).

is_compound(State) :-
    has_parent(_Child, State).

is_atomic(State) :-
    \+ has_parent(_Child, State).

is_history(State) :-
    statechart_actor:history(State, _, _).

is_final(State) :-
    statechart_actor:final(State, _).

is_statechart_element(State) :-
    statechart_actor:state(State, null).

is_in_final_state(S) :-
    is_compound(S),
    has_parent(Child, S),
    is_final(Child),
    statechart_actor:configuration(Configuration),
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
    statechart_actor:state(State, Parent).
has_parent(State, Parent) :-
    statechart_actor:parallel(State, Parent).
has_parent(State, Parent) :-
    statechart_actor:final(State, Parent).
has_parent(State, Parent) :-
    statechart_actor:history(State, Parent, _).

has_descendant_in_set(State, States) :-
    member(Active, States),
    (   Active == State
    ;   is_descendant(Active, State)
    ),
    !.

invoke(State) :-
    statechart_actor:to_be_invoked(State, toplevel, Options),
    toplevel_spawn(Pid, Options),
    emit_trace(invoked(toplevel, Pid, State)),
    debug(statechart_actor(invoke), '      Invoked: toplevel ~p at ~p', [Pid, State]),
    assertz(statechart_actor:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_actor:to_be_invoked(State, actor, Options),
    option(goal(Goal), Options),
    spawn(Goal, Pid, Options),
    emit_trace(invoked(actor, Pid, State)),
    debug(statechart_actor(invoke), '      Invoked: actor ~p at ~p', [Pid, State]),
    assertz(statechart_actor:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_actor:to_be_invoked(State, server, Options0),
    select_option(callback(Callback), Options0, Options1),
    select_option(state(ServerState), Options1, Options),
    server_spawn(Callback, ServerState, Pid, Options),
    emit_trace(invoked(server, Pid, State)),
    debug(statechart_actor(invoke), '      Invoked: server ~p at ~p', [Pid, State]),
    assertz(statechart_actor:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_actor:to_be_invoked(State, supervisor, Options0),
    select_option(children(Children), Options0, Options),
    supervisor_spawn(Children, Pid, Options),
    emit_trace(invoked(supervisor, Pid, State)),
    debug(statechart_actor(invoke), '      Invoked: supervisor ~p at ~p', [Pid, State]),
    assertz(statechart_actor:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_actor:to_be_invoked(State, statechart, Options),
    execution_source_module(statechart_actor, SourceModule),
    statechart_actor:statechart_spawn(Pid, SourceModule:Options),
    emit_trace(invoked(statechart, Pid, State)),
    debug(statechart_actor(invoke), '      Invoked: statechart ~p at ~p', [Pid, State]),
    assertz(statechart_actor:invoked(State, Pid)),
    enqueue_internal_event(spawned(Pid)),
    fail.
invoke(State) :-
    statechart_actor:to_be_invoked(State, actor, Options),
    \+ option(goal(_), Options),
    throw(error(existence_error(option, goal),
                context(statechart_runtime:invoke/1,
                        '<spawn type="actor"> requires goal/1'))).
invoke(State) :-
    statechart_actor:to_be_invoked(State, server, Options),
    (   \+ option(callback(_), Options)
    ->  Missing = callback
    ;   \+ option(state(_), Options),
        Missing = state
    ),
    throw(error(existence_error(option, Missing),
                context(statechart_runtime:invoke/1,
                        '<spawn type="server"> requires callback/1 and state/1'))).
invoke(State) :-
    statechart_actor:to_be_invoked(State, supervisor, Options),
    \+ option(children(_), Options),
    throw(error(existence_error(option, children),
                context(statechart_runtime:invoke/1,
                        '<spawn type="supervisor"> requires children/1'))).
invoke(State) :-
    statechart_actor:to_be_invoked(State, Type, _),
    \+ memberchk(Type, [actor, toplevel, server, supervisor, statechart]),
    throw(error(domain_error(statechart_spawn_type, Type),
                context(statechart_runtime:invoke/1,
                        'supported spawn types are actor, toplevel, server, supervisor, and statechart'))).
invoke(_).

raise(Event) :-
    enqueue_internal_event(Event).

in(State) :-
    statechart_actor:configuration(Configuration),
    memberchk(State, Configuration).

log(Message) :-
    emit_trace(log(Message)),
    debug(statechart_actor(log), '   Output log: ~p', [Message]).

%!  check_chart_goal(+Goal) is det.
%!  call_chart_goal(+Goal) is nondet.
%
%   Vet a chart-embedded goal -- an <onentry>/<onexit>/<go> script action
%   or a transition condition -- before it runs.  A no-op unless a higher
%   layer installs hook_check_chart_goal/2: the node layer does so to
%   sandbox the goal under the active public execution profile, so an
%   untrusted client chart (e.g. spawned via statechart_spawn/2 with
%   src_text/1) cannot execute arbitrary predicates through its scripts.
%   call_chart_goal/1 executes in the current actor's private module.  On a
%   node this exposes the node's shared database while letting predicates in
%   the chart datamodel shadow shared predicates with the same name.
%   Throws (rejecting the goal) if a hook does; trusted desktop/test
%   execution installs no hook and is therefore unchanged.
:- multifile hook_check_chart_goal/2.

check_chart_goal(Goal) :-
    chart_goal_module(Module),
    forall(hook_check_chart_goal(Module, Goal), true).

call_chart_goal(Goal) :-
    chart_goal_module(Module),
    forall(hook_check_chart_goal(Module, Goal), true),
    control_guard:rewrite_goal(Module, Goal, ProtectedGoal),
    call(Module:ProtectedGoal).

chart_goal_module(Module) :-
    execution_source_module(statechart_actor, Module).

script(Goal) :-
    emit_trace(execution(Goal)),
    (   catch(once(call_chart_goal(Goal)),
              Error,
              ( control_guard:rethrow_reserved(Error),
                enqueue_internal_event(error(Error)),
                true
              ))
    ->  true
    ;   enqueue_internal_event(error(failure(Goal)))
    ),
    debug(statechart_actor(execute), '    Execution: ~p', [Goal]).


emit_trace(Event) :-
    catch(statechart_actor:emit_trace(Event), Error,
          (control_guard:rethrow_reserved(Error), true)).
