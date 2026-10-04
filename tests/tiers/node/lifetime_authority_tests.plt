:- begin_tests(lifetime_authority).

:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/node_lifetime.pl').
:- use_module('../../../prolog/web_prolog/node_execution_context.pl').
:- use_module('../../../prolog/web_prolog/node_runtime_state.pl').
:- use_module(library(settings)).

principal(Id, principal{id:Id, capabilities:[execute], unknown:false}).

owned_spawn(Id, Carrier, Goal, Pid) :-
    principal(Id, Principal),
    with_owner_context(Principal, Carrier, local, spawn(Goal, Pid)).

wait_dead(Pid) :-
    (actors:resolve_actor_thread(Pid, _) -> sleep(0.01), wait_dead(Pid); true).

kill_wait(Pid) :- actors:exit(Pid, done), call_with_time_limit(3, wait_dead(Pid)).

test(exit_never_resolves_host_alias) :-
    setup_call_cleanup(
        thread_create(thread_get_message(stop), Thread, [alias(d7_host_thread)]),
        ( actors:exit(d7_host_thread, kill), actors:exit(main, kill),
          assertion(thread_property(Thread, status(running))),
          assertion(thread_property(main, status(running))) ),
        (thread_send_message(Thread, stop), thread_join(Thread, _))).

test(exit_never_resolves_host_thread_number) :-
    setup_call_cleanup(
        thread_create(thread_get_message(stop), Thread, []),
        (thread_property(Thread, id(Id)), actors:exit(Id, kill),
         assertion(thread_property(Thread, status(running)))),
        (thread_send_message(Thread, stop), thread_join(Thread, _))).

test(non_owner_cannot_detach,
     [throws(error(permission_error(spawn, detached_actor, link(false)), _))]) :-
    with_public_execution_profile(actor, spawn(true, _, [link(false)])).

test(exit_cannot_cross_principal_tree) :-
    setup_call_cleanup(owned_spawn("alice", a, sleep(5), Pid),
        ( principal("bob", Bob),
          catch(with_owner_context(Bob, b, local, actors:exit(Pid, kill)), E, true),
          assertion(E = error(permission_error(exit, actor, Pid), _)),
          assertion(actors:resolve_actor_thread(Pid, _)) ),
        kill_wait(Pid)).

test(unknown_remote_pid_does_not_grant_exit_authority,
     [throws(error(permission_error(exit, actor, _), _))]) :-
    principal("alice", P),
    with_owner_context(P, a, local, actors:exit(1234567890@'https://other.example', kill)).

test(send_and_monitor_remain_open) :-
    self(Self),
    setup_call_cleanup(owned_spawn("alice", a, receive({hello -> Self ! seen}), Pid),
        ( principal("bob", Bob),
          with_owner_context(Bob, b, local,
              (monitor(Pid, Ref), send(Pid, hello))),
          receive({seen -> true}, [timeout(2), on_timeout(throw(missing_reply))]),
          receive({down(Pid, Ref, _) -> true}, [timeout(2), on_timeout(throw(missing_down))]) ),
        kill_wait(Pid)).

test(demonitor_cannot_remove_another_actors_monitor) :-
    self(Self),
    setup_call_cleanup(
        (spawn(sleep(5), Target),
         spawn((monitor(Target, Ref), Self ! watching(Ref), receive({stop -> true})), Watcher)),
        (receive({watching(Ref) -> true}, [timeout(2), on_timeout(throw(no_monitor))]),
         demonitor(Ref),
         assertion(actors:monitor(Watcher, Target, Ref))),
        (kill_wait(Watcher), kill_wait(Target))).

test(subtree_actor_quota_includes_children) :-
    self(Self),
    setup_call_cleanup(
        (setting(node_lifetime:max_principal_actors, Old),
         set_setting(node_lifetime:max_principal_actors, 1)),
        setup_call_cleanup(
            owned_spawn("quota-test", q,
                (catch(spawn(sleep(5), _), E, true), Self ! child_result(E), receive({stop -> true})), Pid),
            (receive({child_result(E) -> true}, [timeout(2), on_timeout(throw(no_result))]),
             assertion(E = error(resource_error(actors), _))),
            kill_wait(Pid)),
        set_setting(node_lifetime:max_principal_actors, Old)).

