%%  ping_pong is det.
%
%   Two actors bouncing a message back and forth. The count server and
%   the fridge had a single server talking to the shell; here two spawned
%   actors talk to EACH OTHER, which is the first genuinely concurrent
%   example in the set.
%
%   ping_pong/0 spawns a `pong` actor and then a `ping` actor, handing
%   ping the pong actor's pid so it knows where to send. ping sends
%   ping(Self) and waits for a `pong` reply; pong waits for a ping,
%   prints, and replies. They volley N times (N = 3 here); on the last
%   round ping sends `finished` instead, and both actors print a final
%   line and terminate. Each actor waits for messages in its own mailbox.
%   The received-message lines alternate because pong prints before
%   replying, and ping prints before sending the next ping.
%
%   Remote terminal writes follow the same request/reply principle as
%   Erlang's I/O protocol: the writer sends an I/O request and waits for
%   its corresponding reply before continuing. Here, the shared terminal
%   acknowledges acceptance of the output, preserving that order across
%   nodes, including when the terminal is hosted in SWI-WASM.
%   See https://www.erlang.org/doc/apps/stdlib/io_protocol.html
%
%   The two finishing lines may appear in either order: ping sends
%   `finished` before printing its own line. ping_pong/0 only spawns the
%   actors, so the shell may report true before their conversation ends.
%
%   pong/0 and ping/2 are spawned into separate private modules, so each
%   spawn ships exactly the clauses that actor runs via src_predicates.
%
%   Try adding node('https://n3.elfenbenstornet.se') to pong's spawn
%   options and/or node('https://n4.elfenbenstornet.se') to ping's.
%
%   With no node option, an actor runs on the current node. From SWI-WASM,
%   adding just one gives a browser/remote pair; adding both places the
%   actors on those two remote nodes.
%
%   Open the Logger and enable API traffic to inspect the spawn requests
%   and replies and verify which nodes host the actors.
%
%	@author https://www.erlang.org/doc/system/conc_prog.html


ping(0, Pong_Pid) :-
    Pong_Pid ! finished,
    format('Ping finished.~n').
ping(N, Pong_Pid) :-
    self(Self),
    Pong_Pid ! ping(Self),
    receive({
        pong ->
            format('Ping received pong.~n')
    }),
    N1 is N - 1,
    ping(N1, Pong_Pid).

pong :-
    receive({
        finished ->
            format('Pong finished.~n') ;
        ping(Ping_Pid) ->
            format('Pong received ping.~n'),
            Ping_Pid ! pong,
            pong
    }).

ping_pong :-
    spawn(pong, Pong_Pid, [
        src_predicates([pong/0])
    ]),
    spawn(ping(3, Pong_Pid), _, [
        src_predicates([ping/2])
    ]).


/** <examples>

% Watch the two actors volley: "Pong received ping" / "Ping received
% pong" alternates three times, then both print their finishing line.

?- ping_pong.

*/
