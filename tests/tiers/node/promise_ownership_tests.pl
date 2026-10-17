:- module(test_promise_ownership, []).

:- use_module('../../../prolog/web_prolog/rpc.pl').
:- use_module('../../../prolog/web_prolog/actors.pl', []).
:- use_module('../../../prolog/web_prolog/node_execution_context.pl').
:- use_module('../../../prolog/web_prolog/node_runtime_state.pl', [with_node_port_context/2]).
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', [with_owner_context/4]).
:- use_module(library(plunit)).

:- meta_predicate in_namespace(+,+,0), in_http(+,+,0), with_pending(-,-,0).
in_namespace(Port,NS,Goal) :-
    with_node_port_context(Port,with_public_execution_context(isobase,NS,Goal)).
in_http(Port,Id,Goal) :-
    Principal=principal{id:Id,capabilities:[execute],unknown:false},
    with_node_port_context(Port,with_public_execution_profile(isobase,
        with_owner_context(Principal,http_call,local,Goal))).
with_pending(Ref,Key,Goal) :-
    setup_call_cleanup(
      (rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
       with_mutex(promise_lifecycle,rpc:new_promise_state(Key,_))),
      Goal,rpc:promise_transaction(rpc:dispose_promise_locked(Key))).
invalid(Error,Ref) :-
    assertion(nonvar(Error)),assertion(Error=error(existence_error(promise,Ref),_)).
foreign_yield(Ref) :-
    catch(yield(Ref,_,[timeout(0),on_timeout(throw(foreign_callback_ran))]),Error,true),
    invalid(Error,Ref).
collect(Key,Ref) :- rpc:deliver_promise_answer(Key,failure),yield(Ref,Answer),assertion(Answer==failure).

:- begin_tests(promise_ownership).

test(namespace_isolation_and_same_namespace_retry,
     [forall(member(Kind,[ws_client,isotope_session]))]) :-
    One=..[Kind,owner_one],Two=..[Kind,owner_two],
    in_namespace(19101,One,with_pending(Ref,Key,
      (in_namespace(19101,Two,(foreign_yield(Ref),promise_cleanup(Ref))),
       yield(Ref,First,[timeout(0)]),assertion(First==timeout),collect(Key,Ref)))).

test(node_scope_isolates_identical_namespace_ids) :-
    in_namespace(19101,ws_client(same),with_pending(Ref,Key,
      (in_namespace(19102,ws_client(same),(foreign_yield(Ref),promise_cleanup(Ref))),collect(Key,Ref)))).

test(session_boundary_takes_precedence_over_shared_principal) :-
    in_http(19101,"alice",in_namespace(19101,ws_client(one),with_pending(Ref,Key,
      (in_namespace(19101,ws_client(two),foreign_yield(Ref)),
       in_http(19101,"alice",without_public_execution_context(foreign_yield(Ref))),
       collect(Key,Ref))))).

test(delegated_lineages_are_distinct_namespaces) :-
    in_namespace(19101,ws_lineage(shared_queue,one),with_pending(Ref,Key,
      (in_namespace(19101,ws_lineage(shared_queue,two),(foreign_yield(Ref),promise_cleanup(Ref))),
       in_namespace(19101,ws_lineage(other_queue,one),foreign_yield(Ref)),collect(Key,Ref)))).

test(owner_can_dispose_but_unknown_cleanup_stays_idempotent) :-
    in_namespace(19101,ws_client(cleaning),with_pending(Ref,Key,
      (promise_cleanup(Ref),promise_cleanup(Ref),
       assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),
       catch(yield(Ref,_),Error,true),invalid(Error,Ref)))).

test(foreign_caller_does_not_learn_that_an_owner_is_already_collecting) :-
    in_namespace(19101,ws_client(owner),with_pending(Ref,Key,
      setup_call_cleanup(message_queue_create(Events),
        setup_call_cleanup(
          thread_create(in_namespace(19101,ws_client(owner),
            (catch(yield(Ref,Answer),Error,Answer=error(Error)),
             thread_send_message(Events,Answer))),Thread,[]),
          (wait_for_claim(Key),
           in_namespace(19101,ws_client(other),(foreign_yield(Ref),promise_cleanup(Ref))),
           rpc:deliver_promise_answer(Key,failure),
           thread_get_message(Events,Answer,[timeout(3)]),assertion(Answer==failure)),
          (rpc:promise_transaction(rpc:dispose_promise_locked(Key)),thread_join(Thread,_))),
        message_queue_destroy(Events)))).