test(mailbox_counts_deferred_messages) :-
    setup_call_cleanup(
        (setting(node_lifetime:max_mailbox_messages, Old),
         set_setting(node_lifetime:max_mailbox_messages, 1)),
        setup_call_cleanup(owned_spawn("mailbox-test", q, receive({stop -> true}), Pid),
            (send(Pid, unmatched), sleep(0.03),
             catch(send(Pid, another), E, true),
             assertion(E = error(resource_error(mailbox), _))),
            kill_wait(Pid)),
        set_setting(node_lifetime:max_mailbox_messages, Old)).


test(http_retry_record_retires_with_session) :-
    node_session:session_pid_key(9999999999, Key),
    setup_call_cleanup(assertz(node:isotope_last_event(Key, 1, failure)),
      (node_session:cleanup_isotope_session(Key),
       assertion(\+ node:isotope_last_event(Key, _, _))),
      retractall(node:isotope_last_event(Key, _, _))).

test(browser_pid_requires_ten_digits) :-
    node_ws:browser_local_pid(1000000000),
    node_ws:browser_local_pid(9999999999),
    assertion(\+ node_ws:browser_local_pid(999999999)),
    assertion(\+ node_ws:browser_local_pid(10000000000)).

test(public_peer_bearer_authorizes_lineage) :-
    setup_call_cleanup(
      (node_tokens:issue_token("node:public-peer", [execute, internal_transport], [], Token),
       split_string(Token, "_", "", ["wp", Id, _]),
       format(string(Header), 'Bearer ~w', [Token])),
      (node_auth:request_principal([peer(ip(203,0,113,7)), authorization(Header)], Peer),
       node_lifetime:with_wire_context(_{lineage:"0123456789abcdef0123456789abcdef"}, q, Peer, true)),
      node_tokens:revoke_token(Id)).

test(peer_credentials_are_destination_specific) :-
    setup_call_cleanup(
      register_node_runtime(19487, _{peer_transport_tokens:['https://peer.example'-secret]}),
      with_node_port_context(19487,
        (distribution:hook_transport_options('https://peer.example', [request_header('Authorization'='Bearer secret')]),
         assertion(\+ distribution:hook_transport_options('https://other.example', _)))),
      retractall(node_runtime_state:node_runtime(19487, _))).

test(flat_list_is_not_deep) :-
    numlist(1, 10000, List), node_lifetime:check_depth(List, 2).

test(nested_lists_are_deep, [throws(error(resource_error(term_depth), _))]) :-
    node_lifetime:check_depth([[[x]]], 2).

test(full_watcher_mailbox_does_not_prevent_retirement) :-
    self(Self),
    setup_call_cleanup(
      (setting(node_lifetime:max_mailbox_messages, Old),
       set_setting(node_lifetime:max_mailbox_messages, 1),
       spawn(sleep(5), Target),
       owned_spawn("full-watcher", watcher,
         (monitor(Target, Ref), Self ! ready,
          receive({down(Target, Ref, _) -> Self ! retired})), Watcher)),
      (receive({ready -> true}, [timeout(2), on_timeout(throw(no_ready))]),
       send(Watcher, deferred), sleep(0.02), kill_wait(Target),
       receive({retired -> true}, [timeout(2), on_timeout(throw(no_down))]),
       assertion(\+ actors:resolve_actor_thread(Target, _))),
      (kill_wait(Watcher), kill_wait(Target), set_setting(node_lifetime:max_mailbox_messages, Old))).

test(anonymous_http_accounts_are_independent) :-
    with_owner_context(anonymous, http_call, local, current_owner_context(A)),
    with_owner_context(anonymous, http_call, local, current_owner_context(B)),
    A = ctx(_, IdA, _, _, _), B = ctx(_, IdB, _, _, _), assertion(IdA \== IdB).

test(anonymous_connections_have_independent_accounts) :-
    with_owner_context(anonymous, a, local, current_owner_context(A)),
    with_owner_context(anonymous, b, local, current_owner_context(B)),
    A = ctx(_, IdA, _, _, _), B = ctx(_, IdB, _, _, _), assertion(IdA \== IdB).

