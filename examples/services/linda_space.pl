% Owner-side tuple-space actor. Included by each runtime bootstrap.
% A blocked request is data in Pending, never a blocked service actor.
linda_loop(Tuples, Pending) :-
    receive({
        linda_connect(From, Ref) ->
            self(Space), From ! linda_connected(Ref, Space),
            linda_loop(Tuples, Pending);
        linda(From, Ref, Operation) ->
            linda_request(Operation, From, Ref, Tuples, Pending, Ts, Ps),
            linda_loop(Ts, Ps);
        linda_cancel(From, Ref) ->
            linda_cancel_pending(Pending, From, Ref, Ps),
            linda_loop(Tuples, Ps);
        down(_, Monitor, _) ->
            linda_drop_monitor(Pending, Monitor, Ps),
            linda_loop(Tuples, Ps)
    }).

linda_request(out(T), From, Ref, Ts0, Ps0, Ts, Ps) :- !,
    ( acyclic_term(T), ground(T)
    -> append(Ts0, [T], Added),
       linda_wake(Ps0, Added, Ps, Ts),
       From ! linda_reply(Ref, ok)
    ; Ts = Ts0, Ps = Ps0, From ! linda_reply(Ref, error(invalid_tuple)) ).
linda_request(Op, From, Ref, Ts0, Ps0, Ts, Ps) :-
    nonvar(Op), Op =.. [Kind, Pattern],
    memberchk(Kind, [in, rd, inp, rdp]), acyclic_term(Pattern), !,
    ( linda_match(Kind, Pattern, Ts0, Ts)
    -> Ps = Ps0, From ! linda_reply(Ref, tuple(Pattern))
    ; Ts = Ts0,
      ( memberchk(Kind, [inp, rdp])
      -> Ps = Ps0, From ! linda_reply(Ref, missing)
      ; monitor(From, M), append(Ps0, [wait(From, Ref, M, Kind, Pattern)], Ps) ) ).
linda_request(_, From, Ref, Ts, Ps, Ts, Ps) :-
    From ! linda_reply(Ref, error(invalid_operation)).

% Failed unifications roll back. A successful take removes one occurrence.
linda_match(Kind, Pattern, Ts0, Ts) :-
    copy_term(Pattern, Copy),
    linda_select(Copy, Ts0, Rest), !,
    Pattern = Copy,
    ( memberchk(Kind, [in, inp]) -> Ts = Rest ; Ts = Ts0 ).

linda_select(T, [T|Ts], Ts).
linda_select(T, [X|Xs], [X|Rest]) :- linda_select(T, Xs, Rest).

linda_wake([], Ts, [], Ts).
linda_wake([wait(F,R,M,K,P)|Rest], Ts0, Ps, Ts) :-
    ( linda_match(K, P, Ts0, Ts1)
    -> demonitor(M, [flush]), F ! linda_reply(R, tuple(P)),
       linda_wake(Rest, Ts1, Ps, Ts)
    ; Ps = [wait(F,R,M,K,P)|Tail], linda_wake(Rest, Ts0, Tail, Ts) ).

linda_cancel_pending([], _, _, []).
linda_cancel_pending([wait(F,R,M,K,P)|Rest], From, Ref, Ps) :-
    ( F == From, R == Ref
    -> demonitor(M, [flush]), Ps = Tail
    ; Ps = [wait(F,R,M,K,P)|Tail] ),
    linda_cancel_pending(Rest, From, Ref, Tail).

linda_drop_monitor([], _, []).
linda_drop_monitor([wait(F,R,M,K,P)|Rest], Monitor, Ps) :-
    ( M == Monitor -> Ps = Tail ; Ps = [wait(F,R,M,K,P)|Tail] ),
    linda_drop_monitor(Rest, Monitor, Tail).