test(authenticated_http_requests_share_principal_but_not_other_principals) :-
    with_pending_for_http("alice",Ref,Key),
    setup_call_cleanup(true,
      (in_http(19101,"bob",(foreign_yield(Ref),promise_cleanup(Ref))),
       in_http(19102,"alice",foreign_yield(Ref)),
       in_http(19101,"alice",collect(Key,Ref))),
      rpc:promise_transaction(rpc:dispose_promise_locked(Key))).

test(anonymous_http_requests_have_distinct_owners,
     [forall(member(Id,[anonymous,"anon:per-ip-or-connection-id"]))]) :-
    with_pending_for_http(Id,Ref,Key),
    setup_call_cleanup(true,
      (in_http(19101,Id,(foreign_yield(Ref),promise_cleanup(Ref))),
       assertion(rpc:promise_state(Key,_,_,_,_,_,_))),
      rpc:promise_transaction(rpc:dispose_promise_locked(Key))).

test(namespace_teardown_does_not_automatically_dispose_promises) :-
    NS=ws_client(ended_promise_namespace),
    setup_call_cleanup(open_client_namespace(NS),
      in_namespace(19101,NS,with_pending(Ref,Key,
        (close_client_namespace(NS),collect(Key,Ref)))),close_client_namespace(NS)).

test(expiry_can_dispose_owned_promise_without_client_context) :-
    in_namespace(19101,ws_client(expiring),with_pending(Ref,Key,
      (without_public_execution_context(rpc:promise_auto_cleanup_thread(Key,0)),
       catch(yield(Ref,_),Error,true),invalid(Error,Ref)))).

test(trusted_local_sharing_across_host_threads) :-
    with_pending(Ref,Key,
      (rpc:deliver_promise_answer(Key,failure),
       setup_call_cleanup(message_queue_create(Events),
         (thread_create((yield(Ref,Answer),thread_send_message(Events,Answer)),Thread,[]),
          thread_get_message(Events,Answer,[timeout(3)]),assertion(Answer==failure),
          thread_join(Thread,Status),assertion(Status==true)),message_queue_destroy(Events)))).

test(trusted_local_sharing_across_actors) :-
    with_pending(Ref,Key,
      (rpc:deliver_promise_answer(Key,failure),actors:self(Self),
       actors:spawn((rpc:yield(Ref,Answer),actors:send(Self,promise_owned_answer(Answer))),Pid,
                    [link(false),monitor(true)]),
       actors:receive({promise_owned_answer(Answer)->assertion(Answer==failure)},
                      [timeout(3),on_timeout(throw(missing_actor_answer))]),
       actors:receive({down(Pid,Pid,_)->true},[timeout(3),on_timeout(throw(missing_actor_down))]))).

test(public_clients_cannot_collect_trusted_local_promises) :-
    with_pending(Ref,Key,
      (in_namespace(19101,ws_client(public),(foreign_yield(Ref),promise_cleanup(Ref))),collect(Key,Ref))).

test(trusted_local_context_cannot_collect_or_dispose_client_promises) :-
    with_pending_for_http("alice",Ref,Key),
    setup_call_cleanup(true,
      (foreign_yield(Ref),promise_cleanup(Ref),in_http(19101,"alice",collect(Key,Ref))),
      rpc:promise_transaction(rpc:dispose_promise_locked(Key))).

test(missing_identity_cannot_borrow_an_outer_http_owner_frame) :-
    in_http(19101,"alice",with_pending(Ref,Key,
      (Principal=principal{id:"inner-client",capabilities:[execute],unknown:false},
       with_owner_context(Principal,non_http_carrier,local,foreign_yield(Ref)),
       collect(Key,Ref)))).

test(unidentified_public_execution_fails_closed) :-
    with_public_execution_profile(isobase,
      (rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
       catch(with_mutex(promise_lifecycle,rpc:new_promise_state(Key,_)),Error,true),
       assertion(nonvar(Error)),
       assertion(Error=error(permission_error(create,promise,client_context),_)),
       assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)))).

:- end_tests(promise_ownership).

with_pending_for_http(Id,Ref,Key) :-
    in_http(19101,Id,
      (rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
       with_mutex(promise_lifecycle,rpc:new_promise_state(Key,_)))).

wait_for_claim(Key) :- call_with_time_limit(3,wait_for_claim_loop(Key)).
wait_for_claim_loop(Key) :-
    (with_mutex(promise_lifecycle,(rpc:promise_state(Key,_,_,_,Claim,_,_),Claim\==none))
    -> true; sleep(0.002),wait_for_claim_loop(Key)).
