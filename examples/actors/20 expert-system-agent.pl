%% An expert-system agent and a simulation, following chapter 8.
%
% The expert asks with input/2; the shell plays the user and answers
% randomly. Proof search decides which question comes next.
%
% The book assumes a node-resident knowledge base. Here we ship the rules
% too, so the example runs without installing a separate service.

:- dynamic good_pet/1, bird/1, has_feathers/1, tweets/1,
           small/1, cuddly/1, yellow/1.

% Inference engine

prove(true) :- !.
prove((A, B)) :- !, prove(A), prove(B).
prove(A) :- clause(A, B), prove(B).
prove(A) :- askable(A, Q), input(Q, T), T == yes.

% Knowledge base

good_pet(X) :- bird(X), small(X).
good_pet(X) :- cuddly(X), yellow(X).

bird(X) :- has_feathers(X), tweets(X).

askable(tweets(_), 'Does it tweet?').
askable(small(_), 'Is it small?').
askable(cuddly(_), 'Is it cuddly?').
askable(has_feathers(_), 'Does it have feathers?').
askable(yellow(_), 'Is it yellow?').

% Expert system

expert_ask(Query, Pid, Options) :-
    append([session(false),
            src_predicates([prove/1, good_pet/1, bird/1, askable/2,
                            has_feathers/1, tweets/1, small/1,
                            cuddly/1, yellow/1])], Options, SpawnOptions),
    toplevel_spawn(Pid, SpawnOptions),
    toplevel_call(Pid, prove(Query), [
        limit(1), 
        once(true)
    ]).
    
% Simulation

simulation(Options) :-
    random_member(Name, [tweety,pingu]),
    format('A1: Is ~w a good pet?~n', [Name]),
    expert_ask(good_pet(Name), Pid, Options),
    interact(Pid, Name).
    
interact(Pid, Name) :-
    receive({
        failure(Pid) ->
            format('A2: No, ~w is not a good pet.~n', [Name]) ;
        success(Pid, _, false) ->
            format('A2: Yes, ~w is a good pet.~n', [Name]) ;
        error(Pid, Error) ->
            throw(Error) ;
        prompt(Pid, Question) ->
            format('A2: ~w~n', [Question]),
            random_member(Answer, [yes,no]),
            respond(Pid, Answer),
            format('A1: ~w~n', [Answer]),
            interact(Pid, Name)
    }).

/** <examples>

% Run again to see different answers and proof attempts.

?- simulation([]).

% Supply a private fact. If the expert needs yellow(tweety), it can
% establish it without asking. Pingu still has no known colour.

?- simulation([src_list([yellow(tweety)])]).

*/
