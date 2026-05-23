:- module(statechart_runtime, [
    clean/0,
    with_internal_queue/1,
    root_state/1,
    initial_state/2,
    exit_interpreter/0,
    execute_content/1,
    enqueue_internal_event/1,
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
    script/1
]).

/** <module> Statechart Runtime Helpers

Runtime bookkeeping, ancestry helpers, and built-in predicates for the
statechart actor interpreter. The runtime state itself lives in
`statechart_actor` as thread-local facts.
*/

:- use_module(actor).
:- use_module(toplevel_actor).

:- use_module(library(option)).
:- use_module(library(debug)).

:- meta_predicate with_internal_queue(0).


%!  clean is det.
clean :-
    destroy_internal_queues,
    retractall(statechart_actor:state(_, _)),
    retractall(statechart_actor:to_be_invoked(_, _, _)),
    retractall(statechart_actor:initial(_)),
    retractall(statechart_actor:initial(_, _)),
    retractall(statechart_actor:transition(_, _, _, _, _)),
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
    retractall(statechart_actor:invoked(_, _)).

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
    ;   statechart_actor:transition(init(Root), '', true, [Initial|_], _)
    ->  true
    ;   throw(error(missing_initial_state(Root), _))
    ).

exit_interpreter :-
    statechart_actor:configuration(Configuration),
    predsort(exit_order, Configuration, StatesToExit),
    exit_interpreter(StatesToExit).

exit_interpreter([]).
exit_interpreter([State|States]) :-
    forall(statechart_actor:onexit(State, Content), execute_content(Content)),
    forall(statechart_actor:invoked(State, Pid), exit(Pid, stop)),
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
    statechart_actor:internal_queue(Internal),
    thread_send_message(Internal, Event).

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
invoke(_).

raise(Event) :-
    enqueue_internal_event(Event).

in(State) :-
    statechart_actor:configuration(Configuration),
    memberchk(State, Configuration).

log(Message) :-
    emit_trace(log(Message)),
    debug(statechart_actor(log), '   Output log: ~p', [Message]).

script(Goal) :-
    emit_trace(execution(Goal)),
    (   catch(once(statechart_actor:Goal), Error,
              ( enqueue_internal_event(error(Error)),
                true
              ))
    ->  true
    ;   enqueue_internal_event(error(failure(Goal)))
    ),
    debug(statechart_actor(execute), '    Execution: ~p', [Goal]).


emit_trace(Event) :-
    catch(statechart_actor:emit_trace(Event), _, true).
