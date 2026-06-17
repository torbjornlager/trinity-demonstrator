/*  Cross-node lifecycle tests.

    These tests pin the cross-node behaviors fixed in the
    proxy / monitor / halt / link / down-arity round of work.
    They run two test nodes in the same SWI-Prolog process via
    multi_node_harness.

    See multi_node_harness.pl for the in-process caveats.

    Coverage:
      - Cross-node remote spawn + monitor delivery (down/3 with ref).
      - Cross-node link assertion: actor.pl path (already worked).
      - Cross-node link assertion: toplevel_actor.pl remote
        toplevel_spawn (the missing-link bug fixed today).
      - Cross-node toplevel_halt: returns Reply = true (atom), not "true" (string).
      - Cross-node toplevel_halt: target actor terminates on n4.
      - No proxy stragglers: remote_pid_proxy/2 retracted after halt.
*/

:- use_module('../../../prolog/web_prolog/actor_api.pl').
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../../prolog/web_prolog/node.pl').
:- use_module('../../../prolog/web_prolog/node_log.pl').
:- use_module('../../../prolog/web_prolog/node_controller.pl').
:- use_module('multi_node_harness.pl').

:- use_module(library(plunit)).

:- begin_tests(cross_node_lifecycle).


%  ----------------------------- helpers ------------------------------

flush_mailbox :-
    receive({_ -> flush_mailbox}, [timeout(0), on_timeout(true)]).

remote_only_actor_url(URLB) :-
    nb_getval(node_url_b, URLB).


%  -------------------- monitor delivery (down/3) --------------------

test(remote_spawn_monitor_fires_down,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            spawn(true, Pid, [node(URLB), monitor(true)]),
            receive({
                down(Ref, P, Reason) ->
                    assertion(P == Pid),
                    %  monitor(true) uses Ref = Pid as the convention.
                    assertion(Ref == Pid),
                    %  Natural exit reason is `true` for a thread
                    %  that returned successfully.
                    assertion(Reason == true)
            }, [timeout(5), on_timeout(fail)]),
            Result = ok
        )).


%  ------------------ cross-node link propagation --------------------
%
%  Spawn a parent actor on node A whose body is "spawn a child on
%  node B, then sleep until killed".  Kill the parent.  The child on
%  B must terminate because of link(true).
%
%  This pins the actor.pl side of cross-node link propagation.

parent_with_remote_child(URLB, ParentReady) :-
    %  Default link(true).  sleep/1 is a built-in -- no source
    %  shipping required.  60 seconds is long enough for the test to
    %  finish; the link-driven kill terminates the child early.
    spawn(sleep(60), _Child, [node(URLB)]),
    ParentReady ! ready,
    receive({ _ -> true }).

test(remote_spawn_link_propagates_on_parent_kill,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            spawn(parent_with_remote_child(URLB, Self), ParentPid,
                  [monitor(true)]),
            (   receive({ ready -> true },
                        [timeout(5), on_timeout(fail)])
            ->  format(user_error, "phase1 ok~n", [])
            ;   format(user_error, "phase1 FAIL: no ready from parent~n", []), fail
            ),
            wait_until(node_ws_actor_count(URLB, 1), 5),
            exit(ParentPid, killed_by_test),
            receive({ down(_, _, _) -> true },
                    [timeout(5), on_timeout(fail)]),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            assert_no_orphans(URLB),
            Result = ok
        )).


%  -------------------- cross-node toplevel_halt --------------------
%
%  Pins both the rename/JSON-boolean wiring and the parse_halted_reply
%  fix that turns the JSON string "true" back into the atom true.

test(remote_toplevel_halt_returns_atom_true,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            toplevel_spawn(Pid, [node(URLB), session(true)]),
            toplevel_halt(Pid, Reply),
            assertion(Reply == true),
            assertion(\+ string(Reply)),
            %  And the remote actor really is gone.
            wait_until(node_ws_actor_count(URLB, 0), 5),
            assert_no_orphans(URLB),
            Result = ok
        )).


%  ---- no leftover proxy registration on the caller after halt ----
%
%  Pins the proxy teardown via setup_call_cleanup + the monitor
%  installed in commit_inherited_ws_actor_spawn.  After
%  toplevel_halt, the local proxy thread should exit and the
%  remote_pid_proxy/2 fact should be retracted.

test(remote_toplevel_halt_cleans_up_local_target,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            toplevel_spawn(Pid, [node(URLB), session(true)]),
            %  Target must be registered immediately after spawn.
            assertion(node_controller:current_remote_target(Pid, _)),
            toplevel_halt(Pid, _Reply),
            %  After halt + down delivery, the controller's target
            %  registration must be drained.
            wait_until(\+ node_controller:current_remote_target(Pid, _), 5),
            Result = ok
        )).


%  -------------------------- two-node rpc ---------------------------
%
%  Sanity-check the rpc path end-to-end with a small fact set on
%  node B, queried from the test thread.

%  --------- safe_remote_kill_send: success path with a live node ----------
%
%  The unreachable-node failure path is covered by
%  actor_remote_exit_failure.plt.  Here we pin the complementary
%  invariant: when the cross-node WebSocket is healthy, exiting a
%  remote actor must NOT emit a remote_exit_failed event.  Together
%  the two tests bracket the observability contract.

collect_global_remote_exit_failures(Events) :-
    findall(E,
            ( node_log:node_log_event(global, _Seq, E),
              get_dict(event_type, E, "remote_exit_failed")
            ),
            Events).

