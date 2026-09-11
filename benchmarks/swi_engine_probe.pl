:- module(swi_engine_probe, [main/0]).

:- use_module('../prolog/web_prolog/actors').
:- use_module(library(http/json)).
:- use_module(library(error)).

% Research harness only: engines here are not a Web Prolog actor backend.
% The Python driver samples RSS while this process waits at each marker.
main :-
    current_prolog_flag(argv, Args),
    ( Args = [memory, Mode, CountAtom]
    -> atom_number(CountAtom, Count), must_be(nonneg, Count),
       memberchk(Mode, [actor, thread, engine]),
       marker(baseline), read(go),
       with_idle(Count, Mode, (marker(ready), read(stop)))
    ; Args = [scheduling, Mode, CountAtom]
    -> atom_number(CountAtom, Count), must_be(positive_integer, Count),
       scheduling(Mode, Count, Milliseconds),
       json_write_dict(current_output,
                       _{mode:Mode, iterations:Count,
                         probe_delay_ms:Milliseconds}), nl
    ; throw(error(domain_error(probe_arguments, Args), _))
    ).

marker(Marker) :- writeln(Marker), flush_output.

:- meta_predicate with_idle(+, +, 0).
with_idle(0, _, Goal) :- !, call(Goal).
with_idle(N, Mode, Goal) :-
    setup_call_cleanup(idle_create(Mode, Handle),
                       (N1 is N-1, with_idle(N1, Mode, Goal)),
                       idle_destroy(Mode, Handle)).

idle_create(engine, Engine) :-
    engine_create(_, engine_idle, Engine),
    engine_next(Engine, ready).
idle_create(thread, Thread) :-
    thread_self(Parent),
    thread_create((thread_send_message(Parent, ready),
                   thread_get_message(stop)), Thread, []),
    thread_get_message(ready).
idle_create(actor, Pid) :-
    self(Parent),
    spawn(actor_idle(Parent), Pid, [link(false), monitor(true)]),
    receive({ready -> true}).

engine_idle :- engine_yield(ready), engine_fetch(stop).
actor_idle(Parent) :- Parent ! ready, receive({stop -> true}).

idle_destroy(engine, Engine) :- engine_destroy(Engine).
idle_destroy(thread, Thread) :-
    thread_send_message(Thread, stop), thread_join(Thread, true).
idle_destroy(actor, Pid) :-
    Pid ! stop,
    receive({down(Pid, _, true) -> true},
            [timeout(5), on_timeout(throw(actor_cleanup_timeout(Pid)))]).

% Both engines are ready before timing. Dispatch the busy one first:
% this deliberately models a single worker, without hidden yield insertion.
scheduling(engine, Count, Milliseconds) :-
    setup_call_cleanup(
        engine_create(_, (engine_yield(ready), burn(Count),
                          engine_yield(done)), Busy),
        setup_call_cleanup(
            engine_create(_, (engine_yield(ready), engine_yield(pong)), Probe),
            ( engine_next(Busy, ready), engine_next(Probe, ready),
              get_time(Start),
              engine_next(Busy, done), engine_next(Probe, pong),
              get_time(End), Milliseconds is (End-Start)*1000 ),
            engine_destroy(Probe)),
        engine_destroy(Busy)).

scheduling(actor, Count, Milliseconds) :-
    self(Parent),
    setup_call_cleanup(
        spawn(actor_busy(Parent, Count), Busy, [link(false), monitor(true)]),
        setup_call_cleanup(
            spawn(actor_probe, Probe, [link(false), monitor(true)]),
            ( Busy ! go,
              receive({busy_started -> true}),
              get_time(Start), Probe ! ping(Parent),
              receive({pong -> true}), get_time(End),
              Milliseconds is (End-Start)*1000,
              receive({busy_done -> true}) ),
            idle_destroy(actor, Probe)),
        idle_destroy(actor, Busy)).

actor_busy(Parent, Count) :-
    receive({go -> true}), Parent ! busy_started,
    burn(Count), Parent ! busy_done, receive({stop -> true}).
actor_probe :-
    receive({ping(Parent) -> Parent ! pong}), receive({stop -> true}).

burn(0) :- !.
burn(N) :- N1 is N-1, burn(N1).
