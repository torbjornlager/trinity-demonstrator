:- module(statechart_wasm_model, [
    statechart_wasm_parse_text/1,
    statechart_wasm_parse_stream/1
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
:- use_module(library(sgml)).

%   Web-Prolog operators used inside <spawn> bodies and <go>/<onentry>
%   scripts (e.g. `Pid ! pong`, `Id@Node`, library(wasm)'s `:=`/`#`).
%   read_term/3 and atom_to_term/3 below need these visible at parse
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


:- thread_local xml_parse_message/3.

load_xml_capturing_errors(Stream, Content) :-
    asserta((user:thread_message_hook(sgml(_Parser, _File, Line, Msg), Kind, _) :-
        (Kind == error ; Kind == warning),
        assertz(statechart_wasm_model:xml_parse_message(Kind, Line, Msg))), Ref),
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
                    context(statechart_wasm_model:load_xml_capturing_errors/2,
                            Errors)))
    ).

collect_xml_errors(Errors) :-
    findall(Line-Msg,
            xml_parse_message(error, Line, Msg),
            Errors).


model_generate([], _).
model_generate([element(Name, Attrs, Children)|Rest], Parent) :-
    model_generate_node(Name, Attrs, Children, Parent, NewParent),
    !,
    model_generate(Children, NewParent),
    model_generate(Rest, Parent).
model_generate([_|Rest], Parent) :-
    model_generate(Rest, Parent).


model_generate_node(statechart, Attrs, _Children, Parent, ID) :-
    option(id(ID), Attrs, statechart_wasm),
    gennum(N),
    model_assert(n(N, ID)),
    model_assert(state(ID, Parent)),
    (   option(initial(InitID), Attrs)
    ->  model_assert(initial(InitID))
    ;   true
    ).
model_generate_node(state, Attrs, _Children, Parent, ID) :-
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
    gennum(N),
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
    ->  load_datamodel(Text)
    ;   true
    ).


model_assert(Fact) :-
    assertz(statechart_wasm:Fact).


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
    setup_call_cleanup(
        open_string(Text, Stream),
        read_terms(Stream, Terms),
        close(Stream)).

read_terms(Stream, Terms) :-
    read_term(Stream, Term, []),
    (   Term == end_of_file
    ->  Terms = []
    ;   Terms = [Term|Rest],
        read_terms(Stream, Rest)
    ).


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
