:- module(test_namespace_teardown, []).

:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/node_execution_context.pl').
:- use_module('../../../prolog/web_prolog/node_session.pl', []).
:- use_module('../../../prolog/web_prolog/node_ws.pl', []).
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', []).
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- multifile actors:hook_spawn_option/3, isolation:prepare_module/3.
actors:hook_spawn_option(namespace_test_gate, internal, error:must_be(nonvar)).
isolation:prepare_module(_, _, Options) :-
    memberchk(namespace_test_gate(control(Events,Gate)), Options),
    self(Pid),thread_send_message(Events,preparing(Pid)),thread_get_message(Gate,go).

:- meta_predicate with_namespace(-,0), with_actor(-,0), with_connection(-,-,0).
with_namespace(NS, Goal) :-
    gensym(namespace_test_,Id),NS=ws_client(Id),
    setup_call_cleanup(open_client_namespace(NS),Goal,close_client_namespace(NS)).
with_actor(Pid, Goal) :-
    setup_call_cleanup(spawn(receive({}),Pid,[link(false)]),Goal,stop_actor(Pid)).
stop_actor(Pid) :-
    monitor(Pid,Ref),exit(Pid,true),
    receive({down(Pid,Ref,_)->true},[timeout(3),on_timeout(throw(missing_namespace_down))]).
with_connection(Q, NS, Goal) :-
    gensym(namespace_connection_,Id),NS=ws_client(Id),
    setup_call_cleanup(message_queue_create(Q),
      setup_call_cleanup(open_client_connection(Q,NS),Goal,close_client_connection(Q)),
      catch(message_queue_destroy(Q),_,true)).
register_remote(Name) :- register(Name,'@'(101,'http://namespace-remote.invalid:12345')).
lookup(NS,Name,Expected) :-
    with_public_execution_namespace(NS,(whereis(Name,Found),assertion(Found==Expected))).
closed_error(Error, NS) :-
    assertion(nonvar(Error)),
    assertion(Error=error(permission_error(register,closed_namespace,NS),_)).

:- begin_tests(namespace_teardown).

test(close_sweeps_only_its_namespace_and_preserves_actor_and_service) :-
    with_namespace(One,with_namespace(Two,with_actor(Pid,
      (gensym(namespace_service_,Service),
       setup_call_cleanup(register_service(Service,Pid),
         (with_public_execution_namespace(One,register(shared,Pid)),
          with_public_execution_namespace(Two,register(shared,Pid)),
          close_client_namespace(One),close_client_namespace(One),
          lookup(One,shared,undefined),lookup(Two,shared,Pid),
          whereis_service(Service,Published),assertion(Published==Pid),
          assertion(actors:resolve_actor_thread(Pid,_)),
          with_public_execution_namespace(One,
            catch(register_remote(late),Error,true)),closed_error(Error,One)),
         unregister_service(Service)))))).

test(leaving_request_context_keeps_namespace_open) :-
    with_namespace(NS,
      (with_public_execution_namespace(NS,register_remote(first)),
       with_public_execution_namespace(NS,(unregister(first),register_remote(second))),
       client_namespace_status(NS,Status),assertion(Status==open))).

test(surviving_actor_cannot_repopulate_closed_namespace) :-
    with_namespace(NS,
      (self(Parent),with_public_execution_namespace(NS,
         spawn((receive({try_register->true}),self(Self),
                catch(register(late,Self),Error,true),send(Parent,result(Error)),receive({})),
               Pid,[link(false)])),
       setup_call_cleanup(true,
         (close_client_namespace(NS),send(Pid,try_register),
          receive({result(Error)->true},[timeout(3),on_timeout(throw(missing_late_result))]),
          closed_error(Error,NS),lookup(NS,late,undefined),
          assertion(actors:resolve_actor_thread(Pid,_))),stop_actor(Pid)))).

test(closed_namespace_rejects_named_creation_before_launch) :-
    with_namespace(NS,
      (close_client_namespace(NS),
       with_public_execution_namespace(NS,
         catch(spawn_with_name(true,Pid,[],[name(late)]),Error,true)),
       closed_error(Error,NS),assertion(var(Pid)))).

test(close_cancels_prepared_name_without_running_application) :-
    with_namespace(NS,
      setup_call_cleanup(message_queue_create(Events),
        setup_call_cleanup(message_queue_create(Gate),
          (thread_create(with_public_execution_namespace(NS,
              (catch(spawn_with_name(thread_send_message(Events,application_ran),_,
                         [link(false),namespace_test_gate(control(Events,Gate))],[name(delayed)]),Error,true),
               thread_send_message(Events,result(Error)))),Thread,[]),
           thread_get_message(Events,preparing(Pid),[timeout(3)]),
           close_client_namespace(NS),thread_send_message(Gate,go),
           thread_get_message(Events,result(Error),[timeout(3)]),
           thread_join(Thread,Status),assertion(Status==true),closed_error(Error,NS),
           stop_actor(Pid),lookup(NS,delayed,undefined),
           assertion(\+actors:spawn_name_reservation(_,NS,_,_,_,_)),
           assertion(\+thread_get_message(Events,application_ran,[timeout(0)]))),
          message_queue_destroy(Gate)),message_queue_destroy(Events))).

