:- module(probe_eclipse_rpc).
:- use_module(stateless_rpc).
:- export run/1.

run(Node) :-
    findall(Xs-Ys, rpc(Node, append(Xs, Ys, [a,b]), [limit(1)]), Splits),
    expect(Splits, [[]-[a,b], [a]-[b], [a,b]-[]]),
    findall(Xs-Ys, rpc(Node, append(Xs, Ys, [a,b])), Default),
    expect(Default, Splits),
    findall(Xs-Ys,
            rpc(Node, append(Xs, Ys, [a,b]), [limit(1), once(true)]),
            First),
    expect(First, [[]-[a,b]]),
    findall(ok, rpc(Node, fail, [limit(1)]), Failed),
    expect(Failed, []),
    catch(rpc(Node, throw(rpc_probe_error), [limit(1)]), Error, true),
    expect(Error, rpc_probe_error),
    writeln(eclipse_to_swi_rpc_probe_passed).

expect(Actual, Expected) :-
    ( Actual == Expected -> true
    ; throw(probe_failed(expected(Expected), actual(Actual)))
    ).