test(cpu_watcher_and_tree_metadata_retire) :-
    owned_spawn("watcher-retirement", q, receive({stop -> true}), Pid),
    kill_wait(Pid),
    call_with_time_limit(2, wait_watcher_retired),
    assertion(\+ node_lifetime:principal_lineage(_, tree("watcher-retirement", q), _)).
wait_watcher_retired :-
    (node_lifetime:cpu_watcher(_, "watcher-retirement", _) -> sleep(0.01), wait_watcher_retired; true).

test(all_loader_expansion_hooks_rejected) :-
    forall(member(Name/Arity, [term_expansion/2, goal_expansion/2, term_expansion/4, goal_expansion/4]),
      (functor(Head, Name, Arity),
       catch(node_sandbox:reject_expansion_clause((Head :- true)), E, true),
       assertion(E = error(permission_error(define, expansion_hook, _), _)))).

test(term_depth_is_bounded,
     [throws(error(resource_error(term_depth), _))]) :-
    node_lifetime:check_depth(f(g(h(x))), 2).

test(transport_loss_is_defined_spawn_error,
     [throws(error(remote_spawn_failed(connection_closed), _))]) :-
    setup_call_cleanup(message_queue_create(Q),
        (thread_send_message(Q, connection_closed), distribution:remote_wait_spawned(Q, _)),
        message_queue_destroy(Q)).

test(cancelled_spawn_reply_cannot_satisfy_next_spawn) :-
    setup_call_cleanup(message_queue_create(Q),
        (thread_send_message(Q, spawn_reply("old", spawned(11))),
         thread_send_message(Q, spawn_reply("new", spawned(22))),
         distribution:remote_wait_spawned(Q, "new", Pid), assertion(Pid == 22)),
        message_queue_destroy(Q)).

test(acknowledgement_before_contact_loss_is_not_discarded) :-
    setup_call_cleanup(message_queue_create(Q),
        (thread_send_message(Q, spawn_reply("new", spawned(22))),
         thread_send_message(Q, connection_closed),
         distribution:remote_wait_spawned(Q, "new", Pid), assertion(Pid == 22)),
        message_queue_destroy(Q)).

test(closed_spawn_queue_lives_until_waiter_releases_it) :-
    message_queue_create(Q),
    setup_call_cleanup(assertz(distribution:spawn_queue_user(Q)),
        (distribution:close_spawn_queue(Q), thread_get_message(Q, connection_closed)),
        distribution:release_spawn_queue(Q)),
    catch(message_queue_property(Q, _), E, true),
    assertion(E = error(existence_error(message_queue, Q), _)).

test(lineage_isolates_two_clients_on_one_connection) :-
    Peer = principal{id:"node:test", capabilities:[execute, internal_transport], unknown:false},
    A = "0123456789abcdef0123456789abcdef", B = "fedcba9876543210fedcba9876543210",
    setup_call_cleanup(
        node_lifetime:with_wire_context(_{lineage:A}, shared_connection, Peer,
            actors:spawn(sleep(5), Pid)),
        (node_lifetime:with_wire_context(_{lineage:A}, shared_connection, Peer,
             node_lifetime:connection_owns(shared_connection, Pid)),
         assertion(\+ node_lifetime:with_wire_context(_{lineage:B}, shared_connection, Peer,
             node_lifetime:connection_owns(shared_connection, Pid)))),
        kill_wait(Pid)).

test(browser_cannot_supply_lineage,
     [throws(error(permission_error(use, transport_lineage, _), _))]) :-
    principal("browser", P),
    node_lifetime:with_wire_context(_{lineage:"0123456789abcdef0123456789abcdef"}, q, P, true).

test(detachment_rehomes_terminal) :-
    node_lifetime:rehome_options([link(false), target(creator)], Options),
    assertion(Options == [io_target('$node_log'), link(false)]).

test(compact_pid_is_a_json_number) :-
    distribution:make_id(Id), node_response:json_integer_identity(Id, JSON),
    assertion(integer(JSON)), assertion(JSON == Id),
    assertion(Id >= 1000000000), assertion(Id =< 9999999999).

