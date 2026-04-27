:- module(statechart_exec, [
    interpret/1,
    interpret_text/1,
    interpret_parsed/1,
    select_transitions/2,
    microstep/1,
    enter_states/1,
    compute_exit_set/3,
    compute_entry_set/2
]).

/** <module> Statechart Execution Core

Run-to-completion event loop and transition processing for the statechart
actor profile. Model and runtime facts live in `statechart_actor`.
*/

:- use_module(actor, [receive/1, exit/2, send/2]).

:- use_module(library(sort)).
:- use_module(library(apply)).
:- use_module(library(debug)).
:- use_module(statechart_model, [
    statechart_actor_parse/1,
    statechart_actor_parse_text/1
]).
:- use_module(statechart_runtime, [
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
    invoke/1
]).


interpret(File) :-
    clean,
    statechart_actor_parse(File),
    interpret_parsed(_Root).

interpret_text(Text) :-
    clean,
    statechart_actor_parse_text(Text),
    interpret_parsed(_Root).

interpret_parsed(Root) :-
    (   root_state(Root)
    ->  true
    ;   throw(error(existence_error(statechart, root),
                    context(statechart_exec:interpret_parsed/1,
                            'No <statechart> root element found; check the XML source')))
    ),
    assertz(statechart_actor:configuration([])),
    assertz(statechart_actor:states_to_invoke([])),
    assertz(statechart_actor:running),
    assertz(statechart_actor:state(dummy, Root)),
    initial_state(Root, Initial),
    with_internal_queue((
        enter_states([t(dummy, [Initial], [])]),
        catch(
            main_event_loop,
            exit(shutdown),
            (   retractall(statechart_actor:running),
                exit_interpreter,
                throw(exit(shutdown))
            )
        )
    )).


main_event_loop :-
    (   statechart_actor:running
    ->  main_event_loop_2
    ;   exit_interpreter,
        debug(statechart_actor(info),
              '*** End of processing (a down message was sent to parent)\n', [])
    ).

main_event_loop_2 :-
    (   select_transitions(null, EnabledTransitions)
    ->  microstep(EnabledTransitions),
        main_event_loop
    ;   statechart_actor:internal_queue(Internal),
        thread_get_message(Internal, Event, [timeout(0)]),
        update_eventdata(Event),
        trace_emit(internal_event(Event)),
        debug(statechart_actor(event), '   Int. event: ~p', [Event])
    ->  main_event_loop(Event)
    ;   statechart_actor:states_to_invoke(States),
        States \= []
    ->  maplist(invoke, States),
        retractall(statechart_actor:states_to_invoke(_)),
        assertz(statechart_actor:states_to_invoke([])),
        main_event_loop
    ;   receive({Event -> true}),
        trace_emit(external_event(Event)),
        debug(statechart_actor(event), '   Ext. event: ~p', [Event]),
        (   Event = '$stop'(From)
        ->  retractall(statechart_actor:running),
            exit_interpreter,
            send(From, reply(true))
        ;   update_eventdata(Event),
            main_event_loop(Event)
        )
    ).

main_event_loop(Event) :-
    (   select_transitions(Event, EnabledTransitions)
    ->  microstep(EnabledTransitions),
        main_event_loop
    ;   trace_emit(unmatched(Event)),
        debug(statechart_actor(info), '    Unmatched: ~p', [Event]),
        main_event_loop
    ).


select_transitions(Event, EnabledTransitions) :-
    statechart_actor:configuration(Configuration),
    findall(EnabledTransition,
            ( member(State, Configuration),
              is_atomic(State),
              once(select_transition(Event, State, EnabledTransition))
            ),
            EnabledTransitions0),
    EnabledTransitions0 \= [],
    dedup(EnabledTransitions0, EnabledTransitions1),
    remove_conflicting_transitions(EnabledTransitions1, EnabledTransitions),
    maplist(trace_transition, EnabledTransitions).

select_transition(null, State, t(Ancestor, Targets, Actions)) :-
    ancestor(State, null, Ancestor),
    statechart_actor:transition(Ancestor, '', Condition, Targets, Actions),
    evaluate_condition(Condition).
select_transition(Event, State, t(Ancestor, Targets, Actions)) :-
    Event \== null,
    ancestor(State, null, Ancestor),
    statechart_actor:transition(Ancestor, Event, Condition, Targets, Actions),
    evaluate_condition(Condition).

trace_transition(t(State, Targets, _)) :-
    statechart_actor:configuration(Configuration),
    transition_exit_set(t(State, Targets, []), Configuration, ExitSet),
    compute_entry_set([t(State, Targets, [])], EntrySet),
    trace_emit(transition(State, Targets, ExitSet, EntrySet)),
    debug(statechart_actor(info),
          '   Transition: ~p => ~p (exit ~p, enter ~p)',
          [State, Targets, ExitSet, EntrySet]).

