%%  alarm/0
%
%   A cancellable alarm clock, built from delayed sending. The actor
%   prints a line each time it receives `ring`, and stops on `stop`.
%
%   send/3 can schedule a message for later delivery with the delay/1
%   option, and tag it with id/1 so it can be withdrawn with cancel/1
%   before it fires. Cancellation is scoped to the calling actor: two
%   actors may reuse the same id without interfering. If cancel/1 comes
%   too late, the message has already been delivered and the alarm rings.
%
%	@author Adapted from an example in the Web Prolog book.

alarm :-
    receive({
        ring ->
            writeln('Alarm ringing!'),
            alarm ;
        stop ->
            true
    }).


/** <examples>

% Spawn the alarm, then schedule a ring 5 seconds from now, tagged
% alarm1:

?- spawn(alarm, Pid, [
       src_predicates([alarm/0])
   ]),
   send(Pid, ring, [
       delay(5),
       id(alarm1)
   ]).

% Change our mind within those 5 seconds and withdraw the ring -- the
% alarm never sounds:

?- cancel(alarm1).

% Schedule another ring, this time letting it elapse: after 2 seconds
% 'Alarm ringing!' is printed by the alarm actor.

?- send($Pid, ring, [
       delay(2)
   ]).

?- $Pid ! stop.

*/
