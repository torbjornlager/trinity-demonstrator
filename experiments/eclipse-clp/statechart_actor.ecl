% SPDX-License-Identifier: MIT
:- module(statechart_actor).
:- use_module(actors).
:- import exit/2 from actors.
:- use_module(sxml_document).
:- use_module(toplevel_actors).
:- use_module(server_behaviours).
:- lib(prolog_extras).

:- export statechart_spawn/2, statechart_halt/2, statechart_halt/3.
:- export run_chart/2, raise/1, in/1.
:- tool(statechart_spawn/2, statechart_spawn_/3).

statechart_spawn_(Pid, Options, Caller) :-
    statechart_spawn_at(Pid, Options, none, Caller).

statechart_spawn_at(Pid, Options, ParentBase, Caller) :-
    prepare_sxml(Options, ParentBase, document(Base, [element(statechart, Attrs, Children)]),
                 Trace, SpawnOptions),
    local_chart_options(SpawnOptions, LocalOptions),
    memberchk(initial=Initial, Attrs),
    Root = '$sxml_root'(0),
    chart_model(Children, Root, source(Caller, Base), Nodes, Sources),
    concat_string(Sources, Datamodel),
    append(LocalOptions, [src_text(Datamodel)], ActorOptions),
    Chart = [state(Root, none, compound(Initial), [], [], [], [])|Nodes],
    validate_history_defaults(Chart),
    spawn(statechart_actor:run_chart(Chart, Trace), Pid, ActorOptions)@Caller.

local_chart_options([], []).
local_chart_options([Option|Rest], Local) :-
    ( Option = node(Node) ->
        ( Node == localhost -> Local = More ; unsupported(Option) )
    ; Local = [Option|More] ),
    local_chart_options(Rest, More).

% Flatten the tree in document order, retaining parent links. History
% pseudostates are addressable targets but never enter the configuration.
chart_model([], _, _, [], []).
chart_model([Element|Rest], Parent, Module, Nodes, Sources) :-
    chart_element(Element, Parent, Module, HeadNodes, HeadSources),
    chart_model(Rest, Parent, Module, TailNodes, TailSources),
    append(HeadNodes, TailNodes, Nodes),
    append(HeadSources, TailSources, Sources).

chart_element(element(datamodel, _, Body), _, _, [], [Source]) :- !,
    action_text(Body, Text), concat_string([Text, "\n"], Source).
chart_element(element(spawn, Attrs, Body), Parent, source(Module, Base),
              [invocation('$invoke'(Parent), Type, Operands, Options, Base)], []) :- !,
    invocation_model(Attrs, Body, Module, Type, Operands, Options).
chart_element(element(history, Attrs, [element(go, GoAttrs, _)]), Parent, _,
              [history(Id, Parent, Mode, Targets)], []) :- !,
    memberchk(id=Id, Attrs),
    ( memberchk(type=Mode, Attrs) -> true ; Mode = shallow ),
    sxml_targets(GoAttrs, Targets).
chart_element(element(Type, Attrs, Body), Parent, Source,
              [state(Id, Parent, Kind, Entries, Exits, Transitions, Defers)|Nodes], Sources) :-
    memberchk(id=Id, Attrs),
    ( Type == state ->
        ( memberchk(initial=Initial, Attrs) -> Kind = compound(Initial) ; Kind = atomic )
    ; Kind = Type ),
    Source = source(Module, _),
    state_body(Body, Module, 1, Entries, Exits, Transitions, Defers, Nested),
    chart_model(Nested, Id, Source, Nodes, Sources).

state_body([], _, _, [], [], [], [], []).
state_body([Element|Rest], Module, Key, Entries, Exits, Transitions, Defers, Nested) :-
    Element = element(Type, Attrs, Body),
    ( Type == onentry ->
        Entries = [Goal|E], Exits = X, Transitions = T, Defers = D, Nested = N,
        parse_action(Body, Module, Goal, _)
    ; Type == onexit ->
        Entries = E, Exits = [Goal|X], Transitions = T, Defers = D, Nested = N,
        parse_action(Body, Module, Goal, _)
    ; Type == go ->
        Entries = E, Exits = X, Transitions = [Transition|T], Defers = D, Nested = N,
        transition_model(Attrs, Body, Module, Key, Transition)
    ; Type == defer ->
        Entries = E, Exits = X, Transitions = T, Defers = [defer(Pattern, Guard)|D], Nested = N,
        memberchk(on=Event, Attrs),
        event_pattern(Event, Module, Pattern, EventNames),
        condition(Attrs, Module, Guard, GuardNames),
        share_names(EventNames, GuardNames)
    ; Entries = E, Exits = X, Transitions = T, Defers = D, Nested = [Element|N]
    ),
    Next is Key + 1,
    state_body(Rest, Module, Next, E, X, T, D, N).

