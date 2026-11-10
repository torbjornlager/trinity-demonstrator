:- module(findnsols_probe).
:- use_module(chunked_solutions).
:- lib(prolog_extras).
:- export run_findnsols_probe/0.

:- dynamic visited/1.

run_findnsols_probe :-
    findall(Chunk, findnsols(2, X, member(X, [a,b,c,d,e]), Chunk), Chunks),
    expect(Chunks, [[a,b],[c,d],[e]]),
    findall(Chunk, findnsols(2, X, (X=a; X=b; X=c; X=d), Chunk), Exact),
    expect(Exact, [[a,b],[c,d]]),
    findall(Chunk, findnsols(2, X, (X=1; X=2; fail), Chunk), Residual),
    expect(Residual, [[1,2],[]]),
    findall(Chunk, findnsols(2, X, fail, Chunk), Empty),
    expect(Empty, [[]]),
    once(findnsols(0, X, throw(zero_evaluated_goal), Zero)),
    expect(Zero, []),
    catch(findnsols(-1, X, fail, _), Negative, true),
    expect(Negative, error(domain_error(not_less_than_zero, -1), findnsols/4)),

    once(findnsols(2, pair(X,Y), member(X, [a,b,c]), [pair(a,A),pair(b,B)])),
    ( var(X), var(Y), var(A), var(B), A \== B -> true
    ; throw(template_bindings_escaped)
    ),
    once(findnsols(2, X, member(X, [a,b,c]), [c])),
    catch(findall(Chunk, findnsols(1, X, (X=a; throw(goal_error)), Chunk), _),
          Error, true),
    expect(Error, goal_error),

    retractall(visited(_)),
    once(findnsols(2, X, tracked(X), First)),
    expect(First, [a,b]),
    findall(Event, visited(Event), Visits),
    expect(Visits, [a,b,cleanup]),
    writeln(eclipse_findnsols_probe_passed),
    mutable_count_probe.

mutable_count_probe :-
    findall(Chunk, findnsols(count(2), X, member(X, [a,b,c]), Chunk), Fixed),
    expect(Fixed, [[a,b],[c]]),
    new_chunk_count(2, Count),
    findall(Chunk,
            ( findnsols(Count, X, member(X, [a,b,c,d,e,f,g]), Chunk),
              ( Chunk == [a,b] -> set_chunk_count(Count, 3)
              ; Chunk == [c,d,e] -> set_chunk_count(Count, 1)
              ; true
              )
            ), Resized),
    expect(Resized, [[a,b],[c,d,e],[f],[g]]),
    new_chunk_count(2, UntilExhausted),
    findall(Chunk,
            ( findnsols(UntilExhausted, X, member(X, [a,b,c,d,e]), Chunk),
              set_chunk_count(UntilExhausted, 0)
            ), Tail),
    expect(Tail, [[a,b],[c,d,e]]),
    once(findnsols(UntilExhausted, X, throw(zero_evaluated_goal), Empty)),
    expect(Empty, []),
    writeln(eclipse_findnsols_count_probe_passed).

tracked(X) :-
    setup_call_cleanup(
        true,
        ( member(X, [a,b,c]), assertz(visited(X)) ),
        assertz(visited(cleanup))
    ).

expect(Actual, Expected) :-
    ( Actual == Expected -> true
    ; throw(probe_failed(expected(Expected), actual(Actual)))
    ).
