%%  count_actor(+Count)
%
%   A server actor that maintains a counter, 
%   responding to count/1 and stop messages.
%
%	@param	Count - current counter value
%	@author

count_actor(Count0) :-
    receive({
        count(From) ->
            Count is Count0 + 1,
            From ! count(Count),
            count_actor(Count) ;
        stop ->
            true
    }).


/** <examples>

?- spawn(count_actor(0), Pid, [
       load_predicates([count_actor/1])
   ]).
    
?- self(Me), $Pid ! count(Me), 
   receive({count(N) -> true}).
    
?- $Pid ! stop.

*/
