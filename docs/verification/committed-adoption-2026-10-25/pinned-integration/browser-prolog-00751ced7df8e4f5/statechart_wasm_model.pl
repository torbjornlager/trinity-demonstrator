:- module(statechart_wasm_model, [
    statechart_wasm_parse_text/1,
    statechart_wasm_parse_stream/1,
    statechart_wasm_validate_text/2
]).

/** <module> Statechart Model Parsing (SWI-WASM port)

XML parsing and model fact generation for the SWI-WASM statechart
interpreter. The asserted facts live in the `statechart_wasm` module.

Differences from the desktop `statechart_model`:

  - No file-based entry point. The host (JS or test harness) is
    expected to pass XML as text or open a stream itself. This avoids
    the need for `source_utils:open_source_uri/2` and HTTP fetch.
  - All asserts target `statechart_wasm` instead of `statechart_actor`.
  - `<spawn>` elements produce `to_be_invoked/3` facts which the runtime's
    invoke/1 executes (spawning a browser worker actor/toplevel).
  - `<datamodel>` predicates are tracked (datamodel_predicate/1) so clean/0
    can abolish them and not leak one chart's data/rules into the next.
*/

:- use_module(library(option)).
:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(sxml_schema, [
    load_sxml_structure/2,
    sxml_validate_text/2
]).

