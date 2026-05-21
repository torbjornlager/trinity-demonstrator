%%  important(+Messages)
%
%   Collects all high-priority messages (Priority > 10) from the mailbox first,
%   then hands off to normal/1 for the remaining messages.
%
%	@param	Messages - list of collected messages, high-priority first
%	@author Adapted from an example in an Erlang textbook by Fred Hebert.

important(Messages) :-
    receive({
        Priority-Message if Priority > 10 ->
            Messages = [Message|MoreMessages],
            important(MoreMessages)
    },[
        timeout(0),
        on_timeout(normal(Messages))
    ]).

normal(Messages) :-
    receive({
        _-Message ->
            Messages = [Message|MoreMessages],
            normal(MoreMessages)
    },[
        timeout(0),
        on_timeout(Messages = [])
    ]).


/** <examples>

?- self(S), S ! 15-high, S ! 7-low, S ! 1-low, S ! 17-high.

?- important(Messages).

*/