dedup(List, Deduped) :-
    dedup(List, [], Deduped).

dedup([], _Seen, []).
dedup([H|Rest], Seen, Deduped) :-
    (   memberchk(H, Seen)
    ->  dedup(Rest, Seen, Deduped)
    ;   Deduped = [H|Tail],
        dedup(Rest, [H|Seen], Tail)
    ).

evaluate_condition(Condition) :-
    catch(once(statechart_actor:Condition),
          Error,
          ( enqueue_internal_event(error(Error)),
            fail
          )).

transition_exit_set(t(Source, Targets, _), Configuration, ExitSet) :-
    (   Targets == []
    ->  ExitSet = []
    ;   find_LCCA([Source|Targets], LCA),
        findall(State,
                ( member(State, Configuration),
                  is_descendant(State, LCA)
                ),
                ExitSet)
    ).

conflict(Transition1, Transition2, Configuration) :-
    transition_exit_set(Transition1, Configuration, ExitSet1),
    ExitSet1 \= [],
    transition_exit_set(Transition2, Configuration, ExitSet2),
    ExitSet2 \= [],
    intersects(ExitSet1, ExitSet2).

intersects([State|_], Set) :-
    memberchk(State, Set),
    !.
intersects([_|States], Set) :-
    intersects(States, Set).

preempted_by_any(Transition, Selected, Configuration) :-
    member(Other, Selected),
    conflict(Transition, Other, Configuration),
    Transition = t(Source, _, _),
    Other = t(OtherSource, _, _),
    \+ is_descendant(Source, OtherSource),
    !.

remove_preempted(Transition, Selected, Configuration, Filtered) :-
    Transition = t(Source, _, _),
    exclude(preempted_by(Transition, Configuration, Source), Selected, Filtered).

preempted_by(Transition, Configuration, Source, Other) :-
    conflict(Transition, Other, Configuration),
    Other = t(OtherSource, _, _),
    is_descendant(Source, OtherSource).

remove_conflicting_transitions(Transitions0, Transitions) :-
    statechart_actor:configuration(Configuration),
    remove_conflicting_transitions(Transitions0, Configuration, [], Transitions).

remove_conflicting_transitions([], _Configuration, Transitions, Transitions).
remove_conflicting_transitions([Transition|Rest], Configuration, Selected0, Selected) :-
    (   preempted_by_any(Transition, Selected0, Configuration)
    ->  remove_conflicting_transitions(Rest, Configuration, Selected0, Selected)
    ;   remove_preempted(Transition, Selected0, Configuration, Selected1),
        append(Selected1, [Transition], Selected2),
        remove_conflicting_transitions(Rest, Configuration, Selected2, Selected)
    ).


microstep(EnabledTransitions) :-
    trace_microstep(EnabledTransitions),
    exit_states(EnabledTransitions),
    execute_transition_content(EnabledTransitions),
    enter_states(EnabledTransitions).

trace_microstep(EnabledTransitions) :-
    statechart_actor:configuration(Configuration),
    compute_exit_set(EnabledTransitions, Configuration, ExitSet),
    compute_entry_set(EnabledTransitions, EntrySet),
    trace_emit(microstep(ExitSet, EntrySet)),
    debug(statechart_actor(info), '   Microstep exit ~p enter ~p', [ExitSet, EntrySet]).

trace_emit(Event) :-
    catch(statechart_actor:emit_trace(Event), _, true).

exit_states(EnabledTransitions) :-
    statechart_actor:configuration(Configuration),
    compute_exit_set(EnabledTransitions, Configuration, StatesToExit),
    maplist(states_to_invoke_delete, StatesToExit),
    predsort(exit_order, StatesToExit, SortedStatesToExit),
    (   member(State, SortedStatesToExit),
        statechart_actor:history(H, State, Depth),
        (   Depth == deep
        ->  findall(S,
                    ( member(S, Configuration),
                      is_atomic(S),
                      is_descendant(S, State)
                    ),
                    SS)
        ;   findall(S,
                    ( member(S, Configuration),
                      has_parent(S, State)
                    ),
                    SS)
        ),
        update_history_value(H, SS),
        fail
    ;   true
    ),
    process_states_to_exit(SortedStatesToExit).

process_states_to_exit([]).
process_states_to_exit([State|States]) :-
    forall(statechart_actor:onexit(State, Content), execute_content(Content)),
    forall(statechart_actor:invoked(State, Pid), exit(Pid, stop)),
    configuration_delete(State),
    process_states_to_exit(States).

compute_exit_set(Transitions, Configuration, StatesToExit) :-
    findall(State,
            ( member(t(Source, Targets, _), Transitions),
              Targets \= [],
              find_LCCA([Source|Targets], LCA),
              member(State, Configuration),
              is_descendant(State, LCA)
            ),
            StatesToExit0),
    dedup(StatesToExit0, StatesToExit).

