% Run in a disposable process: a regressed poll inside signal-masked cleanup
% cannot reliably be interrupted by another Prolog signal or time-limit alarm.
:- use_module('../../../prolog/web_prolog/actors.pl').
:- initialization(main, main).

main :-
    current_prolog_flag(argv,[Mode]),
    nb_setval(signal_ran,false),
    (run(Mode) -> writeln(completed);throw(zero_poll_fixture_failed(Mode))).

pending_signal :-
    thread_self(Self),thread_signal(Self,nb_setval(signal_ran,true)).
not_run_yet :- nb_getval(signal_ran,false).
ran_after_cleanup :- nb_getval(signal_ran,true).

run(empty_integer) :- empty(0).
run(empty_float) :- empty(0.0).
run(selection) :-
    self(Self),send(Self,first),send(Self,offer(Sender,Sender)),
    send(Self,pick),send(Self,last),
    setup_call_cleanup(true,true,
      (pending_signal,
       receive({offer(coffee,_) -> fail;pick -> Selected=yes},
               [timeout(0),on_timeout(fail)]),Selected==yes,
       receive({offer(X,Y) -> true},[timeout(0),on_timeout(fail)]),
       X==Y,var(X),var(Sender),
       receive({Next -> true},[timeout(0),on_timeout(fail)]),Next==first,
       receive({Tail -> true},[timeout(0),on_timeout(fail)]),Tail==last,
       \+ receive({absent -> true},[timeout(0),on_timeout(fail)]),
       not_run_yet)),
    ran_after_cleanup.
run(monitor_flush) :-
    self(Self),monitor(1000000001,Ref),make_ref(Other),
    send(Self,down(unrelated,Other,keep)),send(Self,marker),
    setup_call_cleanup(true,true,
      (pending_signal,demonitor(Ref,[flush]),
       receive({down(_,Ref,_) -> fail},[timeout(0),on_timeout(true)]),
       receive({down(unrelated,Other,keep) -> true},[timeout(0),on_timeout(fail)]),
       receive({marker -> true},[timeout(0),on_timeout(fail)]),not_run_yet)),
    ran_after_cleanup.

empty(Zero) :-
    setup_call_cleanup(true,true,
      (pending_signal,
       receive({absent -> fail},[timeout(Zero),on_timeout(Outcome=waiting)]),
       Outcome==waiting,not_run_yet)),
    ran_after_cleanup.
