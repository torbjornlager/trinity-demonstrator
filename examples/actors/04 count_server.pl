%%  count_server(+Count)
%
%   The simplest stateful server: an actor that keeps a running count.
%   This is the archetype for programming with actors in Web Prolog, so
%   it is worth reading closely.
%
%   An actor is a process with a private mailbox and no shared memory; it
%   changes the world only by sending and receiving messages. This one
%   loops on receive/1. A `count(From)` message increments the counter,
%   sends the new value back to the actor named by From, and loops with
%   the updated count; a `stop` message ends the loop, terminating the
%   actor. Notice where the state lives: not in a global variable, but in
%   the predicate's ARGUMENT, carried forward on each recursive call.
%   That is how a purely logical, assignment-free language holds mutable
%   state over time.
%
%   The client half of the protocol -- sending count/1 and waiting for
%   the reply -- is written out by hand in the examples below; the fridge
%   and fridge_server examples show how to hide it behind predicates.
%
%	@param	Count - the current value of the counter.
%	@author A count server, in Web Prolog.

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

% Spawn the server with the counter starting at 0. src_predicates ships
% its clause into the new actor's private module; a public node does not
% share the shell's predicates with a spawned actor implicitly.

?- spawn(count_server(0), Pid, [
       src_predicates([count_server/1])
   ]).

% Act as a client: send count/1 with our own pid as the return address,
% then block in receive/1 until the reply arrives. Run it again to watch
% the count climb -- the state persists in the running actor.

?- self(Me), $Pid ! count(Me),
   receive({count(N) -> true}).

% Shut the server down.

?- $Pid ! stop.

*/
