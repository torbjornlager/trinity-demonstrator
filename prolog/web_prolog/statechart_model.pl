:- module(statechart_model, [
    statechart_actor_parse/1,
    statechart_actor_parse_text/1,
    statechart_spawn_source/3
]).

/** <module> Statechart Model Parsing

Parsing and model-building helpers for the statechart actor profile.
The generated model facts are asserted into `statechart_actor`.
*/

:- use_module(library(option)).
:- use_module(library(apply)).
:- use_module(library(sgml)).
:- use_module(source_utils, [
    uri_atom/2,
    open_source_uri/2
]).


%!  statechart_actor_parse(+Source) is det.
statechart_actor_parse(Source0) :-
    uri_atom(Source0, Source),
    setup_call_cleanup(
        open_source_uri(Source, Stream),
        load_xml_capturing_errors(Stream, ListOfContent),
        close(Stream)),
    model_generate(ListOfContent, null).


%!  statechart_actor_parse_text(+Text) is det.
statechart_actor_parse_text(Text) :-
    setup_call_cleanup(
        open_string(Text, Stream),
        load_xml_capturing_errors(Stream, ListOfContent),
        close(Stream)),
    model_generate(ListOfContent, null).


:- thread_local xml_parse_message/3.

%!  load_xml_capturing_errors(+Stream, -Content) is det.
%
%   Parse XML from Stream, intercepting SGML warnings and errors via
%   thread_message_hook so they do not escape to stderr.  If any
%   error-level messages were emitted, throw them as a structured
%   exception so that the caller (and ultimately the monitor/down
%   notification) receives a human-readable description.
load_xml_capturing_errors(Stream, Content) :-
    asserta((user:thread_message_hook(sgml(_Parser, _File, Line, Msg), Kind, _) :-
        (Kind == error ; Kind == warning),
        assertz(statechart_model:xml_parse_message(Kind, Line, Msg))), Ref),
    catch(
        load_structure(Stream, Content, [
            dialect(xml),
            space(remove)
        ]),
        Error,
        (   erase(Ref),
            retractall(xml_parse_message(_, _, _)),
            throw(Error)
        )
    ),
    erase(Ref),
    collect_xml_errors(Errors),
    retractall(xml_parse_message(_, _, _)),
    (   Errors == []
    ->  true
    ;   throw(error(xml_parse_error(Errors),
                    context(statechart_model:load_xml_capturing_errors/2,
                            Errors)))
    ).

collect_xml_errors(Errors) :-
    findall(Line-Msg,
            xml_parse_message(error, Line, Msg),
            Errors).


%!  statechart_spawn_source(+Options0, -SourceGoal, -SpawnOptions) is det.
statechart_spawn_source(Options0, SourceGoal, SpawnOptions) :-
    partition(is_statechart_trace_option, Options0, TraceOptions, Options1),
    partition(is_statechart_source_option, Options1, SourceOptions, SpawnOptions),
    (   member(Unsupported, SpawnOptions),
        unsupported_statechart_source_option(Unsupported)
    ->  throw(error(domain_error(statechart_source_option, Unsupported),
                    context(statechart_actor:statechart_spawn/2,
                            'unsupported source option for statechart_spawn/2')))
    ;   true
    ),
    (   SourceOptions = [SourceOption]
    ->  source_option_goal(SourceOption, Goal0)
    ;   SourceOptions == []
    ->  throw(error(existence_error(option, load_uri_or_load_text),
                    context(statechart_actor:statechart_spawn/2,
                            'statechart_spawn/2 requires one load_uri/1 or load_text/1 option')))
    ;   throw(error(domain_error(single_statechart_source_option, SourceOptions),
                    context(statechart_actor:statechart_spawn/2,
                            'statechart_spawn/2 accepts only one source option')))
    ),
    trace_option_goal(TraceOptions, Goal0, SourceGoal).


is_statechart_source_option(load_uri(_)).
is_statechart_source_option(load_text(_)).
is_statechart_trace_option(trace(_)).

unsupported_statechart_source_option(load_list(_)).
unsupported_statechart_source_option(load_predicates(_)).

source_option_goal(load_uri(URI), statechart_actor:interpret(URI)).
source_option_goal(load_text(Text), statechart_actor:interpret_text(Text)).

trace_option_goal([], Goal, Goal) :-
    !.
trace_option_goal([trace(Mode)], Goal, WrappedGoal) :-
    !,
    statechart_trace_mode(Mode, TraceMode),
    (   TraceMode == false
    ->  WrappedGoal = Goal
    ;   WrappedGoal = statechart_actor:with_trace(TraceMode, Goal)
    ).