invocation_model(Attrs, Body, Module, Type, Operands, Options) :-
    memberchk(type=Type, Attrs),
    invocation_attributes(Type, Required),
    ( member(Name=_, Attrs), \+ memberchk(Name, [type,options|Required]) ->
        invalid_chart(statechart_spawn_attribute(Type), Name)
    ; true ),
    invocation_operands(Required, Attrs, Module, Operands),
    ( memberchk(options=Text, Attrs) ->
        invocation_term(Text, Module, Listed),
        ( is_list(Listed) -> true
        ; throw(error(type_error(list, Listed), statechart_spawn/2)) )
    ; Listed = [] ),
    check_invocation_options(Listed, Type, []),
    invocation_placement(Type, Listed, Local),
    action_text(Body, Source),
    split_string(Source, "", " \t\r\n", Parts),
    ( (Parts == [""] ; Parts == []) -> Options = Local
    ; Options = [src_text(Source)|Local] ),
    ( Type == statechart -> check_nested_source(Options) ; true ).

invocation_placement(actor, Options, Options) :-
    memberchk(node(Node), Options), Node \== localhost, !,
    ( ( memberchk(target(_), Options) ; memberchk(io_target(_), Options) ) ->
        unsupported(remote_actor_io_target)
    ; true ).
invocation_placement(_, Options, Local) :-
    local_chart_options(Options, Local).

invocation_attributes(actor, [goal]).
invocation_attributes(toplevel, []).
invocation_attributes(server, [callback,state]).
invocation_attributes(supervisor, [children]).
invocation_attributes(statechart, []).

invocation_operands([], _, _, []).
invocation_operands([Name|Names], Attrs, Module, [Value|Values]) :-
    ( memberchk(Name=Text, Attrs) -> invocation_term(Text, Module, Value)
    ; throw(error(existence_error(attribute, Name), statechart_spawn/2)) ),
    check_operand(Name, Value),
    invocation_operands(Names, Attrs, Module, Values).

invocation_term(Atom, Module, Term) :-
    atom_string(Atom, Text),
    parse_term(Text, Module, Term, _),
    ( ground(Term) -> true ; throw(error(instantiation_error, statechart_spawn/2)) ).

check_operand(state, _) :- !.
check_operand(children, Value) :- !,
    ( is_list(Value) -> true ; throw(error(type_error(list, Value), statechart_spawn/2)) ).
check_operand(_, Value) :-
    ( callable(Value) -> true ; throw(error(type_error(callable, Value), statechart_spawn/2)) ).

check_invocation_options([], _, _).
check_invocation_options([Option|Rest], Type, Seen) :-
    ( invocation_source(Option) -> Next = Seen
    ; once(invocation_option(Type, Option)) ->
        functor(Option, Name, 1),
        ( memberchk(Name, Seen) -> invalid_chart(duplicate_spawn_option, Name)
        ; Next = [Name|Seen] )
    ; invalid_chart(statechart_spawn_option(Type), Option) ),
    check_invocation_options(Rest, Type, Next).

invocation_source(src_uri(Uri)) :- !, text_string(Uri, _).
invocation_source(Option) :- source_option(Option).

invocation_option(_, monitor(Bool)) :- memberchk(Bool, [true,false]).
invocation_option(_, link(Bool)) :- memberchk(Bool, [true,false]).
invocation_option(_, node(Node)) :- atom(Node).
invocation_option(_, io_target(Target)) :- invocation_target(Target).
invocation_option(Type, name(Name)) :- Type \== actor, atom(Name), Name \== undefined.
invocation_option(statechart, trace(Bool)) :- memberchk(Bool, [true,false]).
invocation_option(toplevel, session(Bool)) :- memberchk(Bool, [true,false]).
invocation_option(toplevel, time_limit(Limit)) :- invocation_limit(Limit).
invocation_option(toplevel, idle_limit(Limit)) :- invocation_limit(Limit).
invocation_option(Type, target(Target)) :-
    memberchk(Type, [actor,toplevel]), invocation_target(Target).
