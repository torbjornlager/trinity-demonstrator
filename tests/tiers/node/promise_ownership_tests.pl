:- module(test_promise_ownership, []).

:- use_module('../../../prolog/web_prolog/rpc.pl').
:- use_module('../../../prolog/web_prolog/actors.pl', []).
:- use_module('../../../prolog/web_prolog/node_execution_context.pl').
:- use_module('../../../prolog/web_prolog/node_runtime_state.pl', [with_node_port_context/2]).
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', [with_owner_context/4]).
:- use_module('../../../prolog/web_prolog/node_session.pl', []).
:- use_module(library(plunit)).
:- use_module(library(gensym)).
:- use_module(library(prolog_wrap)).

:- meta_predicate in_namespace(+,+,0), in_http(+,+,0), with_pending(-,-,0).
:- meta_predicate with_live_namespace(+,-,0), with_events(-,-,0),
                  with_owned_pending(+,+,-,-,0), with_http_pending(+,-,-,0).
in_namespace(Port,NS,Goal) :-
    with_node_port_context(Port,with_public_execution_context(isobase,NS,Goal)).
in_http(Port,Id,Goal) :-
    Principal=principal{id:Id,capabilities:[execute],unknown:false},
    with_node_port_context(Port,with_public_execution_profile(isobase,
        with_owner_context(Principal,http_call,local,Goal))).
with_pending(Ref,Key,Goal) :-
    setup_call_cleanup(
      open_fixture_namespace(NS),
      setup_call_cleanup(
        (rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
         with_mutex(promise_lifecycle,rpc:new_promise_state(Key,_))),
        Goal,rpc:promise_transaction(rpc:dispose_promise_locked(Key))),
      close_fixture_namespace(NS)).
open_fixture_namespace(Handle) :-
    (   current_public_execution_namespace(NS)
    ->  (NS=ws_lineage(Q,_)
        -> open_client_connection(Q,ws_client(promise_fixture(Q))),Handle=connection(Q)
        ; open_client_namespace(NS),Handle=namespace(NS))
    ;   Handle=none).
close_fixture_namespace(none) :- !.
close_fixture_namespace(namespace(NS)) :- close_client_namespace(NS).
close_fixture_namespace(connection(Q)) :- close_client_connection(Q).
invalid(Error,Ref) :-
    assertion(nonvar(Error)),assertion(Error=error(existence_error(promise,Ref),_)).
foreign_yield(Ref) :-
    catch(yield(Ref,_,[timeout(0),on_timeout(throw(foreign_callback_ran))]),Error,true),
    invalid(Error,Ref).
collect(Key,Ref) :- rpc:deliver_promise_answer(Key,failure),yield(Ref,Answer),assertion(Answer==failure).

with_owned_pending(Port,NS,Ref,Key,Goal) :-
    in_namespace(Port,NS,with_pending(Ref,Key,Goal)).
with_http_pending(Id,Ref,Key,Goal) :-
    in_http(19101,Id,with_pending(Ref,Key,Goal)).

with_live_namespace(Kind, NS, Goal) :-
    gensym(promise_namespace_,Id),NS=..[Kind,Id],
    with_node_port_context(19101,
        setup_call_cleanup(open_client_namespace(NS),Goal,close_client_namespace(NS))).
with_events(Events, Gate, Goal) :-
    setup_call_cleanup(message_queue_create(Events),
        setup_call_cleanup(message_queue_create(Gate),Goal,message_queue_destroy(Gate)),
        message_queue_destroy(Events)).
queue_gone(Q) :-
    \+catch(message_queue_property(Q,size(_)),error(existence_error(message_queue,_),_),fail).
wait_for(Goal) :- call_with_time_limit(3,wait_for_loop(Goal)).
wait_for_loop(Goal) :- (call(Goal) -> true;sleep(0.001),wait_for_loop(Goal)).
:- meta_predicate wait_for(0), wait_for_loop(0).
thread_stopped(T) :-
    \+catch(thread_property(T,status(running)),error(existence_error(thread,_),_),fail).

blocked_worker(Events, Gate) :-
    setup_call_cleanup(thread_send_message(Events,worker_started),
        thread_get_message(Gate,finish),thread_send_message(Events,worker_unwound)).
start_blocked(Ref,Key,Events,Gate) :-
    rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
    rpc:start_promise(Ref,test_promise_ownership:blocked_worker(Events,Gate)).
resources(Key,Q,W,T) :-
    with_mutex(promise_lifecycle,
        (rpc:promise_state(Key,Q,Worker,Timer,_,_,_),arg(1,Worker,W),arg(1,Timer,T))).

surviving_owner(Events, Gate) :-
    start_blocked(Ref,Key,Events,Gate),thread_send_message(Events,owned(Ref,Key)),
    actors:receive({check_closed -> true}),
    catch(yield(Ref,_,[timeout(0)]),YieldError,true),
    catch(start_blocked(_,_,Events,Gate),CreateError,true),
    thread_send_message(Events,survived(YieldError,CreateError)),actors:receive({}).