trace_option_goal(TraceOptions, _Goal, _WrappedGoal) :-
    throw(error(domain_error(single_statechart_trace_option, TraceOptions),
                context(statechart_actor:statechart_spawn/2,
                        'statechart_spawn/2 accepts at most one trace/1 option'))).

statechart_trace_mode(true, logger) :-
    !.
statechart_trace_mode(false, false) :-
    !.
statechart_trace_mode(logger, logger) :-
    !.
statechart_trace_mode(Mode, _TraceMode) :-
    \+ memberchk(Mode, [true, false, logger]),
    throw(error(domain_error(statechart_trace_mode, Mode),
                context(statechart_actor:statechart_spawn/2,
                        'trace/1 must be true, false, or logger'))).


model_generate([], _).
model_generate([element(Name, Attrs, Children)|Rest], Parent) :-
    model_generate_node(Name, Attrs, Children, Parent, NewParent),
    !,
    model_generate(Children, NewParent),
    model_generate(Rest, Parent).
model_generate([_|Rest], Parent) :-
    model_generate(Rest, Parent).


model_generate_node(statechart, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs, statechart_actor),
    statechart_actor:gennum(N),
    model_assert(n(N, ID)),
    model_assert(state(ID, Parent)),
    (   option(initial(InitID), Attrs)
    ->  model_assert(initial(InitID))
    ;   true
    ).
model_generate_node(state, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    statechart_actor:gennum(N),
    model_assert(n(N, ID)),
    model_assert(state(ID, Parent)),
    (   option(initial(Initial), Attrs)
    ->  model_assert(transition(init(ID), '', true, [Initial], []))
    ;   true
    ).
model_generate_node(parallel, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    statechart_actor:gennum(N),
    model_assert(n(N, ID)),
    model_assert(parallel(ID, Parent)).
model_generate_node(spawn, Attrs, Children, Parent, _ID) :-
    select_option(type(Type), Attrs, Attrs1, toplevel),
    maplist(attr_to_option, Attrs1, Options),
    (   children_text(Children, Src)
    ->  load_text_terms(Src, Terms),
        Options1 = [load_list(Terms)|Options]
    ;   Options1 = Options
    ),
    model_assert(to_be_invoked(Parent, Type, Options1)).
model_generate_node(history, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    option(type(Type), Attrs, shallow),
    model_assert(history(ID, Parent, Type)).
model_generate_node(go, Attrs, Children, Parent, _ID) :-
    option(on(EventAtom), Attrs, ''),
    my_atom_to_term(EventAtom, Event, Bindings0),
    option(if(CondAtom), Attrs, true),
    my_atom_to_term(CondAtom, Cond, Bindings1),
    unify_bindings(Bindings0, Bindings1, Bindings2),
    (   option(to(Targets), Attrs)
    ->  atomic_list_concat(TargetList, ' ', Targets)
    ;   TargetList = []
    ),
    children_to_actions(Children, Actions, Bindings2),
    model_assert(transition(Parent, Event, Cond, TargetList, Actions)).
model_generate_node(final, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs),
    statechart_actor:gennum(N),
    model_assert(n(N, ID)),
    model_assert(final(ID, Parent)).
model_generate_node(initial, _Attrs, _Children, Parent, init(Parent)) :-
    model_assert(initial(init(Parent), Parent)).
model_generate_node(onentry, _Attrs, Children, Parent, _ID) :-
    children_to_actions(Children, Actions, []),
    model_assert(onentry(Parent, Actions)).
model_generate_node(onexit, _Attrs, Children, Parent, _ID) :-
    children_to_actions(Children, Actions, []),
    model_assert(onexit(Parent, Actions)).
model_generate_node(datamodel, _Attrs, Children, _Parent, _ID) :-
    (   children_text(Children, Text)
    ->  statechart_actor:load_datamodel(Text)
    ;   true
    ).


model_assert(Fact) :-
    assertz(statechart_actor:Fact).


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
    catch(my_atom_to_term_2(Atom, Term, Bindings),
          Error,
          ( print_message(error, Error),
            fail
          )).

my_atom_to_term_2('', '', []) :-
    !.
my_atom_to_term_2(Atom, Term, Bindings) :-
    atom_to_term(Atom, Term, Bindings).

attr_to_option(A=V, Term) :-
    functor(Term, A, 1),
    arg(1, Term, V).

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

load_text_terms(Text, Terms) :-
    open_string(Text, Stream),
    read_terms(Stream, Terms),
    close(Stream).

read_terms(Stream, Terms) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  Terms = []
    ;   Terms = [Term|Rest],
        read_terms(Stream, Rest)
    ).