invocation_option(supervisor, strategy(Strategy)) :-
    memberchk(Strategy, [one_for_one,one_for_all,rest_for_one]).
invocation_option(supervisor, intensity(N)) :- integer(N), N >= 0.
invocation_option(supervisor, period(T)) :- number(T), T > 0, T < 1.0Inf.

invocation_target(Target) :- atom(Target) ; integer(Target).
invocation_target(Id@Node) :- integer(Id), atom(Node).
invocation_limit(infinite).
invocation_limit(Limit) :- number(Limit), Limit > 0, Limit < 1.0Inf.

check_nested_source(Options) :-
    findall(Option, (member(Option, Options), (Option = src_uri(_) ; Option = src_text(_))), Sources),
    ( Sources = [_] -> true
    ; Sources == [] ->
        throw(error(existence_error(option, src_uri_or_src_text), statechart_spawn/2))
    ; invalid_chart(single_statechart_source_option, Sources) ).

transition_model(Attrs, Body, Module, Key, transition(Key, Trigger, Guard, Action, Targets)) :-
    sxml_targets(Attrs, Targets),
    ( memberchk(after=After, Attrs) ->
        sxml_delay(After, Delay),
        Trigger = after(Delay), EventNames = []
    ; memberchk(on=Event, Attrs) ->
        event_pattern(Event, Module, Pattern, EventNames), Trigger = event(Pattern)
    ; Trigger = eventless, EventNames = [] ),
    condition(Attrs, Module, Guard, GuardNames),
    parse_action(Body, Module, Action, ActionNames),
    share_names(EventNames, GuardNames),
    append(EventNames, GuardNames, NamesInScope),
    share_names(NamesInScope, ActionNames).

event_pattern(Event, Module, Pattern, Names) :-
    atom_string(Event, Text),
    parse_term(Text, Module, Pattern, Names).

condition(Attrs, Module, Guard, Names) :-
    ( memberchk(if=Condition, Attrs) ->
        atom_string(Condition, Text), parse_term(Text, Module, Guard, Names)
    ; Guard = true, Names = [] ).

parse_action(Body, Module, Goal, Names) :-
    action_text(Body, Text),
    split_string(Text, "", " \t\r\n", Parts),
    ( ( Parts == [""] ; Parts == [] ) -> Goal = true, Names = []
    ; parse_term(Text, Module, Goal, Names) ).

action_text(Body, Text) :- concat_string(Body, Text).

% Read one term per XML field. Named variables are then shared across a
% transition's pattern, guard and action. Anonymous variables stay distinct.
parse_term(Text, Module, Term, Names) :-
    concat_string([Text, "\n.\n"], Source),
    setup_call_cleanup(open(string(Source), read, Stream),
        ( read_term(Stream, Term, [variable_names(Names)])@Module,
          read(Stream, end_of_file)@Module, at_eof(Stream) ),
        close(Stream)),
    !.
parse_term(Text, _, _, _) :-
    throw(error(syntax_error(sxml_prolog_term(Text)), statechart_spawn/2)).

share_names([], _).
share_names([Name=Var|Rest], Names) :-
    ( Name \== '_', memberchk(Name=Other, Names) -> Var = Other ; true ),
    share_names(Rest, Names).

unsupported(Feature) :-
    invalid_chart(n7_statechart_feature, Feature).

invalid_chart(Reason, Value) :-
    throw(error(domain_error(Reason, Value), statechart_spawn/2)).

run_chart(Chart, Trace) :-
    self(Self), actor_module(Self, Module),
    engine_self(Engine), get_engine_property(Engine, store, Store),
    Context = ctx(Chart, Trace, Module, Store),
    store_set(Store, sxml_queue, queue([], [])),
    store_set(Store, sxml_postponed, []),
    store_set(Store, sxml_timers, []),
    store_set(Store, sxml_pending, []),
    store_set(Store, sxml_children, []),
    store_set(Store, sxml_configuration, []),
    configuration_for([], [], Context, Initial),
    enter_states(Initial, Context),
    trace(Trace, configuration(Initial)),
    event_loop([], Context).

