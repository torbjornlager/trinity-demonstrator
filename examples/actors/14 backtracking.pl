%%  Getting answers through backtracking.
%
%   Prolog's backtracking -- normally an internal mechanism the
%   programmer cannot pause -- placed under EXTERNAL, message-driven
%   control. A spawned goal enumerates the solutions to human(Who), but
%   instead of collecting them all at once it sends the FIRST solution
%   back to its parent and then blocks in receive. It produces the next
%   solution only when told to, by a `next` message, and stops on `stop`.
%
%   The mechanism turns on two facts established elsewhere in the book.
%   The `next` clause has body `fail`, so receiving `next` makes the
%   receive fail, and that failure propagates backwards into human(Who),
%   forcing it to backtrack and yield its next solution. And !/2 is an
%   effect that backtracking does NOT undo: each answer already sent
%   stays in the parent's mailbox, so backtracking through the solution
%   set leaves behind a trail of delivered answers, one per `next`.
%
%   This is something Erlang cannot do -- it has no backtracking to
%   expose -- and it is the seed of the Prolog Web's toplevel behaviour.
%   See "15 simple_toplevel.pl" for the next step: wrapping this kernel
%   in a reusable protocol.
%
%	@author Adapted from an example in the Web Prolog book.

human(socrates).
human(plato).
human(aristotle).


/** <examples>

% Spawn the enumerator. It sends socrates straightaway, then blocks.

?- self(Self),
   spawn(( human(Who),
           Self ! Who,
           receive({
               next -> fail ;
               stop -> true
           })
         ), Pid, [
       src_predicates([human/1])
   ]).

?- flush.

% Each `next` drives one step of backtracking: the receive fails, human/1
% backtracks to its next solution, and that solution is sent on.

?- $Pid ! next.

?- flush.

?- $Pid ! next.

?- flush.

% `stop` lets the goal succeed and the actor terminate normally.

?- $Pid ! stop.

*/
