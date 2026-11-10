:- module(web_prolog_library).
:- lib(json).
:- lib(prolog_extras).

:- export memberchk/2, nth0/3, nth0/4, nth1/3, nth1/4, between/3, succ/2.
:- export maplist/2, maplist/3, maplist/4, maplist/5, maplist/6, maplist/7, maplist/8.
:- export foldl/4, foldl/5, foldl/6, call_nth/2, countall/2.
:- export runtime_property/1, get_time/1.
:- export node_setting/2.
:- export ('=@=')/2.
:- local store(node_settings).

:- tool(maplist/2, maplist_/3).
:- tool(maplist/3, maplist_/4).
:- tool(maplist/4, maplist_/5).
:- tool(maplist/5, maplist_/6).
:- tool(maplist/6, maplist_/7).
:- tool(maplist/7, maplist_/8).
:- tool(maplist/8, maplist_/9).
:- tool(foldl/4, foldl_/5).
:- tool(foldl/5, foldl_/6).
:- tool(foldl/6, foldl_/7).
:- tool(call_nth/2, call_nth_/3).
:- tool(countall/2, countall_/3).

% The adapter supplies only public settings when it starts this engine.
load_node_settings :-
    ( getenv('TRINITY_N7_PUBLIC_SETTINGS', Text) ->
        setup_call_cleanup(open(string(Text), read, Stream),
            json_read(Stream, {Fields}, [names_as_atoms]), close(Stream)),
        findall(Key:Value, (member(Key:Raw, Fields), setting_value(Raw, Value)), Settings),
        store_set(node_settings, public, Settings)
    ; true ).

node_setting(Key, Value) :-
    store_get(node_settings, public, Settings),
    ( nonvar(Key) -> memberchk(Key:Value, Settings)
    ; member(Key:Value, Settings) ).

setting_value(Text, Value) :- string(Text), !, atom_string(Value, Text).
setting_value([], []) :- !.
setting_value([Raw|Rest], [Value|Values]) :- !,
    setting_value(Raw, Value),
    setting_value(Rest, Values).
setting_value(Value, Value).

:- load_node_settings.

% Capabilities of the native host, shared across Web Prolog profiles.
runtime_property(persistent(true)).
runtime_property(inbound_addressable(true)).
runtime_property(dom(false)).
runtime_property(actor_isolation(independent)).
runtime_property(hard_termination(true)).

get_time(Seconds) :- statistics(hr_time, Seconds).

% SWI's variant comparison uses the same variable-sharing test as variant/2.
'=@='(Left, Right) :- variant(Left, Right).

% A first match commits before inspecting the rest of the list.
memberchk(Element, List) :-
    ( var(List) -> List = [Element|_]
    ; List = [Head|Tail] ->
        ( Element = Head -> true ; memberchk(Element, Tail) )
    ; List == [] -> fail
    ; throw(error(type_error(list, List), memberchk/2))
    ).

succ(Predecessor, Successor) :-
    ( nonvar(Predecessor) ->
        require_natural(Predecessor),
        Next is Predecessor + 1,
        Successor = Next
    ; require_natural(Successor),
      Successor > 0,
      Predecessor is Successor - 1
    ).

require_natural(Value) :-
    require_integer(Value, succ/2),
    ( Value >= 0 -> true
    ; throw(error(domain_error(not_less_than_zero, Value), succ/2))
    ).

nth0(Index, List, Element) :- nth(0, Index, List, Element, nth0/3).
nth1(Index, List, Element) :- nth(1, Index, List, Element, nth1/3).

nth(Base, Index, List, Element, Context) :-
    ( var(Index) ->
        nth_position(Base, Index, List, Element)
    ; require_integer(Index, Context),
      Offset is Index - Base,
      Offset >= 0,
      nth_at(Offset, List, Element)
    ).

nth_position(I, I, [Head|_], Head).
nth_position(I, Index, [_|Tail], Element) :-
    Next is I + 1,
    nth_position(Next, Index, Tail, Element).

nth_at(0, [Head|_], Head) :- !.
nth_at(Offset, [_|Tail], Element) :-
    Offset > 0,
    Next is Offset - 1,
    nth_at(Next, Tail, Element).

nth0(Index, List, Element, Rest) :- nth_rest(0, Index, List, Element, Rest, nth0/4).
nth1(Index, List, Element, Rest) :- nth_rest(1, Index, List, Element, Rest, nth1/4).

nth_rest(Base, Index, List, Element, Rest, Context) :-
    ( var(Index) ->
        nth_rest_position(Base, Index, List, Element, Rest)
    ; require_integer(Index, Context),
      Offset is Index - Base,
      Offset >= 0,
      nth_rest_at(Offset, List, Element, Rest)
    ).

nth_rest_position(I, I, [Head|Tail], Head, Tail).
nth_rest_position(I, Index, [Head|Tail], Element, [Head|Rest]) :-
    Next is I + 1,
    nth_rest_position(Next, Index, Tail, Element, Rest).

nth_rest_at(0, [Head|Tail], Head, Tail) :- !.
nth_rest_at(Offset, [Head|Tail], Element, [Head|Rest]) :-
    Offset > 0,
    Next is Offset - 1,
    nth_rest_at(Next, Tail, Element, Rest).

between(Low, High, Value) :-
    require_integer(Low, between/3),
    require_integer(High, between/3),
    ( var(Value) ->
        Low =< High,
        range_value(Low, High, Value)
    ; require_integer(Value, between/3),
      Low =< Value, Value =< High
    ).