% Run to completion before taking another external message. Reoffer a
% snapshot only after a net change, so re-deferral cannot spin.
event_loop(Start, Context) :-
    Context = ctx(Chart, Trace, _, Store),
    store_get(Store, sxml_configuration, Active),
    ( member(Id, Active), node(Id, Chart, state(_, '$sxml_root'(0), final, _, _, _, _)) ->
        shutdown_chart(Active, Context)
    ; select_transitions(eventless, Active, Context, Selected) ->
        microstep(Selected, Active, Context),
        event_loop(Start, Context)
    ; dequeue_event(Store, Event) ->
        trace(Trace, internal_event(Event)),
        handle_event(Event, Active, Context),
        event_loop(Start, Context)
    ; Active \== Start, store_get(Store, sxml_postponed, Reversed), Reversed \== [] ->
        store_set(Store, sxml_postponed, []),
        reverse(Reversed, Reoffered),
        trace(Trace, reoffered(Reoffered)),
        store_set(Store, sxml_queue, queue(Reoffered, [])),
        event_loop(Active, Context)
    ; store_get(Store, sxml_pending, Pending), Pending \== [] ->
        store_set(Store, sxml_pending, []),
        invoke_states(Active, Pending, Context),
        event_loop(Active, Context)
    ; receive({Event -> true}),
      ( ground(Event), Event = '$sxml_halt'(From, Ref) ->
          shutdown_chart(Active, Context),
          send(From, '$sxml_halted'(Ref))
      ; ground(Event), Event = '$sxml_after'(Source, Key, Ref) ->
          handle_timer(Source, Key, Ref, Active, Context),
          event_loop(Active, Context)
      ; trace(Trace, external_event(Event)),
        handle_event(Event, Active, Context),
        event_loop(Active, Context)
      )
    ).

handle_event(Event, Active, Context) :-
    Context = ctx(Chart, Trace, _, Store),
    ( ground(Event), Event = '$sxml_after'(_, _, _) -> true
    ; select_transitions(event(Event), Active, Context, Selected) ->
        microstep(Selected, Active, Context)
    ; once((member(Leaf, Active), atomic_state(Leaf, Chart),
            ancestor_or_self(Leaf, Source, Chart),
            node(Source, Chart, state(_, _, _, _, _, _, Defers)),
            member(Template, Defers),
            copy_term(Template-Event, defer(Candidate, Guard)-Candidate),
            evaluate_guard(Guard, Context))) ->
        store_get(Store, sxml_postponed, Old),
        store_set(Store, sxml_postponed, [Event|Old]),
        trace(Trace, deferred(Event))
    ; trace(Trace, unmatched(Event))
    ).

select_transitions(Trigger, Active, Context, Selected) :-
    Context = ctx(Chart, _, _, _),
    findall(Choice,
        ( member(Leaf, Active), atomic_state(Leaf, Chart),
          once(select_from_leaf(Leaf, Trigger, Active, Context, Choice)) ),
        Candidates),
    filter_transitions(Candidates, [], Chart, Selected),
    Selected \= [].

select_from_leaf(Leaf, Trigger, Active, Context, Choice) :-
    Context = ctx(Chart, _, _, _),
    ancestor_or_self(Leaf, Source, Chart),
    node(Source, Chart, state(_, _, _, _, _, Transitions, _)),
    member(Template, Transitions),
    copy_term(Template-Trigger, transition(Key, Match, Guard, Action, Targets)-Match),
    evaluate_guard(Guard, Context),
    plan_transition(Source, Key, Action, Targets, Active, Chart, Choice).

evaluate_guard(Guard, ctx(_, _, Module, Store)) :-
    catch(call_chart_goal(Guard, Module), Error,
          (chart_error(Error, Store), fail)).

plan_transition(Source, Key, Action, Targets, Active, Chart,
                choice(Source, Key, Action, Targets, Exits)) :-
    ( Targets == [] -> Exits = []
    ; once((proper_ancestor(Source, Domain, Chart),
            all_descend_from(Targets, Domain, Chart))),
      findall(Id, (member(Id, Active), proper_ancestor(Id, Domain, Chart)), Exits)
    ).

all_descend_from([], _, _).
all_descend_from([Id|Ids], Parent, Chart) :-
    once(proper_ancestor(Id, Parent, Chart)),
    all_descend_from(Ids, Parent, Chart).

% At most one choice per leaf; the same ancestor choice may be nominated
% by several leaves. For overlaps a descendant source preempts an ancestor;
% otherwise the first nominated choice wins.
filter_transitions([], Selected, _, Selected).
filter_transitions([Choice|Rest], Kept, Chart, Selected) :-
    Choice = choice(Source, Key, _, _, _),
    ( memberchk(choice(Source, Key, _, _, _), Kept) -> Next = Kept
    ; once((member(Other, Kept), choices_conflict(Choice, Other),
            Other = choice(OtherSource, _, _, _, _),
            \+ proper_ancestor(Source, OtherSource, Chart))) -> Next = Kept
    ; remove_preempted(Kept, Choice, Remaining),
      append(Remaining, [Choice], Next)
    ),
    filter_transitions(Rest, Next, Chart, Selected).

