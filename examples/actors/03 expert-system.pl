%%  prove(+Goal) is semidet.
%
%   A tiny backward-chaining expert system, built as a meta-interpreter:
%   a Prolog program that interprets Prolog. prove/1 solves a goal much
%   as Prolog itself would -- true succeeds, a conjunction is solved
%   left to right, and a goal that matches a rule head is replaced by
%   that rule's body -- but with one extra clause that makes it an
%   interactive expert system.
%
%   That last clause fires when a goal is `askable`: instead of proving
%   it from the knowledge base, it puts the corresponding question to the
%   user and treats the answer as the truth value. So the rules for
%   good_pet/1 (a small bird, or something cuddly and yellow) become a
%   dialogue -- the user supplies the leaf facts the program cannot
%   derive on its own.
%
%   Reading answers with read/1 makes this an interactive example: it
%   needs a node that supports terminal input (an ISOTOPE profile).
%
%	@param	Goal - the goal to establish, by rules or by asking.
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

% Is tweety a good pet? The system asks what it cannot derive; answer
% each question with `yes.` or `no.` and it reasons to a conclusion.
% (Try: does it have feathers? yes; does it tweet? yes; is it small? yes.)

?- prove(good_pet(tweety)).

*/