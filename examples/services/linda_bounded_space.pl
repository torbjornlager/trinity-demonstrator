% Public Trealla service admission. Keep the ordinary Linda protocol and FIFO
% semantics; never evict tuples or waiting readers to admit another request.
% Limits allow 512 stored tuples and 256 pending requests, each at most
% 4096 logical units (term nodes plus atom/number text characters).
linda_bounded_loop(Tuples, Pending) :-
    receive({
        linda_connect(From, Ref) ->
            self(Space),
            From ! linda_connected(Ref, Space),
            linda_bounded_loop(Tuples, Pending) ;
        linda(From, Ref, Operation) ->
            linda_bounded_request(Operation, From, Ref, Tuples, Pending, Ts, Ps),
            linda_bounded_loop(Ts, Ps) ;
        linda_cancel(From, Ref) ->
            linda_cancel_pending(Pending, From, Ref, Ps),
            linda_bounded_loop(Tuples, Ps) ;
        down(_, Monitor, _) ->
            linda_drop_monitor(Pending, Monitor, Ps),
            linda_bounded_loop(Tuples, Ps)
    }).

linda_bounded_request(Op, From, Ref, Ts0, Ps0, Ts, Ps) :-
    (  linda_admission_error(Op, Ts0, Ps0, Error)
    -> Ts = Ts0,
       Ps = Ps0,
       From ! linda_reply(Ref, error(Error))
    ;  linda_request(Op, From, Ref, Ts0, Ps0, Ts, Ps)
    ).

linda_admission_error(Op, _, _, tuple_too_large) :-
    nonvar(Op), Op =.. [Kind, Term], memberchk(Kind, [out, in, rd, inp, rdp]),
    acyclic_term(Term), \+ linda_term_budget(Term, 4096, _), !.
linda_admission_error(out(T), Ts, _, tuple_space_full) :-
    acyclic_term(T), ground(T), length(Ts, N), N >= 512, !.
linda_admission_error(Op, Ts, Ps, pending_requests_full) :-
    nonvar(Op), Op =.. [Kind, Pattern], memberchk(Kind, [in, rd]),
    acyclic_term(Pattern),
    \+ linda_match(Kind, Pattern, Ts, _),
    length(Ps, N), N >= 256.

% Consume a finite budget during traversal so oversized terms cannot cause an
% unbounded sizing pass. Variables count as one node; compound arguments are
% visited directly instead of allocating a second copy through univ.
linda_term_budget(Term, Before, After) :-
    Before > 0,
    (  var(Term)
    -> After is Before - 1
    ;  atomic(Term)
    -> (  atom(Term)
       -> atom_length(Term, Size)
       ;  number_chars(Term, Chars),
          length(Chars, Size)
       ),
       After is Before - Size - 1,
       After >= 0
    ;  functor(Term, Name, Arity),
       atom_length(Name, Size),
       Left is Before - Size - 1,
       Left >= 0,
       linda_args_budget(1, Arity, Term, Left, After)
    ).

linda_args_budget(I, Arity, _, Before, Before) :- I > Arity, !.
linda_args_budget(I, Arity, Term, Before, After) :-
    arg(I, Term, Arg), linda_term_budget(Arg, Before, Left),
    Next is I + 1, linda_args_budget(Next, Arity, Term, Left, After).