remove_preempted([], _, []).
remove_preempted([Other|Rest], Choice, Kept) :-
    ( choices_conflict(Choice, Other) -> Kept = Tail ; Kept = [Other|Tail] ),
    remove_preempted(Rest, Choice, Tail).

choices_conflict(choice(_, _, _, _, Exits), choice(_, _, _, _, Other)) :-
    member(Id, Exits), memberchk(Id, Other), !.

microstep(Selected, Active, Context) :-
    Context = ctx(_, Trace, _, _),
    findall(Id, (member(Id, Active), exits_in_step(Id, Selected)), ToExit),
    remember_history(ToExit, Active, Context),
    findall(Id, (member(Id, Active), \+ memberchk(Id, ToExit)), Retained),
    choice_targets(Selected, Targets),
    configuration_for(Retained, Targets, Context, Desired),
    findall(Id, (member(Id, Desired), \+ memberchk(Id, Retained)), ToEnter),
    trace_choices(Selected, Active, Context),
    trace(Trace, microstep(ToExit, ToEnter)),
    reverse(ToExit, ExitOrder),
    exit_states(ExitOrder, Context),
    run_transitions(Selected, Context),
    enter_states(ToEnter, Context),
    trace(Trace, configuration(Desired)).

exits_in_step(Id, Selected) :-
    member(choice(_, _, _, _, Exits), Selected), memberchk(Id, Exits), !.

choice_targets([], []).
choice_targets([choice(_, _, _, Targets, _)|Rest], All) :-
    choice_targets(Rest, Tail),
    append(Targets, Tail, All).

trace_choices(_, _, ctx(_, false, _, _)) :- !.
trace_choices([], _, _).
trace_choices([choice(Source, _, _, Targets, Exits)|Rest], Active, Context) :-
    Context = ctx(_, Trace, _, _),
    ( Targets == [] -> Enters = []
    ; findall(Id, (member(Id, Active), \+ memberchk(Id, Exits)), Retained),
      configuration_for(Retained, Targets, Context, Desired),
      findall(Id, (member(Id, Desired), \+ memberchk(Id, Retained)), Enters)
    ),
    trace(Trace, transition(Source, Targets, Exits, Enters)),
    trace_choices(Rest, Active, Context).

run_transitions([], _).
run_transitions([choice(_, _, Action, _, _)|Rest], Context) :-
    Context = ctx(_, Trace, Module, Store),
    run_action(Action, Trace, Module, Store),
    run_transitions(Rest, Context).

remember_history(Exits, Active, ctx(Chart, _, _, Store)) :-
    ( member(history(Id, Parent, Mode, _), Chart), memberchk(Parent, Exits),
      findall(State, (member(State, Active), history_member(Mode, State, Parent, Chart)), Saved),
      store_set(Store, sxml_history(Id), Saved),
      fail
    ; true ).

history_member(shallow, State, Parent, Chart) :- parent(State, Parent, Chart).
history_member(deep, State, Parent, Chart) :-
    atomic_state(State, Chart), once(proper_ancestor(State, Parent, Chart)).

configuration_for(Retained, Targets, Context, Configuration) :-
    Context = ctx(Chart, _, _, _),
    resolve_targets(Targets, Context, [], Resolved),
    append(Retained, Resolved, Requested),
    subtree('$sxml_root'(0), Requested, Chart, [_|Configuration]).

validate_history_defaults(Chart) :-
    findall(Id, member(history(Id, _, _, _), Chart), Histories),
    resolve_targets(Histories, ctx(Chart, false, none, none), [], _).

resolve_targets([], _, _, []).
resolve_targets([Id|Rest], Context, Seen, Resolved) :-
    Context = ctx(Chart, _, _, Store),
    ( node(Id, Chart, history(_, _, _, Default)) ->
        ( memberchk(Id, Seen) -> invalid_chart(history_cycle, Id) ; true ),
        ( Store \== none, store_get(Store, sxml_history(Id), Saved) -> Next = Saved
        ; Next = Default ),
        resolve_targets(Next, Context, [Id|Seen], Expanded)
    ; Expanded = [Id] ),
    resolve_targets(Rest, Context, Seen, Tail),
    append(Expanded, Tail, Resolved).

