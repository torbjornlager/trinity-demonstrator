%%  fridge(+FoodList)
%
%   A server actor modelling a fridge. Responds to store/3 and take/3 messages.
%
%	@param	FoodList - list of food items currently in the fridge
%	@author Adapted from an example in an Erlang textbook by Fred Hebert

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

?- spawn(fridge([]), Pid, [
       load_predicates([fridge/1])
   ]).
    
?- store($Pid, milk, R1). 
?- store($Pid, meat, R1). 

?- take($Pid, milk, R2).
?- take($Pid, meat, R2).
    
?- $Pid ! terminate.

*/
