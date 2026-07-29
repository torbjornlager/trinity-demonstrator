%% Actor-substrate microbenchmarks corresponding to actor_benchmarks.pl.
-module(actor_benchmark).
-export([lifecycle_series/2, chain_series/2, pingpong_series/2,
         idle/0, chain_proc/2,
         ping_server/1, ping_rounds/2, pong_server/0]).

lifecycle_once(Actors) ->
    Start = erlang:monotonic_time(microsecond),
    [one_lifecycle() || _ <- lists:seq(1, Actors)],
    Stop = erlang:monotonic_time(microsecond),
    Stop - Start.

one_lifecycle() ->
    {Pid, Ref} = spawn_monitor(?MODULE, idle, []),
    Pid ! stop,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    end.

lifecycle_series(Actors, Repetitions) ->
    lifecycle_once(3),
    [lifecycle_once(Actors)
     || _ <- lists:seq(1, Repetitions)].

idle() ->
    receive stop -> ok end.

chain_once(Actors) ->
    Start = erlang:monotonic_time(microsecond),
    chain_start(Actors),
    Stop = erlang:monotonic_time(microsecond),
    Stop - Start.

chain_start(Actors) ->
    chain_proc(Actors, self()).

chain_proc(0, Root) ->
    Root ! ok;
chain_proc(N, Root) ->
    Child = spawn(?MODULE, chain_proc, [N-1, Root]),
    Child ! ok,
    receive ok -> ok end.

chain_series(Actors, Repetitions) ->
    chain_once(10),
    [chain_once(Actors)
     || _ <- lists:seq(1, Repetitions)].

pingpong_series(RoundTrips, Repetitions) ->
    {Pong, PongRef} = spawn_monitor(?MODULE, pong_server, []),
    {Ping, PingRef} =
        spawn_monitor(?MODULE, ping_server, [Pong]),
    ping_once(Ping, 100),
    Times = [ping_once(Ping, RoundTrips)
             || _ <- lists:seq(1, Repetitions)],
    Ping ! stop,
    Pong ! stop,
    receive
        {'DOWN', PingRef, process, Ping, normal} -> ok
    end,
    receive
        {'DOWN', PongRef, process, Pong, normal} -> ok
    end,
    Times.

ping_once(Ping, RoundTrips) ->
    Start = erlang:monotonic_time(microsecond),
    Ping ! {run, RoundTrips, self()},
    receive ping_done -> ok end,
    Stop = erlang:monotonic_time(microsecond),
    Stop - Start.

ping_server(Pong) ->
    receive
        {run, RoundTrips, From} ->
            ping_rounds(RoundTrips, Pong),
            From ! ping_done,
            ping_server(Pong);
        stop ->
            ok
    end.

ping_rounds(0, _Pong) ->
    ok;
ping_rounds(N, Pong) ->
    Pong ! {ping, self()},
    receive pong -> ok end,
    ping_rounds(N-1, Pong).

pong_server() ->
    receive
        {ping, Ping} ->
            Ping ! pong,
            pong_server();
        stop ->
            ok
    end.
