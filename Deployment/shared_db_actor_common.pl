% Shared database loaded by all ACTOR-profile deployment nodes (n3, n4).
% Holds the actor predicates that the tutorial expects to find on either
% public actor node, plus the public service directory.

service(counter, meta(actor, protocol(count_v1))).
service(pubsub_service, meta(actor, protocol(pubsub_v1))).


echo_actor :-
    receive({
        echo(From, Msg) ->
            From ! echo(Msg),
            echo_actor
    }).


count_actor(Count0) :-
    receive({
        count(From) ->
            Count is Count0 + 1,
            From ! count(Count),
            count_actor(Count) ;
        stop ->
            true
    }).



% Native ping-pong benchmark.  The worker predicates live in this shared
% database, so the spawned actors can call them directly: no src_* source
% transfer or private source installation is part of the measurement.

ping_pong :-
    ping_pong(1000).

ping_pong(RoundTrips) :-
    must_be(nonneg, RoundTrips),
    self(MasterPid),
    spawn(pong(MasterPid), PongPid),
    spawn(ping(RoundTrips, PongPid)),
    receive({finished -> true}).

ping_pong_benchmark(RoundTrips, Microseconds) :-
    get_time(T0),
    ping_pong(RoundTrips),
    get_time(T1),
    Microseconds is round((T1-T0) * 1_000_000).

ping(0, PongPid) :-
    PongPid ! finished.
ping(N, PongPid) :-
    self(Self),
    PongPid ! ping(Self),
    receive({pong -> true}),
    N1 is N - 1,
    ping(N1, PongPid).

pong(MasterPid) :-
    receive({
        finished ->
            MasterPid ! finished ;
        ping(PingPid) ->
            PingPid ! pong,
            pong(MasterPid)
    }).


authorized(alice). 
owns(alice, printer2). 
online(printer2).
