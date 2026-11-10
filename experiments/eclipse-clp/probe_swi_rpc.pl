:- initialization(main, main).

main([URI]) :-
    findall(Xs-Ys, rpc(URI, append(Xs, Ys, [a,b]), [limit(1)]), Splits),
    expect(Splits, [[]-[a,b], [a]-[b], [a,b]-[]]),
    findall(Xs-Ys,
            rpc(URI, append(Xs, Ys, [a,b]), [limit(1), once(true)]),
            First),
    expect(First, [[]-[a,b]]),
    findall(ok, rpc(URI, fail, [limit(1)]), Failed),
    expect(Failed, []),
    catch(rpc(URI, throw(rpc_probe_error), [limit(1)]), Error, true),
    expect(Error, rpc_probe_error),
    writeln(swi_to_eclipse_rpc_probe_passed).
main(_) :-
    throw(error(domain_error(arguments, 'expected one ECLiPSe base URI'), main/1)).

expect(Actual, Expected) :-
    ( Actual == Expected -> true
    ; throw(error(probe_failed(Expected, Actual), main/1))
    ).
