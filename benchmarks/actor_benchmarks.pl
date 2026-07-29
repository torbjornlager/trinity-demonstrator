/** <module> Actor-substrate microbenchmarks

This source is shared by the native and SWI-WASM benchmark runs described in
the benchmarking appendix of the Prolog Trinity book.  Times are elapsed wall
times in microseconds.

The lifecycle benchmark starts and stops one actor at a time.  The ping-pong
benchmark creates one actor pair, warms it up, and then times repeated batches
over the same pair so that actor startup is outside the timed interval.

For the stand-alone native actor core, load `actors.pl` before consulting this
file.  For the full native node, load `load.pl` first.  In the browser node,
paste the required predicates into the demonstrator editor.
*/

%!  benchmark_lifecycle(+Actors, -Microseconds) is det.

benchmark_lifecycle(Actors, Microseconds) :-
    benchmark_lifecycle(precompiled_io, Actors, Microseconds).

benchmark_lifecycle(Mode, Actors, Microseconds) :-
    get_time(T0),
    forall(between(1, Actors, _), benchmark_one_lifecycle(Mode)),
    get_time(T1),
    Microseconds is round((T1-T0)*1_000_000).

benchmark_one_lifecycle :-
    benchmark_one_lifecycle(precompiled_io).

benchmark_one_lifecycle(Mode) :-
    benchmark_lifecycle_io_options(Mode, IOOptions),
    spawn(benchmark_idle, Pid, [
        link(false),
        monitor(true),
        src_predicates([benchmark_idle/0])
      | IOOptions
    ]),
    Pid ! stop,
    receive({down(Pid, _, true) -> true}).

benchmark_lifecycle_io_options(precompiled_io, []).
benchmark_lifecycle_io_options(generated, [isolation_io(generated)]).

benchmark_idle :-
    receive({stop -> true}).


%!  benchmark_pingpong_series(+RoundTrips, +Repetitions, -Times) is det.

benchmark_pingpong_series(RoundTrips, Repetitions, Times) :-
    spawn(benchmark_pong_server, Pong, [
        link(false),
        monitor(true),
        src_predicates([benchmark_pong_server/0])
    ]),
    spawn(benchmark_ping_server(Pong), Ping, [
        link(false),
        monitor(true),
        src_predicates([
            benchmark_ping_server/1,
            benchmark_ping_rounds/2
        ])
    ]),
    benchmark_ping_once(Ping, 100, _),
    findall(Microseconds,
            ( between(1, Repetitions, _),
              benchmark_ping_once(Ping, RoundTrips, Microseconds)
            ),
            Times),
    Ping ! stop,
    Pong ! stop,
    receive({down(Ping, _, true) -> true}),
    receive({down(Pong, _, true) -> true}).

benchmark_ping_once(Ping, RoundTrips, Microseconds) :-
    self(Self),
    get_time(T0),
    Ping ! run(RoundTrips, Self),
    receive({ping_done -> true}),
    get_time(T1),
    Microseconds is round((T1-T0)*1_000_000).

benchmark_ping_server(Pong) :-
    receive({
        run(RoundTrips, From) ->
            benchmark_ping_rounds(RoundTrips, Pong),
            From ! ping_done,
            benchmark_ping_server(Pong);
        stop ->
            true
    }).

benchmark_ping_rounds(0, _) :- !.
benchmark_ping_rounds(N, Pong) :-
    self(Self),
    Pong ! ping(Self),
    receive({pong -> true}),
    N1 is N-1,
    benchmark_ping_rounds(N1, Pong).

benchmark_pong_server :-
    receive({
        ping(Ping) ->
            Ping ! pong,
            benchmark_pong_server;
        stop ->
            true
    }).


%!  benchmark_lifecycle_series(+Actors, +Repetitions, -Times) is det.

benchmark_lifecycle_series(Actors, Repetitions, Times) :-
    benchmark_lifecycle_series(precompiled_io, Actors, Repetitions, Times).

benchmark_lifecycle_series(Mode, Actors, Repetitions, Times) :-
    benchmark_lifecycle(Mode, 3, _),
    findall(Microseconds,
            ( between(1, Repetitions, _),
              benchmark_lifecycle(Mode, Actors, Microseconds)
            ),
            Times).


%!  benchmark_chain_series(+Actors, +Repetitions, -Times) is det.

benchmark_chain_series(Actors, Repetitions, Times) :-
    benchmark_chain_series(baseline, Actors, Repetitions, Times).


%!  benchmark_chain_series(+Mode, +Actors, +Repetitions, -Times) is det.
%
%   Compare the former generated-I/O path with the precompiled default, while
%   independently checking whether a stable source module affects the chain:
%
%     - baseline:       parent-module inheritance and generated I/O prelude
%     - stable_goal:    explicitly use this stable source module
%     - precompiled_io: use the default precompiled I/O implementation
%     - template:       stable source module and precompiled I/O

benchmark_chain_series(Mode, Actors, Repetitions, Times) :-
    benchmark_chain_time(Mode, 10, _),
    findall(Microseconds,
            ( between(1, Repetitions, _),
              benchmark_chain_time(Mode, Actors, Microseconds)
            ),
            Times).

benchmark_chain_time(Actors, Microseconds) :-
    benchmark_chain_time(baseline, Actors, Microseconds).

benchmark_chain_time(Mode, Actors, Microseconds) :-
    get_time(T0),
    benchmark_chain_start(Mode, Actors),
    get_time(T1),
    Microseconds is round((T1-T0)*1_000_000).

benchmark_chain_start(Actors) :-
    benchmark_chain_start(baseline, Actors).

benchmark_chain_start(Mode, Actors) :-
    self(Self),
    benchmark_chain_proc(Mode, Actors, Self).

benchmark_chain_proc(_, 0, Root) :- !,
    Root ! ok.
benchmark_chain_proc(Mode, N, Root) :-
    N1 is N-1,
    benchmark_chain_spawn(Mode, N1, Root, Child),
    Child ! ok,
    receive({ok -> true}).

benchmark_chain_spawn(baseline, N, Root, Child) :-
    spawn(benchmark_chain_proc(baseline, N, Root), Child, [
        link(false),
        isolation_io(generated)
    ]).
benchmark_chain_spawn(stable_goal, N, Root, Child) :-
    spawn(user:benchmark_chain_proc(stable_goal, N, Root), Child, [
        link(false),
        isolation_io(generated)
    ]).
benchmark_chain_spawn(precompiled_io, N, Root, Child) :-
    spawn(benchmark_chain_proc(precompiled_io, N, Root), Child, [
        link(false)
    ]).
benchmark_chain_spawn(template, N, Root, Child) :-
    spawn(user:benchmark_chain_proc(template, N, Root), Child, [
        link(false)
    ]).
