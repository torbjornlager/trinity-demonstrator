:- module(n5_shared_db).
:- use_module(actors).
:- local op(200, xfx, @).

:- export ancestor_descendant/2, parent_child/2, mother_child/2, father_child/2.
:- export list_price/2, price/2.
:- export service/2, echo_actor/0, count_actor/1, ping_pong/0, ping_pong/1.
:- export ping_pong_benchmark/2, ping/2, pong/1.
:- export authorized/1, owns/2, online/1.
:- export human/1, shared_fact/1, local_label/1, shared_transition_enabled/0.
:- export linda_local_address/1.

:- include('shared_db_common.pl').
:- include('shared_db_actor_eclipse.pl').
:- include('shared_db_n4.pl').

:- include('shared_db_linda_address.pl').

% The benchmark only needs elapsed time and a nonnegative round count.
get_time(Time) :- elapsed(Time).

must_be(nonneg, Value) :-
    ( var(Value) -> throw(error(instantiation_error, ping_pong/1))
    ; \+ integer(Value) -> throw(error(type_error(integer, Value), ping_pong/1))
    ; Value < 0 -> throw(error(domain_error(not_less_than_zero, Value), ping_pong/1))
    ; true ).
