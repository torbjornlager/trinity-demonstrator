%%  count_server(+Count)
%
%   A server actor that maintains a counter, 
%   responding to count/1 and stop messages.
%
%	@param	Count - current counter value
%	@author

count_server(Count0) :-
    receive({
        count(From) ->
            Count is Count0 + 1,
            From ! count(Count),
            count_server(Count) ;
        stop ->
            true
    }).


/** <examples>

?- spawn(count_server(0), Pid).
    
?- self(Me), $Pid ! count(Me), 
   receive({count(N) -> true}).
    
?- $Pid ! stop.

*/