% Fill default branches only where no explicit target (or retained active
% state) chose a branch. In parallel, independently fill each region.
subtree(Id, Requested, Chart, [Id|Children]) :-
    node(Id, Chart, state(_, _, Kind, _, _, _, _)),
    ( Kind = compound(Initial) ->
        ( once((member(state(Child, Id, _, _, _, _, _), Chart),
                requested_branch(Child, Requested, Chart))) -> true
        ; Child = Initial ),
        subtree(Child, Requested, Chart, Children)
    ; Kind == parallel ->
        findall(Child, member(state(Child, Id, _, _, _, _, _), Chart), Regions),
        subtrees(Regions, Requested, Chart, Children)
    ; Children = [] ).

subtrees([], _, _, []).
subtrees([Id|Rest], Requested, Chart, States) :-
    subtree(Id, Requested, Chart, Head),
    subtrees(Rest, Requested, Chart, Tail),
    append(Head, Tail, States).

requested_branch(Id, Requested, Chart) :-
    member(State, Requested), ancestor_or_self(State, Id, Chart), !.

node(Id, Chart, Node) :-
    member(Node, Chart), arg(1, Node, Id), !.

parent(Id, Parent, Chart) :-
    Id \== '$sxml_root'(0),
    node(Id, Chart, Node), arg(2, Node, Parent).

ancestor_or_self(Id, Id, _).
ancestor_or_self(Id, Ancestor, Chart) :- proper_ancestor(Id, Ancestor, Chart).

proper_ancestor(Id, Ancestor, Chart) :-
    parent(Id, Parent, Chart),
    ( Ancestor = Parent ; proper_ancestor(Parent, Ancestor, Chart) ).

atomic_state(Id, Chart) :-
    node(Id, Chart, state(_, _, Kind, _, _, _, _)),
    ( Kind == parallel -> \+ member(state(_, Id, _, _, _, _, _), Chart)
    ; memberchk(Kind, [atomic, final]) ).

shutdown_chart(Active, Context) :-
    reverse(Active, ExitOrder),
    exit_states(ExitOrder, Context).

exit_states([], _).
exit_states([Id|Rest], Context) :-
    Context = ctx(Chart, Trace, Module, Store),
    node(Id, Chart, state(_, _, _, _, Exits, _, _)),
    cancel_state_timers(Id, Store),
    run_actions(Exits, Trace, Module, Store),
    stop_state_children(Id, Store),
    store_get(Store, sxml_configuration, Active),
    delete(Id, Active, Remaining),
    store_set(Store, sxml_configuration, Remaining),
    exit_states(Rest, Context).

enter_states([], _).
enter_states([Id|Rest], Context) :-
    Context = ctx(Chart, Trace, Module, Store),
    node(Id, Chart, state(_, Parent, Kind, Entries, _, Transitions, _)),
    store_get(Store, sxml_configuration, Active),
    findall(State, (member(state(State, _, _, _, _, _, _), Chart),
                    ( State == Id -> true ; memberchk(State, Active) )), Updated),
    store_set(Store, sxml_configuration, Updated),
    schedule_timers(Transitions, Id, Store),
    ( memberchk(invocation('$invoke'(Id), _, _, _, _), Chart) ->
        store_get(Store, sxml_pending, Pending),
        store_set(Store, sxml_pending, [Id|Pending])
    ; true ),
    run_actions(Entries, Trace, Module, Store),
    ( Kind == final, Parent \== '$sxml_root'(0) ->
        ( node(Parent, Chart, state(_, _, parallel, _, _, _, _)) ->
            complete_parallel(Parent, Updated, Chart, Store)
        ; enqueue_event(Store, done(Parent)),
          ( parent(Parent, Outer, Chart) ->
              complete_parallel(Outer, Updated, Chart, Store)
          ; true )
        )
    ; true ),
    enter_states(Rest, Context).

% Invocations are considered in state and declaration order only after
% eventless, internal and reoffered events have settled.
invoke_states([], _, _).
invoke_states([Id|Rest], Pending, Context) :-
    Context = ctx(Chart, _, _, _),
    ( memberchk(Id, Pending) ->
        findall(child(Type, Operands, Options, Base),
                member(invocation('$invoke'(Id), Type, Operands, Options, Base), Chart),
                Children),
        invoke_children(Children, Id, Context)
    ; true ),
    invoke_states(Rest, Pending, Context).

