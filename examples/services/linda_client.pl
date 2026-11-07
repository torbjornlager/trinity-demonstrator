% Owner-installed application interface; loaded into the node shared database.
% Clients call these five predicates without loading protocol implementation.
linda_out(Tuple) :- linda_local_call(out(Tuple), ok).
linda_in(Tuple) :- linda_local_call(in(Tuple), tuple(Tuple)).
linda_rd(Tuple) :- linda_local_call(rd(Tuple), tuple(Tuple)).
linda_inp(Tuple) :- linda_local_call(inp(Tuple), tuple(Tuple)).
linda_rdp(Tuple) :- linda_local_call(rdp(Tuple), tuple(Tuple)).

linda_local_call(Operation, Result) :-
    linda_local_address(Address),
    self(Me),
    make_ref(Ref),
    Address ! linda_connect(Me, Ref),
    receive({
        linda_connected(Ref, Space) -> true
    },[
        timeout(5),
        on_timeout(throw(linda_down(unavailable)))
    ]),
    linda_call(Space, Operation, Result).

linda_call(Space, Operation, Result) :-
    self(Me),
    make_ref(Ref),
    setup_call_cleanup(
        monitor(Space, Monitor),
        (  Space ! linda(Me, Ref, Operation),
           receive({
               linda_reply(Ref, Reply) -> true ;
               down(_, Monitor, Reason) -> throw(linda_down(Reason))
           }),
           linda_result(Reply, Result)
        ),
        (  catch(Space ! linda_cancel(Me, Ref), _, true),
           demonitor(Monitor, [flush])
        )
    ).

linda_result(error(Reason), _) :- !, throw(linda_error(Reason)).
linda_result(missing, _) :- !, fail.
linda_result(Reply, Reply).
