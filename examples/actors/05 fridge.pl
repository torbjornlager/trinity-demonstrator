%%  fridge(+FoodList)
%
%   A server actor modelling a fridge, and -- more importantly -- an
%   example of hiding a message protocol behind an ordinary predicate
%   API. It builds on the count server by adding a real request/response
%   protocol with more than one operation.
%
%   The fridge holds a list of food items in its argument, the same
%   state-in-an-argument technique the count server uses. It understands
%   three messages: store(From, Food) adds an item and acknowledges;
%   take(From, Food) removes an item if present, replying ok(Food) or
%   not_found; terminate ends the actor. Each reply is tagged with the
%   server's own pid (Self-Answer) so a client can tell whose answer it
%   is receiving.
%
%   A client should not have to know those message shapes. store/3 and
%   take/3 wrap the send-then-receive handshake into a single synchronous
%   call: send the request, then block for the matching reply. This is
%   the standard way to turn an asynchronous actor into a synchronous,
%   predicate-shaped service, and the fridge_server example generalises
%   it into a reusable behaviour.
%
%	@param	FoodList - the items currently in the fridge.
%	@author Adapted from an example in an Erlang textbook by Fred Hebert.

fridge(FoodList0) :-
    receive({
        store(From, Food) ->
            self(Self),
            From ! Self-ok,
            fridge([Food|FoodList0]);
        take(From, Food) ->
            self(Self),
            (   select(Food, FoodList0, FoodList)
            ->  From ! Self-ok(Food),
                fridge(FoodList)
            ;   From ! Self-not_found,
                fridge(FoodList0)
            );
        terminate ->
            true
    }).

store(Pid, Food, Response) :-
    self(Self),
    Pid ! store(Self, Food),
    receive({
        Pid-Response -> true
    }).

take(Pid, Food, Response) :-
    self(Self),
    Pid ! take(Self, Food),
    receive({
        Pid-Response -> true
    }).


/** <examples>

% Spawn an empty fridge. Only fridge/1 needs to travel to the actor; the
% client predicates store/3 and take/3 run here in the shell.

?- spawn(fridge([]), Pid, [
       src_predicates([fridge/1])
   ]).

% Store two items. Each call sends store/3 and waits for the ok reply, so
% the interaction reads like an ordinary predicate call.

?- store($Pid, milk, R1).
?- store($Pid, meat, R1).

% Take milk (present -> ok(milk)); take meat, then take meat again to see
% the not_found reply once it is gone.

?- take($Pid, milk, R2).
?- take($Pid, meat, R2).

?- $Pid ! terminate.

*/
