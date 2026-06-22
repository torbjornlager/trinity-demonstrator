:- module(statechart_wasm_runtime, [
    clean/0,
    root_state/1,
    initial_state/2,
    exit_interpreter/0,
    execute_content/1,
    enqueue_internal_event/1,
    dequeue_internal_event/1,
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
    check_chart_goal/1
]).

/** <module> Statechart Runtime Helpers (SWI-WASM port)

Runtime bookkeeping, ancestry helpers, and built-in predicates for the
SWI-WASM statechart interpreter. The runtime state itself lives as
dynamic facts in `statechart_wasm`.

Differences from the desktop `statechart_runtime`:

  - The internal event queue is a list held in a dynamic fact instead of
    a SWI message queue (no threads in WASM).
  - `invoke/1` is a no-op; `<spawn>` is parsed but not executed in the
    WASM port (deferred).
  - No dependency on `actor` or `toplevel_actor`.
*/

:- use_module(library(lists)).


%!  clean is det.
clean :-
    retractall(statechart_wasm:state(_, _)),
    retractall(statechart_wasm:to_be_invoked(_, _, _)),
    retractall(statechart_wasm:initial(_)),
    retractall(statechart_wasm:initial(_, _)),
    retractall(statechart_wasm:transition(_, _, _, _, _)),
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
    retractall(statechart_wasm:internal_queue(_)),
    retractall(statechart_wasm:running).


root_state(Root) :-
    statechart_wasm:state(Root, null),
    !.

initial_state(Root, Initial) :-
    (   statechart_wasm:initial(Initial)
    ->  true
    ;   statechart_wasm:transition(init(Root), '', true, [Initial|_], _)
    ->  true
    ;   throw(error(missing_initial_state(Root), _))
    ).

exit_interpreter :-
    statechart_wasm:configuration(Configuration),
    predsort(exit_order, Configuration, StatesToExit),
    exit_interpreter(StatesToExit).

exit_interpreter([]).
exit_interpreter([State|States]) :-
    forall(statechart_wasm:onexit(State, Content), execute_content(Content)),
    configuration_delete(State),
    (   is_final(State),
        has_parent(State, Parent),
        is_statechart_element(Parent)
    ->  true
    ;   exit_interpreter(States)
    ).

execute_content(Content) :-
    maplist(call, Content).

enqueue_internal_event(Event) :-
    retract(statechart_wasm:internal_queue(Q)),
    append(Q, [Event], Q1),
    assertz(statechart_wasm:internal_queue(Q1)).

dequeue_internal_event(Event) :-
    retract(statechart_wasm:internal_queue([Event|Q])),
    assertz(statechart_wasm:internal_queue(Q)).

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

%   <spawn> is parsed but not executed in the WASM port.  Charts that
%   rely on spawned child actors will simply not get those children;
%   no error is raised, no PIDs are recorded.
invoke(_State) :- true.

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

script(Goal) :-
    emit_trace(execution(Goal)),
    (   catch(( check_chart_goal(Goal), once(statechart_wasm:Goal) ),
              Error,
              ( enqueue_internal_event(error(Error)),
                true
              ))
    ->  true
    ;   enqueue_internal_event(error(failure(Goal)))
    ).


emit_trace(Event) :-
    catch(statechart_wasm:emit_trace(Event), _, true).