range_value(Low, High, Value) :-
    ( Low == High -> Value = Low
    ; ( Value = Low
      ; Next is Low + 1, range_value(Next, High, Value) )
    ).

maplist_(Goal, L1, Module) :- map_lists(Goal, [L1], Module).
maplist_(Goal, L1, L2, Module) :- map_lists(Goal, [L1,L2], Module).
maplist_(Goal, L1, L2, L3, Module) :- map_lists(Goal, [L1,L2,L3], Module).
maplist_(Goal, L1, L2, L3, L4, Module) :- map_lists(Goal, [L1,L2,L3,L4], Module).
maplist_(Goal, L1, L2, L3, L4, L5, Module) :- map_lists(Goal, [L1,L2,L3,L4,L5], Module).
maplist_(Goal, L1, L2, L3, L4, L5, L6, Module) :- map_lists(Goal, [L1,L2,L3,L4,L5,L6], Module).
maplist_(Goal, L1, L2, L3, L4, L5, L6, L7, Module) :- map_lists(Goal, [L1,L2,L3,L4,L5,L6,L7], Module).

map_lists(Closure, Lists, Module) :-
    list_columns(Lists, Heads, Tails),
    ( Heads == [] -> true
    ; invoke_closure(Closure, Heads, Module),
      map_lists(Closure, Tails, Module)
    ).

foldl_(Goal, L1, Initial, Final, Module) :-
    fold_lists(Goal, [L1], Initial, Final, Module).
foldl_(Goal, L1, L2, Initial, Final, Module) :-
    fold_lists(Goal, [L1,L2], Initial, Final, Module).
foldl_(Goal, L1, L2, L3, Initial, Final, Module) :-
    fold_lists(Goal, [L1,L2,L3], Initial, Final, Module).

fold_lists(Closure, Lists, Initial, Final, Module) :-
    list_columns(Lists, Heads, Tails),
    ( Heads == [] -> Final = Initial
    ; append(Heads, [Initial, Next], Arguments),
      invoke_closure(Closure, Arguments, Module),
      fold_lists(Closure, Tails, Next, Final, Module)
    ).

% Any known list fixes the shape of this column. Only offer both shapes
% when every list is still a variable, preserving list generation.
list_columns(Lists, Heads, Tails) :-
    known_shape(Lists, Shape),
    ( Shape == empty ->
        all_empty(Lists), Heads = [], Tails = []
    ; Shape == nonempty ->
        list_step(Lists, Heads, Tails)
    ; ( all_empty(Lists), Heads = [], Tails = []
      ; list_step(Lists, Heads, Tails) )
    ).

known_shape([], open).
known_shape([List|Lists], Shape) :-
    ( var(List) -> known_shape(Lists, Shape)
    ; List == [] -> Shape = empty
    ; Shape = nonempty
    ).

all_empty([]).
all_empty([[]|Lists]) :- all_empty(Lists).

list_step([], [], []).
list_step([[Head|Tail]|Lists], [Head|Heads], [Tail|Tails]) :-
    list_step(Lists, Heads, Tails).

% ECLiPSe tools supply the caller's module separately. Build the extended
% goal without binding the closure, then invoke it in that module.
invoke_closure(Closure, Arguments, Caller) :-
    callable_in(Closure, Caller, Plain, Module),
    Plain =.. Parts,
    append(Parts, Arguments, Extended),
    Goal =.. Extended,
    call(Goal)@Module.

call_nth_(Goal, Index, Caller) :-
    ( var(Index) ->
        callable_in(Goal, Caller, Plain, Module),
        shelf_create(counter(0), Counter),
        numbered_solution(Plain, Module, Counter, Index)
    ; require_integer(Index, call_nth/2),
      ( Index > 0 -> true
      ; throw(error(domain_error(not_less_than_one, Index), call_nth/2))
      ),
      callable_in(Goal, Caller, Plain, Module),
      shelf_create(counter(0), Counter),
      once(numbered_solution(Plain, Module, Counter, Index))
    ).

numbered_solution(Goal, Module, Counter, Index) :-
    call(Goal)@Module,
    shelf_inc_and_get(Counter, 1, Number),
    Index = Number.

% Each call owns its counter. Backtracking over the generator undoes its
% bindings while preserving the count, including for nested countall calls.
countall_(Goal, Count, Caller) :-
    callable_in(Goal, Caller, Plain, Module),
    shelf_create(counter(0), Counter),
    ( call(Plain)@Module,
      shelf_inc(Counter, 1),
      fail
    ; shelf_get(Counter, 1, Count)
    ).

callable_in(Goal, Caller, Plain, Module) :-
    ( nonvar(Goal), Goal = Qualified:Inner, atom(Qualified) ->
        callable_in(Inner, Qualified, Plain, Module)
    ; require_callable(Goal),
      Plain = Goal,
      Module = Caller
    ).

require_callable(Goal) :-
    ( var(Goal) -> throw(error(instantiation_error, call/1))
    ; ( atom(Goal) ; compound(Goal), Goal \= [_|_] ) -> true
    ; throw(error(type_error(callable, Goal), call/1))
    ).

require_integer(Value, Context) :-
    ( integer(Value) -> true
    ; var(Value) -> throw(error(instantiation_error, Context))
    ; throw(error(type_error(integer, Value), Context))
    ).