invoke_children([], _, _).
invoke_children([child(Type, Operands, Options, Base)|Rest], State, Context) :-
    Context = ctx(_, Trace, Module, Store),
    ( Type == statechart -> Resolved = Options
    ; invocation_sources(Options, Base, Resolved) ),
    ( start_invocation(Type, Operands, ['$state_owned'|Resolved], Base, Module, Pid) -> true
    ; throw(error(statechart_invocation_failed(Type, State), statechart_spawn/2)) ),
    store_get(Store, sxml_children, Children),
    store_set(Store, sxml_children, [owned_child(State, Pid)|Children]),
    trace(Trace, invoked(Type, Pid, State)),
    enqueue_event(Store, spawned(Pid)),
    invoke_children(Rest, State, Context).

invocation_sources([], _, []).
invocation_sources([Option|Rest], Base, [Source|Sources]) :-
    ( Option = src_uri(Uri) -> sxml_prolog_source(Uri, Base, Text), Source = src_text(Text)
    ; Source = Option ),
    invocation_sources(Rest, Base, Sources).

start_invocation(actor, [Goal], Options, _, Module, Pid) :-
    ( select(target(Target), Options, Remaining) ->
        ( memberchk(io_target(_), Remaining) -> ActorOptions = Remaining
        ; ActorOptions = [io_target(Target)|Remaining] )
    ; ActorOptions = Options ),
    spawn(Goal, Pid, ActorOptions)@Module.
start_invocation(toplevel, [], Options, _, Module, Pid) :-
    toplevel_spawn(Pid, Options)@Module.
start_invocation(server, [Callback,State], Options, _, Module, Pid) :-
    server_spawn(Callback, State, Pid, Options)@Module.
start_invocation(supervisor, [Specs], Options, _, Module, Pid) :-
    supervisor_spawn(Specs, Pid, Options)@Module.
start_invocation(statechart, [], Options, Base, Module, Pid) :-
    statechart_spawn_at(Pid, Options, Base, Module).

stop_state_children(Id, Store) :-
    store_get(Store, sxml_pending, Pending),
    ( delete(Id, Pending, Rest) -> true ; Rest = Pending ),
    store_set(Store, sxml_pending, Rest),
    store_get(Store, sxml_children, Children),
    stop_state_children(Children, Id, Remaining),
    store_set(Store, sxml_children, Remaining).

stop_state_children([], _, []).
stop_state_children([Child|Rest], Id, Remaining) :-
    ( Child = owned_child(Id, Pid) ->
        % A new activation can reuse the same child name.
        setup_call_cleanup(monitor(Pid, Ref),
            ( exit(Pid, stop), receive({down(Pid, Ref, _) -> true}) ),
            demonitor(Ref, [flush])),
        Remaining = Tail
    ; Remaining = [Child|Tail] ),
    stop_state_children(Rest, Id, Tail).

complete_parallel(Id, Active, Chart, Store) :-
    ( node(Id, Chart, state(_, _, parallel, _, _, _, _)),
      in_final_state(Id, Active, Chart) ->
        enqueue_event(Store, done(Id)),
        ( parent(Id, Parent, Chart) ->
            complete_parallel(Parent, Active, Chart, Store)
        ; true )
    ; true ).

in_final_state(Id, Active, Chart) :-
    node(Id, Chart, state(_, _, Kind, _, _, _, _)),
    ( Kind == final -> memberchk(Id, Active)
    ; Kind = compound(_) ->
        member(State, Active), node(State, Chart, state(_, Id, final, _, _, _, _))
    ; Kind == parallel ->
        \+ (member(state(Child, Id, _, _, _, _, _), Chart),
            \+ in_final_state(Child, Active, Chart))
    ).

schedule_timers([], _, _).
schedule_timers([transition(Key, Trigger, _, _, _)|Rest], Id, Store) :-
    ( Trigger = after(Delay) ->
        self(Self), fresh_reference(Ref),
        store_get(Store, sxml_timers, Timers),
        store_set(Store, sxml_timers, [timer(Id, Key, Ref)|Timers]),
        send(Self, '$sxml_after'(Id, Key, Ref), [delay(Delay), id(Ref)])
    ; true ),
    schedule_timers(Rest, Id, Store).

cancel_state_timers(Id, Store) :-
    store_get(Store, sxml_timers, Timers),
    cancel_state_timers(Timers, Id, Remaining),
    store_set(Store, sxml_timers, Remaining).