stop_test_actor(Pid) :-
    setup_call_cleanup(actors:monitor(Pid,Ref),
        (actors:exit(Pid,kill),actors:receive({down(Pid,Ref,_) -> true},
             [timeout(3),on_timeout(throw(missing_promise_actor_down))])),
        actors:demonitor(Ref,[flush])).

:- thread_local creation_pause/2.
creation_barrier(_) :-
    (creation_pause(Events,Gate)
    -> thread_send_message(Events,admission_checked),thread_get_message(Gate,continue)
    ;true).

:- meta_predicate with_creation_barrier(0).
with_creation_barrier(Goal) :-
    setup_call_cleanup(
        wrap_predicate(rpc:hook_check_promise_owner(Owner),namespace_promise_race,Wrapped,
            (Wrapped,test_promise_ownership:creation_barrier(Owner))),
        Goal,unwrap_predicate(rpc:hook_check_promise_owner/1,namespace_promise_race)).

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

test(namespace_teardown_disposes_promises_and_rejects_late_creation) :-
    NS=ws_client(ended_promise_namespace),
    setup_call_cleanup(open_client_namespace(NS),
      in_namespace(19101,NS,with_pending(Ref,Key,
        (close_client_namespace(NS),close_client_namespace(NS),
         assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),
         catch(yield(Ref,_,[timeout(0),on_timeout(throw(closed_callback_ran))]),Error,true),
         invalid(Error,Ref),
         rpc:make_reference(Late),rpc:promise_queue_key(Late,LateKey),
         catch(with_mutex(promise_lifecycle,rpc:new_promise_state(LateKey,_)),CreateError,true),
         assertion(CreateError=error(permission_error(create,promise,closed_namespace(NS)),_)),
         assertion(\+rpc:promise_state(LateKey,_,_,_,_,_,_))))),close_client_namespace(NS)).

test(teardown_reclaims_local_resources_and_preserves_surviving_actor,
     [forall(member(Kind,[ws_client,isotope_session])),timeout(5)]) :-
    with_events(Events,Gate,with_live_namespace(Kind,NS,
      setup_call_cleanup(
        with_public_execution_namespace(NS,
          actors:spawn(test_promise_ownership:surviving_owner(Events,Gate),Pid,[link(false)])),
        (thread_get_message(Events,owned(Ref,Key),[timeout(3)]),
         thread_get_message(Events,worker_started,[timeout(3)]),resources(Key,Q,W,T),
         close_client_namespace(NS),close_client_namespace(NS),
         assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),assertion(queue_gone(Q)),
         thread_get_message(Events,worker_unwound,[timeout(3)]),
         wait_for(thread_stopped(W)),wait_for(thread_stopped(T)),
         actors:send(Pid,check_closed),
         thread_get_message(Events,survived(YieldError,CreateError),[timeout(3)]),
         invalid(YieldError,Ref),
         assertion(CreateError=error(permission_error(create,promise,closed_namespace(NS)),_)),
         assertion(actors:resolve_actor_thread(Pid,_))),
        stop_test_actor(Pid)))).

test(teardown_wakes_waiting_collector_without_timeout_callback, [timeout(5)]) :-
    with_events(Events,_,with_live_namespace(ws_client,NS,
      in_namespace(19101,NS,with_pending(Ref,Key,
        setup_call_cleanup(
          thread_create(in_namespace(19101,NS,
            (catch(yield(Ref,_,[timeout(3),on_timeout(throw(closed_callback_ran))]),Error,true),
             thread_send_message(Events,collected(Error)))),Thread,[]),
          (wait_for_claim(Key),close_client_namespace(NS),
           thread_get_message(Events,collected(Error),[timeout(3)]),invalid(Error,Ref)),
          (close_client_namespace(NS),thread_join(Thread,_))))))).

test(http_actor_retirement_disposes_promises_in_original_node_scope, [timeout(5)]) :-
    with_live_namespace(isotope_session,NS,
      setup_call_cleanup(actors:spawn(receive({}),Pid,[link(false)]),
        setup_call_cleanup(node_session:register_isotope_session(Pid),
          (node_session:remember_isotope_session_namespace(Pid,NS),
           with_owned_pending(19101,NS,Ref,Key,
             (without_public_execution_context(stop_test_actor(Pid)),
              assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),foreign_yield(Ref)))),
          node_session:cleanup_isotope_session(Pid)),
        stop_test_actor(Pid))).

test(ending_one_ws_toplevel_preserves_promises_in_shared_namespace, [timeout(5)]) :-
    with_live_namespace(ws_client,NS,
      setup_call_cleanup(actors:spawn(receive({}),Pid,[link(false)]),
        setup_call_cleanup(node_session:register_isotope_session(Pid),
          (node_session:remember_isotope_session_namespace(Pid,NS),
           with_owned_pending(19101,NS,Ref,Key,
             (without_public_execution_context(stop_test_actor(Pid)),node_session:cleanup_isotope_session(Pid),
              assertion(client_namespace_status(NS,open)),collect(Key,Ref)))),
          node_session:cleanup_isotope_session(Pid)),
        stop_test_actor(Pid))).