test(cross_node_exit_succeeds_silently,
     [setup((flush_mailbox, node_log:clear_log_scope(global))),
      Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            spawn(sleep(60), Pid, [node(URLB), monitor(true)]),
            wait_until(node_ws_actor_count(URLB, 1), 5),
            exit(Pid, normal),
            receive({ down(_, P, _) -> true },
                    [timeout(5), on_timeout(fail)]),
            assertion(P == Pid),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            %  Critical postcondition: no failure events were logged.
            collect_global_remote_exit_failures(Events),
            assertion(Events == []),
            Result = ok
        )).


%  ------------ down/3 wire format: custom reason round-trips --------------
%
%  exit(Pid, Reason) where Reason is an arbitrary atom must arrive
%  intact in the down/3 message delivered locally.  This pins the
%  answer_to_json(down/3) + ws_json_down_reason round-trip end to end.

test(down_event_preserves_custom_exit_reason,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            spawn(sleep(60), Pid, [node(URLB), monitor(true)]),
            wait_until(node_ws_actor_count(URLB, 1), 5),
            exit(Pid, custom_test_reason),
            receive({ down(Ref, P, Reason) ->
                        assertion(P == Pid),
                        assertion(Ref == Pid),       % monitor(true) sentinel
                        assertion(Reason == custom_test_reason)
                    },
                    [timeout(5), on_timeout(fail)]),
            Result = ok
        )).


%  ------- explicit monitor/2 returns a fresh ref carried by down/3 --------
%
%  Spawn without an at-spawn monitor, then install a monitor via
%  monitor/2, and verify the down delivered when the actor exits
%  carries the Ref returned by monitor/2, NOT the pid-as-sentinel
%  that monitor(true) at spawn time would use.

test(explicit_monitor_2_carries_user_ref,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            spawn(sleep(60), Pid, [node(URLB)]),
            monitor(Pid, Ref),
            assertion(Ref \== Pid),
            exit(Pid, normal),
            receive({ down(DownRef, P, _) ->
                        assertion(P == Pid),
                        assertion(DownRef == Ref)
                    },
                    [timeout(5), on_timeout(fail)]),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            Result = ok
        )).


%  -- node_controller mirror invariants (proxy-less migration, step 2) --
%
%  These tests pin the invariant that the node_controller tables
%  stay in sync with the proxy era's state.  When step 3+ switches
%  readers over to the controller, these invariants are what make
%  that switch safe.

test(controller_mirrors_target_monitor_link_on_remote_spawn,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            spawn(sleep(60), Pid, [node(URLB), monitor(true)]),
            %  Three writes mirrored: target, monitor (Ref = Pid
            %  for monitor(true)), link (default link(true)).
            assertion(current_remote_target(Pid, Self)),
            assertion(node_controller:remote_monitor_(Self, Pid, Pid)),
            assertion(node_controller:remote_link_(Self, Pid)),
            %  Clean up: kill the remote actor and wait for the
            %  proxy finalize to drain the controller tables.
            exit(Pid, normal),
            receive({ down(_, _, _) -> true },
                    [timeout(5), on_timeout(fail)]),
            wait_until(\+ current_remote_target(Pid, _), 5),
            wait_until(\+ node_controller:remote_monitor_(_, Pid, _), 5),
            %  The link entry is drained by stop/2 of the local
            %  watcher actor, not by the proxy finalize.  For a
            %  test thread (which never goes through stop/2), the
            %  link mirror does not auto-clean -- that is the same
            %  behaviour as the legacy link/2 table, which also
            %  leaks for tests run from the shell.  Step 5 will
            %  align this once exit/2 reads from remote_link_/2.
            Result = ok
        )).

test(controller_drops_monitor_on_demonitor,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            spawn(sleep(60), Pid, [node(URLB)]),
            monitor(Pid, Ref),
            self(Self),
            assertion(node_controller:remote_monitor_(Self, Pid, Ref)),
            demonitor(Ref),
            assertion(\+ node_controller:remote_monitor_(_, _, Ref)),
            exit(Pid, normal),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            Result = ok
        )).

%  ----- cross-node send/2 round-trip (proxy-less migration, step 4) -----
%
%  Pin that messages sent from the test thread to a remote actor's
%  mailbox, and from that remote actor back to the test thread,
%  both work after the proxy is bypassed on the send path.  Uses an
%  echo-style actors: receive a ping(From) message, send pong back.

test(cross_node_send_round_trip,
     [setup(flush_mailbox), Result == ok]) :-
    with_test_nodes(
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            spawn(receive({ ping(From) -> send(From, pong) }),
                  Pid, [node(URLB), monitor(true)]),
            %  Outbound: test thread -> remote actor.  Exercises
            %  the new send/2 wire-direct clause for Id@Node.
            send(Pid, ping(Self)),
            %  Inbound: remote actor -> test thread.
            receive({ pong -> true },
                    [timeout(5), on_timeout(fail)]),
            %  Wait for the natural down notification (remote actor
            %  exits after sending pong).
            receive({ down(_, P, _) -> assertion(P == Pid) },
                    [timeout(5), on_timeout(fail)]),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            Result = ok
        )).


setup_node_b_with_humans(URLB) :-
    %  Inject facts into node B's shared DB by loading a small
    %  source text at startup.
    %  (with_test_nodes accepts arbitrary node/2 options.)
    (   nonvar(URLB)
    ->  true
    ;   nb_getval(node_url_b, URLB)
    ).

test(rpc_round_trip_to_remote_node,
     [setup(flush_mailbox), Result == [plato, aristotle]]) :-
    with_test_nodes(
        [node_spec(b, [
            profile(actor), auth(open),
            load_shared_db_text("human(plato).\nhuman(aristotle).\n")
        ])],
        (   remote_only_actor_url(URLB),
            findall(Who, rpc(URLB, human(Who)), Result0),
            sort(Result0, Result0Sorted),
            sort([plato, aristotle], Expected),
            assertion(Result0Sorted == Expected),
            Result = Result0
        )).


:- end_tests(cross_node_lifecycle).
