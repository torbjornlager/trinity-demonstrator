% Standalone SWI-Prolog reproducer; no Web Prolog modules or packages.
% Run in a disposable process: pending mode can spin and ignore Ctrl-C.
% Modes: control (no signal), pending (failing poll), peek (local workaround).
:- initialization(main, main).

main :-
    current_prolog_flag(argv,[Mode]),
    memberchk(Mode,[control,pending,peek]),
    setup_call_cleanup(true,true,poll(Mode)),
    writeln(completed).

poll(Mode) :-
    thread_self(Self),
    (Mode==control -> true;thread_signal(Self,true)),
    (   Mode==peek
    ->  (thread_peek_message(Self,_) -> thread_get_message(Self,_);true)
    ;   (thread_get_message(Self,absent,[timeout(0)]) -> true;true)
    ).
