%%  prove(+Goal)
%
%   A meta-interpreter that asks the user yes/no questions for askable goals.
%
%	@param	Goal - the goal to prove
%	@author Torbjörn Lager

:- dynamic tweets/1, has_feathers/1,
           cuddly/1, small/1, yellow/1.

prove(true) :- !.
prove((B, Bs)) :- !,
    prove(B),
    prove(Bs).
prove(H) :-
    clause(H, B),
    prove(B).
prove(A) :-
    askable(A, Q),
    writeln(Q),
    read(Answer),
    Answer == yes.

good_pet(X) :- bird(X), small(X).
good_pet(X) :- cuddly(X), yellow(X).

bird(X) :- has_feathers(X), tweets(X).

askable(tweets(_), 'Does it tweet?').
askable(small(_), 'Is it small?').
askable(cuddly(_), 'Is it cuddly?').
askable(has_feathers(_), 'Does it have feathers?').
askable(yellow(_), 'Is it yellow?').


/** <examples>

?- prove(good_pet(tweety)).

*/