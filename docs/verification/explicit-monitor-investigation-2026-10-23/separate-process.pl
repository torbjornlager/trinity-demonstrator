:- ensure_loaded('../../../tests/tiers/t4_node.pl').

probe :-
    forall(between(1,3,Trial),
        setup_call_cleanup(
            test_toplevel_correlation_transport:start_native_peer(Process,URL),
            (actors:spawn(sleep(60),Pid,[node(URL),monitor(true)]),
             actors:exit(Pid,custom_test_reason),
             actors:receive({down(Pid,Pid,custom_test_reason)->true},
                            [timeout(5),on_timeout(throw(missing_down))]),
             actors:receive({down(Pid,Pid,R)->Extra=some(R)},
                            [timeout(0.2),on_timeout(Extra=none)]),
             format('separate_process(~q,~q,~q,~q).~n',[Trial,URL,Pid,Extra]),
             assertion(Extra==none)),
            test_toplevel_correlation_transport:stop_native_peer(Process))).
