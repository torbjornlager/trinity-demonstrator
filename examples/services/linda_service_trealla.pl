% Owner bootstrap for the Trealla deployment. Application code stays here,
% independently of the Trealla actor runtime and the public Examples drawer.
:- module(linda_service_trealla, [start_linda_service/1]).
:- use_module('/app/actors.pl').

:- include(linda_space).
:- include(linda_bounded_space).

start_linda_service(Pid) :-
    spawn(linda_bounded_loop([], []), Pid,
          [link(false),
           src_predicates([linda_bounded_loop/2, linda_bounded_request/7,
                           linda_admission_error/4, linda_term_budget/3,
                           linda_args_budget/5, linda_request/7, linda_match/4,
                           linda_select/3, linda_wake/4,
                           linda_cancel_pending/4, linda_drop_monitor/3])]),
    catch(register_service(linda, Pid), Error,
          (exit(Pid, kill), throw(Error))).