test(teardown_preserves_other_namespace_node_http_and_trusted_promises) :-
    with_pending(LocalRef,LocalKey,
      (with_live_namespace(ws_client,NS,
        with_owned_pending(19101,NS,Ref,Key,
          with_owned_pending(19102,NS,NodeRef,NodeKey,
            with_owned_pending(19101,ws_client(other_promise_owner),OtherRef,OtherKey,
              with_http_pending("alice",HttpRef,HttpKey,
                (close_client_namespace(NS),
                 assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),
                 in_namespace(19101,NS,foreign_yield(Ref)),
                 in_namespace(19102,NS,collect(NodeKey,NodeRef)),
                 in_namespace(19101,ws_client(other_promise_owner),collect(OtherKey,OtherRef)),
                 in_http(19101,"alice",collect(HttpKey,HttpRef)),
                 assertion(rpc:promise_state(LocalKey,_,_,_,_,_,trusted_local)))
              )
            )
          )
        )),
       collect(LocalKey,LocalRef))).

test(connection_closure_sweeps_all_lineages_but_explicit_closure_only_one) :-
    Base=ws_client(promise_connection),A=ws_lineage(Connection,a),B=ws_lineage(Connection,b),
    with_events(Connection,_,
      with_node_port_context(19101,
        setup_call_cleanup(open_client_connection(Connection,Base),
          with_owned_pending(19101,Base,BaseRef,BaseKey,
            with_owned_pending(19101,A,ARef,AKey,
              with_owned_pending(19101,B,BRef,BKey,
                (close_client_namespace(A),
                 assertion(\+rpc:promise_state(AKey,_,_,_,_,_,_)),foreign_yield(ARef),
                 assertion(rpc:promise_state(BaseKey,_,_,_,_,_,_)),
                 assertion(rpc:promise_state(BKey,_,_,_,_,_,_)),
                 close_client_connection(Connection),close_client_connection(Connection),
                 assertion(\+rpc:promise_state(BaseKey,_,_,_,_,_,_)),
                 assertion(\+rpc:promise_state(BKey,_,_,_,_,_,_)),
                 foreign_yield(BaseRef),foreign_yield(BRef))
              )
            )
          ),
          close_client_connection(Connection)))).

test(creation_already_admitted_cannot_escape_teardown_sweep, [timeout(5)]) :-
    with_events(Events,Gate,with_live_namespace(ws_client,NS,
      with_creation_barrier(
        (rpc:make_reference(Ref),rpc:promise_queue_key(Ref,Key),
         thread_create(in_namespace(19101,NS,
           (assertz(test_promise_ownership:creation_pause(Events,Gate)),
            with_mutex(promise_lifecycle,rpc:new_promise_state(Key,Q)),
            thread_send_message(Events,created(Q)))),Creator,[]),
         setup_call_cleanup(true,
           (thread_get_message(Events,admission_checked,[timeout(3)]),
            thread_create(with_node_port_context(19101,close_client_namespace(NS)),Closer,[]),
            wait_for(client_namespace_status(NS,closed)),
            thread_send_message(Gate,continue),
            thread_join(Closer,CloseStatus),assertion(CloseStatus==true),
            thread_get_message(Events,created(Q),[timeout(3)]),
            assertion(\+rpc:promise_state(Key,_,_,_,_,_,_)),assertion(queue_gone(Q))),
           (thread_send_message(Gate,continue),thread_join(Creator,_))))))).

test(collection_and_teardown_have_one_winner,
     [forall(between(1,10,_)),timeout(5)]) :-
    with_events(Events,Gate,with_live_namespace(ws_client,NS,
      in_namespace(19101,NS,with_pending(Ref,Key,
        (rpc:deliver_promise_answer(Key,failure),
         thread_create(in_namespace(19101,NS,
           (thread_get_message(Gate,go),
            catch((yield(Ref,Answer),Result=answer(Answer)),Error,Result=error(Error)),
            thread_send_message(Events,Result))),Collector,[]),
         thread_create(with_node_port_context(19101,
           (thread_get_message(Gate,go),close_client_namespace(NS))),Closer,[]),
         thread_send_message(Gate,go),thread_send_message(Gate,go),
         thread_join(Closer,CloseStatus),assertion(CloseStatus==true),
         thread_join(Collector,CollectStatus),assertion(CollectStatus==true),
         thread_get_message(Events,Result,[timeout(3)]),
         (Result==answer(failure) -> true;Result=error(Error),invalid(Error,Ref)),
         assertion(\+rpc:promise_state(Key,_,_,_,_,_,_))))))).

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
