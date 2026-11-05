:- module(iso_dcg, [iso_phrase/2, iso_phrase/3]).

:- meta_predicate iso_phrase(:, ?), iso_phrase(:, ?, ?).

% Logical expansion described by Ulrich Neumerkel's dcgs_exp.pl.
% https://www.complang.tuwien.ac.at/ulrich/iso-prolog/dcgs/dcgs_exp.pl
% The draft's optional input and remainder type checks are omitted.
iso_phrase(Body, Input) :-
    iso_phrase(Body, Input, []).

iso_phrase(Qualified, Input, Rest) :-
    strip_module(Qualified, Module, Body),
    run_body(Body, Module, Input, Rest).

run_body(Body, Module, Input, Rest) :-
    (   var(Body)
    ->  throw(error(instantiation_error, _))
    ;   expand_body(Body, Module, Input, Rest, Goal),
        call(Module:Goal)
    ).

expand_body(Body, Module, Input, Rest, Goal) :-
    (   var(Body)
    ->  Goal = iso_dcg:run_body(Body, Module, Input, Rest)
    ;   expand_nonvar(Body, Module, Input, Rest, Goal)
    ).

expand_nonvar([], _, Input, Rest, Input = Rest) :- !.
expand_nonvar([Head|Tail], _, Input, Rest, Input = List) :-
    !,
    (   is_list([Head|Tail])
    ->  append([Head|Tail], Rest, List)
    ;   '$skip_list'(_, [Head|Tail], End),
        (   var(End)
        ->  throw(error(instantiation_error, _))
        ;   throw(error(type_error(list, [Head|Tail]), _))
        )
    ).
expand_nonvar((A, B), Module, Input, Rest, (First, Second)) :-
    !,
    expand_body(A, Module, Input, Middle, First),
    expand_body(B, Module, Middle, Rest, Second).
expand_nonvar((A ; B), Module, Input, Rest, (First ; Second)) :-
    !,
    (   nonvar(A), A = (If -> Then)
    ->  expand_if(If, Then, Module, Input, Rest, First)
    ;   expand_body(A, Module, Input, Rest, First)
    ),
    expand_body(B, Module, Input, Rest, Second).
expand_nonvar('|'(A, B), Module, Input, Rest, Goal) :-
    !,
    expand_nonvar((A ; B), Module, Input, Rest, Goal).
expand_nonvar((If -> Then), Module, Input, Rest, Goal) :-
    !,
    expand_if(If, Then, Module, Input, Rest, Goal).
expand_nonvar({Goal}, _, Input, Rest, (Goal, Input = Rest)) :- !.
expand_nonvar(!, _, Input, Rest, (!, Input = Rest)) :- !.
expand_nonvar(phrase(Body), Module, Input, Rest,
              iso_dcg:run_body(Body, Module, Input, Rest)) :- !.
expand_nonvar(call(Closure), _, Input, Rest, call(Closure, Input, Rest)) :- !.
expand_nonvar(\+ Body, Module, Input, Rest,
              (\+ iso_dcg:run_body(Body, Module, Input, _), Input = Rest)) :- !.
expand_nonvar(Body, _, Input, Rest, Goal) :-
    (   callable(Body)
    ->  Body =.. [Name|Args],
        append([Name|Args], [Input, Rest], Expanded),
        Goal =.. Expanded
    ;   throw(error(type_error(callable, Body), _))
    ).

expand_if(If, Then, Module, Input, Rest, (Condition -> Consequent)) :-
    expand_body(If, Module, Input, Middle, Condition),
    expand_body(Then, Module, Middle, Rest, Consequent).