%   Web-Prolog operators used inside typed <spawn> attributes/options and
%   <go>/<onentry> scripts (e.g. `Pid ! pong`, `Id@Node`, library(wasm)'s
%   `:=`/`#`).  atom_to_term/3 below needs these visible at parse
%   time.  A module-local `:- op` is NOT honoured by read_term/3 called
%   from this module, so declare them in `user` (global), matching how
%   the operators are globally available in the desktop node where the
%   actor layer defines them.
:- op(800,  xfx, user:(!)).
:- op(200,  xfx, user:(@)).
:- op(1000, xfy, user:if).
:- op(990,  xfx, user:(:=)).
:- op(100,  fx,  user:(#)).


%!  statechart_wasm_parse_text(+Text) is det.
%
%   Parse the statechart XML in Text (atom or string) and assert the
%   model facts into the `statechart_wasm` module.

statechart_wasm_parse_text(Text) :-
    setup_call_cleanup(
        open_string(Text, Stream),
        load_xml_capturing_errors(Stream, ListOfContent),
        close(Stream)),
    model_generate(ListOfContent, null).


%!  statechart_wasm_parse_stream(+Stream) is det.
%
%   Parse the statechart XML from Stream and assert the model facts.
%   Stream is closed by the caller.

statechart_wasm_parse_stream(Stream) :-
    load_xml_capturing_errors(Stream, ListOfContent),
    model_generate(ListOfContent, null).


load_xml_capturing_errors(Stream, Content) :-
    load_sxml_structure(Stream, Content).


%!  statechart_wasm_validate_text(+Text, -Diagnostics) is det.
%
%   Validate without modifying the singleton browser statechart model.
statechart_wasm_validate_text(Text, Diagnostics) :-
    sxml_validate_text(Text, Diagnostics).


model_generate([], _).
model_generate([element(Name, Attrs, Children)|Rest], Parent) :-
    model_generate_node(Name, Attrs, Children, Parent, NewParent),
    !,
    model_generate(Children, NewParent),
    model_generate(Rest, Parent).
model_generate([_|Rest], Parent) :-
    model_generate(Rest, Parent).


validate_statechart_version(Attrs) :-
    (   option(version(Version), Attrs)
    ->  (   Version == '0.2'
        ->  true
        ;   throw(error(domain_error(statechart_version, Version),
                        context(statechart_wasm_model:model_generate_node/5,
                                'the supported SXML version is 0.2')))
        )
    ;   throw(error(existence_error(attribute, version),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<statechart> requires a version attribute')))
    ).

model_generate_node(statechart, Attrs, _Children, Parent, ID) :-
    validate_statechart_version(Attrs),
    (   option(initial(InitID), Attrs)
    ->  true
    ;   throw(error(existence_error(attribute, initial),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<statechart> requires an initial attribute')))
    ),
    option(id(ID), Attrs, statechart_wasm),
    gennum(N),
    model_assert(n(N, ID)),
    model_assert(state(ID, Parent)),
    model_assert(initial(InitID)).
model_generate_node(state, Attrs, Children, Parent, ID) :-
    validate_state_initial(Attrs, Children),
    option(id(ID), Attrs),
    gennum(N),
    model_assert(n(N, ID)),
    model_assert(state(ID, Parent)),
    (   option(initial(Initial), Attrs)
    ->  model_assert(transition(init(ID), '', true, [Initial], []))
    ;   true
    ).
model_generate_node(parallel, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    gennum(N),
    model_assert(n(N, ID)),
    model_assert(parallel(ID, Parent)).
%  `type` plus the type-specific operands describe the invocation itself.
%  `options` is a ground Prolog list containing all optional settings.  Body
%  text becomes one src_text fragment without being reparsed and serialised by
%  the statechart model.
model_generate_node(spawn, Attrs, Children, Parent, _ID) :-
    (   select_option(type(Type), Attrs, Attrs1)
    ->  true
    ;   throw(error(existence_error(attribute, type),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn> requires a type attribute')))
    ),
    validate_spawn_type(Type),
    spawn_element_options(Type, Attrs1, Options0),
    (   children_text(Children, Src)
    ->  Options = [src_text(Src)|Options0]
    ;   Options = Options0
    ),
    validate_spawn_options(Type, Options),
    model_assert(to_be_invoked(Parent, Type, Options)).
model_generate_node(history, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    option(type(Type), Attrs, shallow),
    model_assert(history(ID, Parent, Type)).
model_generate_node(go, Attrs, Children, Parent, _ID) :-
    transition_trigger(Attrs, Parent, Trigger, Bindings0),
    option(if(CondAtom), Attrs, true),
    my_atom_to_term(CondAtom, Cond, Bindings1),
    unify_bindings(Bindings0, Bindings1, Bindings2),
    (   option(to(Targets), Attrs)
    ->  transition_targets(Targets, TargetList)
    ;   TargetList = []
    ),
    children_to_actions(Children, Actions, Bindings2),
    assert_transition(Trigger, Parent, Cond, TargetList, Actions).
model_generate_node(defer, Attrs, _Children, Parent, _ID) :-
    (   option(on(EventAtom), Attrs)
    ->  true
    ;   throw(error(existence_error(attribute, on),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<defer> requires an on attribute')))
    ),
    my_atom_to_term(EventAtom, Event, Bindings0),
    option(if(CondAtom), Attrs, true),
    my_atom_to_term(CondAtom, Cond, Bindings1),
    unify_bindings(Bindings0, Bindings1, _),
    model_assert(defer(Parent, Event, Cond)).
model_generate_node(final, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    gennum(N),
    model_assert(n(N, ID)),
    model_assert(final(ID, Parent)).
model_generate_node(initial, _Attrs, _Children, _Parent, _ID) :-
    throw(error(domain_error(sxml_element, initial),
                context(statechart_wasm_model:model_generate_node/5,
                        'the <initial> element is not supported; use the initial attribute on its parent'))).
model_generate_node(onentry, _Attrs, Children, Parent, _ID) :-
    children_to_actions(Children, Actions, []),
    model_assert(onentry(Parent, Actions)).
model_generate_node(onexit, _Attrs, Children, Parent, _ID) :-
    children_to_actions(Children, Actions, []),
    model_assert(onexit(Parent, Actions)).
model_generate_node(datamodel, _Attrs, Children, _Parent, _ID) :-
    (   children_text(Children, Text)
    ->  load_datamodel(Text)
    ;   true
    ).


transition_targets(Targets, TargetList) :-
    (   is_list(Targets)
    ->  TargetList = Targets
    ;   atomic_list_concat(TargetList, ' ', Targets)
    ).


model_assert(Fact) :-
    assertz(statechart_wasm:Fact).


has_state_child(Children) :-
    member(element(Name, _Attrs, _Grandchildren), Children),
    memberchk(Name, [state, parallel, final]),
    !.

validate_state_initial(Attrs, Children) :-
    (   has_state_child(Children),
        \+ option(initial(_), Attrs)
    ->  throw(error(existence_error(attribute, initial),
                    context(statechart_wasm_model:model_generate_node/5,
                            'a compound <state> requires an initial attribute')))
    ;   true
    ).


transition_trigger(Attrs, Parent, after(Key, Delay), []) :-
    option(after(DelayAtom), Attrs),
    !,
    (   option(on(_), Attrs)
    ->  throw(error(domain_error(statechart_transition_trigger,
                                 on_and_after),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<go> cannot have both on and after attributes')))
    ;   true
    ),
    after_delay(DelayAtom, Delay),
    gennum(N),
    Key = after(Parent, N).
transition_trigger(Attrs, _Parent, event(Event), Bindings) :-
    option(on(EventAtom), Attrs, ''),
    my_atom_to_term(EventAtom, Event, Bindings).

after_delay(Value, Delay) :-
    (   number(Value)
    ->  Delay0 = Value
    ;   atom(Value),
        catch(atom_number(Value, Delay0), _, fail)
    ),
    Delay0 >= 0,
    Delay0 < 1.0Inf,
    !,
    Delay = Delay0.
after_delay(Value, _Delay) :-
    throw(error(domain_error(non_negative_number, Value),
                context(statechart_wasm_model:model_generate_node/5,
                        'the after attribute is a delay in seconds'))).

assert_transition(event(Event), Parent, Cond, Targets, Actions) :-
    model_assert(transition(Parent, Event, Cond, Targets, Actions)).
assert_transition(after(Key, Delay), Parent, Cond, Targets, Actions) :-
    model_assert(after_transition(Parent, Key, Delay, Cond, Targets, Actions)).


children_to_actions([], [], _Bindings).
children_to_actions([Child|Children], [Action|Actions], Bindings) :-
    child_to_action(Child, Action, Bindings),
    !,
    children_to_actions(Children, Actions, Bindings).
children_to_actions([_|Children], Actions, Bindings) :-
    children_to_actions(Children, Actions, Bindings).

child_to_action(Children, Action, Bindings) :-
    atom(Children),
    \+ blank_atom(Children),
    my_atom_to_term(Children, Expr, Bindings1),
    unify_bindings(Bindings, Bindings1, _),
    Action = script(Expr).

my_atom_to_term(Atom, Term, Bindings) :-
    my_atom_to_term_2(Atom, Term, Bindings).

my_atom_to_term_2('', '', []) :-
    !.
my_atom_to_term_2(Atom, Term, Bindings) :-
    atom_to_term(Atom, Term, Bindings).

spawn_element_options(Type, Attrs0, Options) :-
    select_option(options(OptionsText), Attrs0, Attrs1, []),
    parse_spawn_options(OptionsText, ListedOptions),
    spawn_required_options(Type, Attrs1, Attrs2, RequiredOptions),
    reject_remaining_spawn_attributes(Type, Attrs2),
    append(RequiredOptions, ListedOptions, Options).

parse_spawn_options([], []) :-
    !.
parse_spawn_options(Text, Options) :-
    catch(atom_to_term(Text, Term, _Bindings), _, fail),
    !,
    (   is_list(Term)
    ->  Options = Term
    ;   throw(error(type_error(list, Term),
                    context(statechart_wasm_model:model_generate_node/5,
                            'the options attribute must be a Prolog list')))
    ).
parse_spawn_options(Text, _) :-
    throw(error(syntax_error(spawn_options(Text)),
                context(statechart_wasm_model:model_generate_node/5,
                        'the options attribute must contain a valid Prolog term'))).

spawn_required_options(actor, Attrs0, Attrs, [goal(Goal)]) :-
    (   select_option(goal(GoalText), Attrs0, Attrs)
    ->  typed_attribute_value(GoalText, Goal),
        (   callable(Goal)
        ->  true
        ;   throw(error(type_error(callable, Goal),
                        context(statechart_wasm_model:model_generate_node/5,
                                'the goal attribute must be callable')))
        )
    ;   throw(error(existence_error(attribute, goal),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn type="actor"> requires a goal attribute')))
    ).
spawn_required_options(toplevel, Attrs, Attrs, []).
spawn_required_options(server, Attrs0, Attrs, [callback(Callback), state(State)]) :-
    (   select_option(callback(CallbackText), Attrs0, Attrs1)
    ->  typed_attribute_value(CallbackText, Callback),
        (   callable(Callback)
        ->  true
        ;   throw(error(type_error(callable, Callback),
                        context(statechart_wasm_model:model_generate_node/5,
                                'the callback attribute must be callable')))
        )
    ;   throw(error(existence_error(attribute, callback),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn type="server"> requires a callback attribute')))
    ),
    (   select_option(state(StateText), Attrs1, Attrs)
    ->  typed_attribute_value(StateText, State)
    ;   throw(error(existence_error(attribute, state),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn type="server"> requires a state attribute')))
    ).
spawn_required_options(supervisor, Attrs0, Attrs, [children(Children)]) :-
    (   select_option(children(ChildrenText), Attrs0, Attrs)
    ->  typed_attribute_value(ChildrenText, Children),
        (   is_list(Children)
        ->  true
        ;   throw(error(type_error(list, Children),
                        context(statechart_wasm_model:model_generate_node/5,
                                'the children attribute must be a Prolog list')))
        )
    ;   throw(error(existence_error(attribute, children),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn type="supervisor"> requires a children attribute')))
    ).
spawn_required_options(statechart, Attrs, Attrs, []).

reject_remaining_spawn_attributes(_, []).
reject_remaining_spawn_attributes(Type, [Name=_|_]) :-
    throw(error(domain_error(statechart_spawn_attribute(Type), Name),
                context(statechart_wasm_model:model_generate_node/5,
                        'only required operands may be direct spawn attributes'))).

typed_attribute_value(Value0, Value) :-
    atom(Value0),
    !,
    atom_to_term(Value0, Parsed, _Bindings),
    Value = Parsed.
typed_attribute_value(Value, Value).

validate_spawn_type(actor) :- !.
validate_spawn_type(toplevel) :- !.
validate_spawn_type(server) :- !.
validate_spawn_type(supervisor) :- !.
validate_spawn_type(statechart) :- !.
validate_spawn_type(Type) :-
    throw(error(domain_error(statechart_spawn_type, Type),
                context(statechart_wasm_model:model_generate_node/5,
                        'supported spawn types are actor, toplevel, server, supervisor, and statechart'))).

validate_spawn_options(Type, Options) :-
    maplist(validate_spawn_option(Type), Options),
    reject_duplicate_spawn_options(Options),
    validate_spawn_source_contract(Type, Options).

validate_spawn_option(actor, goal(Goal)) :-
    ground(Goal),
    callable(Goal),
    !.
validate_spawn_option(server, callback(Callback)) :-
    ground(Callback),
    callable(Callback),
    !.
validate_spawn_option(server, state(State)) :- ground(State), !.
validate_spawn_option(supervisor, children(Children)) :-
    ground(Children),
    is_list(Children),
    !.
validate_spawn_option(Type, Option) :-
    ground(Option),
    allowed_spawn_option(Type, Option),
    !.
validate_spawn_option(Type, Option) :-
    throw(error(domain_error(statechart_spawn_option(Type), Option),
                context(statechart_wasm_model:model_generate_node/5,
                        'unsupported or invalid option for this spawn type'))).

allowed_spawn_option(_, monitor(Bool)) :- boolean_value(Bool).
allowed_spawn_option(_, link(Bool)) :- boolean_value(Bool).
allowed_spawn_option(_, node(_)).
allowed_spawn_option(_, io_target(_)).
allowed_spawn_option(Type, src_text(Text)) :- source_text_type(Type), text_value(Text).
allowed_spawn_option(Type, src_uri(URI)) :- source_text_type(Type), text_value(URI).
allowed_spawn_option(Type, src_list(Terms)) :- supplemental_source_type(Type), is_list(Terms).
allowed_spawn_option(Type, src_predicates(PIs)) :- supplemental_source_type(Type), predicate_indicators(PIs).
allowed_spawn_option(actor, target(_)).
allowed_spawn_option(toplevel, target(_)).
allowed_spawn_option(toplevel, session(Bool)) :- boolean_value(Bool).
allowed_spawn_option(toplevel, time_limit(Limit)) :- spawn_limit(Limit).
allowed_spawn_option(toplevel, idle_limit(Limit)) :- spawn_limit(Limit).
allowed_spawn_option(toplevel, name(Name)) :- atomic(Name).
allowed_spawn_option(server, name(Name)) :- atomic(Name).
allowed_spawn_option(supervisor, strategy(Strategy)) :-
    memberchk(Strategy, [one_for_one, one_for_all, rest_for_one]).
allowed_spawn_option(supervisor, intensity(Intensity)) :-
    integer(Intensity), Intensity > 0.
allowed_spawn_option(supervisor, period(Period)) :-
    number(Period), Period > 0.
allowed_spawn_option(supervisor, name(Name)) :- atomic(Name).
allowed_spawn_option(statechart, name(Name)) :- atomic(Name).
allowed_spawn_option(statechart, trace(Bool)) :- boolean_value(Bool).

source_text_type(Type) :- prolog_source_type(Type), !.
source_text_type(statechart).

prolog_source_type(actor).
prolog_source_type(toplevel).
prolog_source_type(server).
prolog_source_type(supervisor).

supplemental_source_type(Type) :- prolog_source_type(Type), !.
supplemental_source_type(statechart).

boolean_value(true).
boolean_value(false).

text_value(Value) :- atom(Value), !.
text_value(Value) :- string(Value).

spawn_limit(infinite) :- !.
spawn_limit(Limit) :- number(Limit), Limit > 0.

predicate_indicators(PIs) :-
    is_list(PIs),
    maplist(predicate_indicator, PIs).

predicate_indicator(Name/Arity) :-
    atom(Name),
    integer(Arity),
    Arity >= 0.

validate_spawn_source_contract(statechart, Options) :-
    !,
    include(statechart_source_option, Options, Sources),
    (   Sources = [_]
    ->  true
    ;   Sources == []
    ->  throw(error(existence_error(option, src_uri_or_src_text),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn type="statechart"> requires one src_uri/1 or src_text/1 source')))
    ;   throw(error(domain_error(single_statechart_source_option, Sources),
                    context(statechart_wasm_model:model_generate_node/5,
                            '<spawn type="statechart"> accepts exactly one source')))
    ).
validate_spawn_source_contract(_, _).

statechart_source_option(src_text(_)).
statechart_source_option(src_uri(_)).

reject_duplicate_spawn_options(Options) :-
    reject_duplicate_spawn_options(Options, []).

reject_duplicate_spawn_options([], _).
reject_duplicate_spawn_options([Option|Options], Seen) :-
    functor(Option, Name, _),
    (   repeatable_source_option(Name)
    ->  Seen1 = Seen
    ;   memberchk(Name, Seen)
    ->  throw(error(permission_error(duplicate, spawn_option, Name),
                    context(statechart_wasm_model:model_generate_node/5,
                            'a spawn option may be specified only once')))
    ;   Seen1 = [Name|Seen]
    ),
    reject_duplicate_spawn_options(Options, Seen1).

repeatable_source_option(src_text).
repeatable_source_option(src_uri).
repeatable_source_option(src_list).
repeatable_source_option(src_predicates).

unify_bindings(Bs1, Bs2, Bs3) :-
    unify_bindings(Bs2, Bs1, Bs3, Bs1).

unify_bindings([], _Existing, Acc, Acc).
unify_bindings([Name=Var|Rest], Existing, Bs3, Acc0) :-
    (   memberchk(Name=ExistingVar, Existing)
    ->  Var = ExistingVar,
        Acc1 = Acc0
    ;   Acc1 = [Name=Var|Acc0]
    ),
    unify_bindings(Rest, Existing, Bs3, Acc1).

blank_atom(Atom) :-
    atom(Atom),
    atom_codes(Atom, Codes),
    Codes \= [],
    forall(member(Code, Codes), char_type(Code, space)).

children_text(Children, Text) :-
    findall(Atom,
            ( member(Atom, Children),
              atom(Atom),
              \+ blank_atom(Atom)
            ),
            Atoms),
    Atoms \= [],
    atomic_list_concat(Atoms, '\n', Text).

%!  load_datamodel(+Text) is det.
%
%   Read Prolog clauses from Text and assert them into the
%   `statechart_wasm` module so that <onentry>/<onexit> scripts can
%   refer to them.  Uses open_string/2 (portable) instead of memfiles.

load_datamodel(Text) :-
    datamodel_dynamic_snapshot(Before),
    setup_call_cleanup(
        open_string(Text, Stream),
        read_datamodel_terms(Stream),
        close(Stream)),
    %  Track every predicate the datamodel added, including ones created by
    %  directives (`:- dynamic(p/1)`, `:- assertz(...)`) that assert_local/1
    %  does not see, by diffing the module's dynamic predicates around the
    %  load.  clean/0 then abolishes them so nothing leaks into the next chart.
    datamodel_dynamic_snapshot(After),
    subtract(After, Before, New),
    forall(member(PI, New), track_datamodel_predicate(PI)).

%   The predicate indicators currently dynamic in the statechart_wasm module.
datamodel_dynamic_snapshot(PIs) :-
    findall(F/N,
            ( predicate_property(statechart_wasm:Head, dynamic),
              functor(Head, F, N) ),
            PIs0),
    sort(PIs0, PIs).

read_datamodel_terms(Stream) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  true
    ;   expand_and_assert(Term),
        read_datamodel_terms(Stream)
    ).

expand_and_assert(Term) :-
    expand_term(Term, ExpandedTerm),
    (   is_list(ExpandedTerm)
    ->  maplist(assert_local, ExpandedTerm)
    ;   assert_local(ExpandedTerm)
    ).

assert_local(:-(Head, Body)) :- !,
    functor(Head, F, N),
    dynamic(statechart_wasm:F/N),
    track_datamodel_predicate(F/N),
    assertz(statechart_wasm:(Head :- Body)).
assert_local(:-Body) :- !,
    call(statechart_wasm:Body).
assert_local(Fact) :-
    functor(Fact, F, N),
    dynamic(statechart_wasm:F/N),
    track_datamodel_predicate(F/N),
    assertz(statechart_wasm:Fact).

%   Record the indicator of a predicate the <datamodel> contributes, so
%   clean/0 can abolish it on the next chart and the two charts stay
%   isolated.  Deduplicated.
track_datamodel_predicate(F/N) :-
    (   statechart_wasm:datamodel_predicate(F/N)
    ->  true
    ;   assertz(statechart_wasm:datamodel_predicate(F/N))
    ).


%!  gennum(-N) is det.
gennum(N) :-
    (   retract(statechart_wasm:num(N))
    ->  N1 is N+1,
        assertz(statechart_wasm:num(N1))
    ;   N = 0,
        assertz(statechart_wasm:num(1))
    ).
