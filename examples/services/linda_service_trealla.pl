% Owner bootstrap for the Trealla deployment. Application code stays here,
% independently of the Trealla actor runtime and the public Examples drawer.
:- module(linda_service_trealla, [start_linda_service/1]).
:- use_module('/app/actors.pl').

:- include(linda_space).

start_linda_service(Pid) :-
    spawn(linda_loop([], []), Pid,
          [link(false),
           src_predicates([linda_loop/2, linda_request/7, linda_match/4,
                           linda_select/3, linda_wake/4,
                           linda_cancel_pending/4, linda_drop_monitor/3])]),
    catch(register_service(linda, Pid), Error,
          (exit(Pid, kill), throw(Error))).