test(wide_json_identity_preserves_every_bit) :-
    Id is (1 << 128) + 7,
    node_response:json_integer_identity(Id, Text),
    assertion(string(Text)), number_string(Decoded, Text), assertion(Decoded == Id).

test(separate_connections_have_separate_lineages_and_one_principal_account) :-
    principal("same-principal", P),
    with_owner_context(P, connection_a, local, node_lifetime:command_context(_{}, A)),
    with_owner_context(P, connection_b, local, node_lifetime:command_context(_{}, B)),
    assertion(A.lineage \== B.lineage), assertion(A.account == B.account).

test(lineage_reclamation_is_selective) :-
    Peer = principal{id:"node:test", capabilities:[execute, internal_transport], unknown:false},
    A = "0123456789abcdef0123456789abcdef", B = "fedcba9876543210fedcba9876543210",
    setup_call_cleanup(
        (node_lifetime:with_wire_context(_{lineage:A}, shared_connection, Peer,
             actors:spawn(sleep(5), P1)),
         node_lifetime:with_wire_context(_{lineage:B}, shared_connection, Peer,
             actors:spawn(sleep(5), P2))),
        (node_lifetime:with_wire_context(_{lineage:A}, shared_connection, Peer,
             node_lifetime:reclaim_lineage(shared_connection)),
         call_with_time_limit(2, wait_dead(P1)),
         assertion(actors:resolve_actor_thread(P2, _))),
        (kill_wait(P1), kill_wait(P2))).

cpu_spin :- cpu_spin.

test(cpu_quota_is_charged_to_children) :-
    self(Self),
    setup_call_cleanup(
        (setting(node_lifetime:principal_cpu_seconds, Old),
         set_setting(node_lifetime:principal_cpu_seconds, 0.01)),
        setup_call_cleanup(
            owned_spawn("cpu-test", q,
                (spawn(cpu_spin, Child), Self ! child(Child), receive({stop -> true})), Pid),
            (monitor(Pid, Ref),
             receive({child(Child) -> true}, [timeout(2), on_timeout(throw(no_child))]),
             receive({down(Pid, Ref, resource_error(cpu)) -> true},
                     [timeout(2), on_timeout(throw(cpu_quota_not_enforced))]),
             call_with_time_limit(2, wait_dead(Child))),
            kill_wait(Pid)),
        set_setting(node_lifetime:principal_cpu_seconds, Old)).

lease_scenario(URI) :-
    setup_call_cleanup(test_node:ws_open(URI, WS),
        (test_node:ws_send_json(WS, json{command:spawn,goal:"sleep(5)",options:"[]"}),
         test_node:ws_receive_json(WS, Event),
         term_string(Pid, Event.pid),
         sleep(0.5), assertion(\+ actors:resolve_actor_thread(Pid, _))),
        catch(websocket:ws_close(WS, 1000, "done"), _, true)).

test(lease_reclaims_silent_connection_work) :-
    test_node:with_node_server_options([ws_lease_seconds(0.15)], URI,
        plunit_lifetime_authority:lease_scenario(URI)).

% A client that only answers the server's pings (ws_receive/2 replies with
% pong automatically) stays in contact, so its work is not reclaimed.
lease_ping_scenario(URI) :-
    setup_call_cleanup(test_node:ws_open(URI, WS),
        (test_node:ws_send_json(WS, json{command:spawn,goal:"sleep(10)",options:"[]"}),
         test_node:ws_receive_json(WS, Event),
         term_string(Pid, Event.pid),
         catch(call_with_time_limit(1.5, websocket:ws_receive(WS, _)),
               time_limit_exceeded, true),
         assertion(actors:resolve_actor_thread(Pid, _))),
        catch(websocket:ws_close(WS, 1000, "done"), _, true)).

test(lease_pings_keep_a_responsive_connection) :-
    test_node:with_node_server_options([ws_lease_seconds(0.6)], URI,
        plunit_lifetime_authority:lease_ping_scenario(URI)).

:- end_tests(lifetime_authority).
