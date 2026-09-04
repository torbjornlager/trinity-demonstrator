%%  ring(+N, +Laps)
%
%   The classic process-ring benchmark: build a ring of N actor
%   processes and pass a token all the way around it Laps times.
%
%   Each worker knows only its successor's pid. It forwards a `token` to
%   that successor and loops; on `stop` it forwards the stop and halts.
%   The shell is the hub: it closes the ring (the last worker points back
%   at the shell), injects a token, waits for it to come back round -- one
%   lap -- and repeats, then sends `stop` around to tear the ring down.
%
%   It is a compact demonstration of wiring many actors together by pid
%   and routing a message through the topology they form.
%
%   A server node caps how many actors one client may hold at once
%   (max_ws_actors_per_principal), so a large N may be refused there with
%   "Too many active WebSocket actors". The browser-based SWI-WASM ACTOR
%   node runs every actor inside a single WASM instance, with no
%   WebSocket actors and no such per-client cap, so rings of any size run
%   there. As a safeguard, each run first clears any actors a previous
%   run may have left behind.
%
%	@author The Erlang process-ring benchmark, in Web Prolog.

%%  worker(+Next)
%
%   One node of the ring, forwarding to its successor Next.

worker(Next) :-
    receive({
        token ->
            Next ! token,
            worker(Next) ;
        stop ->
            Next ! stop
    }).

%%  build_ring(+N, +Last, -First)
%
%   Spawn N workers chained towards Last (the hub), and return First,
%   the pid of the worker the hub should hand the token to. Each spawned
%   worker carries its own source, since a public node does not let one
%   actor's predicates cross into another implicitly.

build_ring(0, Last, Last) :- !.
build_ring(N, Last, First) :-
    N > 0,
    spawn(worker(Last), Pid, [
        src_predicates([worker/1])
    ]),
    N1 is N - 1,
    build_ring(N1, Pid, First).

%%  clear_actors is det.
%
%   Terminate every actor visible from this session except the shell
%   itself, so repeated runs start from a clean slate.

clear_actors :-
    self(Self),
    actors(All),
    forall( ( member(Pid, All), Pid \== Self ),
            exit(Pid, cleared) ).

%%  ring(+N, +Laps)
%
%   Build the ring around this shell and drive Laps trips around it.

ring(N, Laps) :-
    clear_actors,
    self(Hub),
    build_ring(N, Hub, First),
    run_laps(First, 1, Laps).

run_laps(First, Lap, Laps) :-
    (   Lap =< Laps
    ->  First ! token,
        receive({ token -> true }),
        format("Lap ~w of ~w complete.~n", [Lap, Laps]),
        Lap1 is Lap + 1,
        run_laps(First, Lap1, Laps)
    ;   First ! stop,
        receive({ stop -> writeln('Ring shut down.') })
    ).


/** <examples>

?- time(ring(3, 5)).

?- time(ring(10, 2)).

*/