execute_transition_content(EnabledTransitions) :-
    (   member(t(_, _, Children), EnabledTransitions),
        execute_content(Children),
        fail
    ;   true
    ).

enter_states(EnabledTransitions) :-
    compute_entry_set(EnabledTransitions, StatesToEnter),
    predsort(entry_order, StatesToEnter, SortedStatesToEnter),
    process_states_to_enter(SortedStatesToEnter),
    statechart_actor:configuration(NewConfiguration),
    trace_emit(configuration(NewConfiguration)),
    debug(statechart_actor(config), 'Configuration: ~p', [NewConfiguration]).

process_states_to_enter([]).
process_states_to_enter([State|States]) :-
    configuration_add(State),
    states_to_invoke_add(State),
    forall(statechart_actor:onentry(State, Content), execute_content(Content)),
    (   is_final(State)
    ->  (   has_parent(State, Parent),
            is_statechart_element(Parent)
        ->  retractall(statechart_actor:running)
        ;   has_parent(State, Parent),
            enqueue_internal_event(done(Parent)),
            has_parent(Parent, Grandparent),
            (   is_parallel(Grandparent),
                forall(has_parent(Child, Grandparent), is_in_final_state(Child))
            ->  enqueue_internal_event(done(Grandparent))
            ;   true
            )
        )
    ;   true
    ),
    process_states_to_enter(States).


compute_entry_set(Transitions, StatesToEnter) :-
    compute_entry_set(Transitions, [], StatesToEnter0),
    dedup(StatesToEnter0, StatesToEnter).

compute_entry_set([], States, States).
compute_entry_set([t(Source, Targets, _)|Transitions], States0, States) :-
    (   Targets == []
    ->  States1 = States0
    ;   find_LCCA([Source|Targets], LCA),
        compute_entry_set_for_targets(Targets, LCA, States0, States1)
    ),
    compute_entry_set(Transitions, States1, States).

compute_entry_set_for_targets([], _LCA, States, States).
compute_entry_set_for_targets([Target0|Targets], LCA, States0, States) :-
    resolve_targets(Target0, ResolvedTargets),
    compute_entry_set_for_resolved(ResolvedTargets, LCA, States0, States1),
    compute_entry_set_for_targets(Targets, LCA, States1, States).

compute_entry_set_for_resolved([], _LCA, States, States).
compute_entry_set_for_resolved([Target|Targets], LCA, States0, States) :-
    add_descendant_states_to_enter(Target, States0, States1),
    add_ancestor_states_to_enter(Target, LCA, States1, States2),
    compute_entry_set_for_resolved(Targets, LCA, States2, States).

resolve_targets(Target, ResolvedTargets) :-
    (   is_history(Target)
    ->  (   statechart_actor:historyValue(Target, States)
        ->  ResolvedTargets = States
        ;   statechart_actor:transition(Target, '', true, States, _)
        ->  ResolvedTargets = States
        ;   ResolvedTargets = []
        )
    ;   ResolvedTargets = [Target]
    ).

add_descendant_states_to_enter(State, States0, States) :-
    ordered_add(State, States0, States1),
    (   is_parallel(State)
    ->  add_parallel_descendants(State, States1, States)
    ;   is_compound(State)
    ->  add_initial_descendants(State, States1, States)
    ;   States = States1
    ).

add_initial_descendants(State, States0, States) :-
    (   statechart_actor:transition(init(State), '', true, Targets, _)
    ->  add_targets_descendants(Targets, State, States0, States)
    ;   States = States0
    ).

add_parallel_descendants(Parallel, States0, States) :-
    findall(Child, has_parent(Child, Parallel), Children),
    add_parallel_children(Children, States0, States).

add_parallel_children([], States, States).
add_parallel_children([Child|Children], States0, States) :-
    (   has_descendant_in_set(Child, States0)
    ->  States1 = States0
    ;   add_descendant_states_to_enter(Child, States0, States1)
    ),
    add_parallel_children(Children, States1, States).

add_targets_descendants([], _Root, States, States).
add_targets_descendants([Target|Targets], Root, States0, States) :-
    add_descendant_states_to_enter(Target, States0, States1),
    add_ancestor_states_to_enter(Target, Root, States1, States2),
    add_targets_descendants(Targets, Root, States2, States).

add_ancestor_states_to_enter(State, Root, States0, States) :-
    findall(Ancestor, proper_ancestor(State, Root, Ancestor), Ancestors),
    add_ancestors_list(Ancestors, States0, States).

add_ancestors_list([], States, States).
add_ancestors_list([Ancestor|Ancestors], States0, States) :-
    ordered_add(Ancestor, States0, States1),
    (   is_parallel(Ancestor)
    ->  add_parallel_descendants(Ancestor, States1, States2)
    ;   States2 = States1
    ),
    add_ancestors_list(Ancestors, States2, States).