test(http_bookkeeping_replacement_preserves_namespace_cleanup_ends_it) :-
    gensym(namespace_http_,Id),NS=isotope_session(Id),
    setup_call_cleanup(open_client_namespace(NS),
      with_actor(Pid,
        setup_call_cleanup(node_session:register_isotope_session(Pid),
          (node_session:remember_isotope_session_namespace(Pid,NS),
           with_public_execution_namespace(NS,register_remote(alias)),
           node_session:register_isotope_session(Pid),lookup(NS,alias,'@'(101,'http://namespace-remote.invalid:12345')),
           node_session:cleanup_isotope_session(Pid),lookup(NS,alias,undefined),
           client_namespace_status(NS,Status),assertion(Status==closed),
           assertion(actors:resolve_actor_thread(Pid,_))),
          node_session:cleanup_isotope_session(Pid))),close_client_namespace(NS)).

test(http_actor_retirement_closes_namespace_before_down) :-
    gensym(namespace_http_stop_,Id),NS=isotope_session(Id),
    setup_call_cleanup(open_client_namespace(NS),
      (spawn(receive({}),Pid,[link(false)]),
       setup_call_cleanup(node_session:register_isotope_session(Pid),
         (node_session:remember_isotope_session_namespace(Pid,NS),
          with_public_execution_namespace(NS,register_remote(alias)),
          stop_actor(Pid),lookup(NS,alias,undefined),
          client_namespace_status(NS,Status),assertion(Status==closed)),
         node_session:cleanup_isotope_session(Pid))),close_client_namespace(NS)).

test(http_session_remembered_after_early_exit_is_closed) :-
    gensym(namespace_http_early_,Id),NS=isotope_session(Id),
    setup_call_cleanup(open_client_namespace(NS),
      (spawn(receive({}),Pid,[link(false)]),stop_actor(Pid),
       node_session:remember_isotope_session_namespace(Pid,NS),
       client_namespace_status(NS,Status),assertion(Status==closed),
       node_session:cleanup_isotope_session(Pid)),close_client_namespace(NS)).

test(ending_one_ws_toplevel_keeps_shared_namespace_open) :-
    with_connection(_,NS,
      (spawn(receive({}),Pid,[link(false)]),
       setup_call_cleanup(node_session:register_isotope_session(Pid),
         (node_session:remember_isotope_session_namespace(Pid,NS),
          with_public_execution_namespace(NS,register_remote(alias)),stop_actor(Pid),
          node_session:cleanup_isotope_session(Pid),
          client_namespace_status(NS,Status),assertion(Status==open),
          with_public_execution_namespace(NS,(unregister(alias),register_remote(next)))),
         node_session:cleanup_isotope_session(Pid)))).

test(ws_disconnect_closes_base_and_delegated_namespaces) :-
    with_connection(Q,NS,
      (Delegated=ws_lineage(Q,token),
       with_public_execution_namespace(NS,register_remote(base)),
       with_public_execution_namespace(Delegated,register_remote(alias)),
       thread_create(thread_get_message(Q,'$ws_close'),Relay,[]),
       node_ws:ws_cleanup(Q,Relay,_{}),
       lookup(NS,base,undefined),lookup(Delegated,alias,undefined),
       with_public_execution_namespace(Delegated,catch(register_remote(late),Error,true)),
       closed_error(Error,Delegated),
       assertion(\+node_execution_context:closed_lineage(Q,_)),
       assertion(\+node_execution_context:namespace_connection(Q,_)))).

test(explicit_lineage_closure_blocks_reentry_only_for_that_lineage) :-
    with_connection(Q,NS,
      (Peer=principal{id:"node:namespace-test",capabilities:[execute,internal_transport],unknown:false},
       A="0123456789abcdef0123456789abcdef",B="fedcba9876543210fedcba9876543210",
       atom_string(Token,A),Delegated=ws_lineage(Q,Token),
       node_lifetime:with_wire_context(_{lineage:A},Q,Peer,test_namespace_teardown:register_remote(alias)),
       node_lifetime:with_wire_context(_{lineage:A},Q,Peer,node_lifetime:reclaim_lineage(Q)),
       lookup(Delegated,alias,undefined),
       catch(node_lifetime:with_wire_context(_{lineage:A},Q,Peer,test_namespace_teardown:register_remote(late)),Error,true),
       closed_error(Error,Delegated),
       node_lifetime:with_wire_context(_{lineage:B},Q,Peer,test_namespace_teardown:register_remote(other)),
       client_namespace_status(NS,Status),assertion(Status==open))).

:- end_tests(namespace_teardown).
