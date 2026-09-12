%%  important(-Messages)
%
%   A priority queue that drains a mailbox high-priority messages first,
%   regardless of the order in which they arrived. It ties together three
%   features of receive/2: guards, timeouts, and message deferral.
%
%   important/1 accepts only messages whose priority exceeds 10, because
%   its single clause carries the guard `if Priority > 10`. Any lower
%   priority message in the mailbox matches no clause and is DEFERRED --
%   left in place for later. timeout(0) means "do not wait for new
%   messages": once no matching (high-priority) message remains, the
%   receive times out at once and on_timeout hands control to normal/1,
%   which then collects everything still deferred, in arrival order. The
%   result is a single list with the urgent messages pulled to the front.
%
%   The example depends squarely on deferral: without it, the first
%   receive could not skip past low-priority messages to reach the
%   high-priority ones behind them.
%
%	@param	Messages - the collected messages, high-priority ones first.
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

% Send four messages to our own mailbox, interleaving priorities.

?- self(S), S ! 15-high, S ! 7-low, S ! 1-low, S ! 17-high.

% Drain them: the two high-priority messages come out first (in arrival
% order), then the low-priority ones -- Messages = [high, high, low, low].

?- important(Messages).

*/