cancel_state_timers([], _, []).
cancel_state_timers([Timer|Rest], Id, Remaining) :-
    ( Timer = timer(Id, _, Ref) -> cancel(Ref), Remaining = Tail
    ; Remaining = [Timer|Tail] ),
    cancel_state_timers(Rest, Id, Tail).

handle_timer(Source, Key, Ref, Active, Context) :-
    Context = ctx(Chart, Trace, _, Store),
    store_get(Store, sxml_timers, Timers),
    ( memberchk(timer(Source, Key, Ref), Timers) ->
        delete(timer(Source, Key, Ref), Timers, Remaining),
        store_set(Store, sxml_timers, Remaining),
        node(Source, Chart, state(_, _, _, _, _, Transitions, _)),
        memberchk(transition(Key, after(Delay), Guard, Action, Targets), Transitions),
        trace(Trace, internal_event(after(Source, Delay))),
        ( evaluate_guard(Guard, Context) ->
            plan_transition(Source, Key, Action, Targets, Active, Chart, Choice),
            microstep([Choice], Active, Context)
        ; true )
    ; true ).

run_actions([], _, _, _).
run_actions([Goal|Rest], Trace, Module, Store) :-
    copy_term(Goal, Instance),
    run_action(Instance, Trace, Module, Store),
    run_actions(Rest, Trace, Module, Store).

run_action(Goal, Trace, Module, Store) :-
    trace(Trace, execution(Goal)),
    catch(
        ( call_chart_goal(Goal, Module) -> true
        ; enqueue_event(Store, error(failure(Goal))) ),
        Error,
        chart_error(Error, Store)).

% Runtime control signals belong to the actor host, not to the chart.
chart_error(abort, _) :- !, throw(abort).
chart_error('$abort_goal', _) :- !, throw('$abort_goal').
chart_error('$ptcp_time_limit', _) :- !, throw('$ptcp_time_limit').
chart_error(unwind(Reason), _) :- !, throw(unwind(Reason)).
chart_error(Error, Store) :- enqueue_event(Store, error(Error)).

call_chart_goal(Goal, Module) :-
    prepare_actor_goal(Goal, Prepared),
    once(call(Prepared)@Module).

trace(true, Event) :- !, browser_chart_trace(Event).
trace(false, _).

raise(Event) :-
    chart_store(Store),
    enqueue_event(Store, Event).
in(State) :-
    chart_store(Store),
    store_get(Store, sxml_configuration, Configuration),
    member(State, Configuration).

chart_store(Store) :-
    engine_self(Engine), get_engine_property(Engine, store, Store),
    ( store_get(Store, sxml_queue, _) -> true
    ; throw(error(permission_error(access, statechart_context, self), statechart_actor)) ).

enqueue_event(Store, Event) :-
    store_get(Store, sxml_queue, queue(Front, Back)),
    store_set(Store, sxml_queue, queue(Front, [Event|Back])).

dequeue_event(Store, Event) :-
    store_get(Store, sxml_queue, queue(Front, Back)),
    ( Front = [Event|Rest] -> NewBack = Back
    ; reverse(Back, [Event|Rest]), NewBack = [] ),
    store_set(Store, sxml_queue, queue(Rest, NewBack)).

statechart_halt(Pid, Reply) :-
    halt_chart(Pid, Reply, infinite).

statechart_halt(Pid, Reply, Timeout) :-
    ( var(Timeout) -> throw(error(instantiation_error, statechart_halt/3))
    ; \+ number(Timeout) -> throw(error(type_error(number, Timeout), statechart_halt/3))
    ; Timeout < 0 -> throw(error(domain_error(nonnegative_timeout, Timeout), statechart_halt/3))
    ; halt_chart(Pid, Reply, Timeout)
    ).

halt_chart(Pid, Reply, Timeout) :-
    self(Self), fresh_reference(Request),
    setup_call_cleanup(monitor(Pid, Monitor),
        ( send(Pid, '$sxml_halt'(Self, Request)),
          halt_options(Timeout, Pid, Monitor, Reply, Options),
          receive({
                '$sxml_halted'(Request) -> Reply = true
              ; down(Pid, Monitor, _) -> Reply = killed
          }, Options) ),
        demonitor(Monitor, [flush])).

halt_options(infinite, _, _, _, []) :- !.
halt_options(Timeout, Pid, Monitor, Reply, [timeout(Timeout), on_timeout(Force)]) :-
    Force = (exit(Pid, kill), receive({down(Pid, Monitor, _) -> Reply = killed})).
