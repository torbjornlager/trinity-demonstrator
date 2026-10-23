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
:- use_module(library(prolog_wrap)).

:- begin_tests(cross_node_lifecycle).


%  ----------------------------- helpers ------------------------------

% Diagnostics are opt-in. They observe selection and delivery without changing
% receive clauses, deadlines or the mailbox contents.
:- meta_predicate with_lifecycle_nodes(+, +, 0).
:- thread_local lifecycle_scope/1, lifecycle_origin/1.

% The in-process node harness shares both monitor tables. Track only monitors
% explicitly requested by this fixture, including ones whose local row retires
% before the corresponding wire delivery reaches the controller.
:- thread_local lifecycle_fixture/1, lifecycle_owned_monitor/4.
:- meta_predicate lifecycle_spawn(0,-,+).
with_lifecycle_nodes(Test, Specs, Goal) :-
    gensym(lifecycle_fixture_,Token),
    setup_call_cleanup(
        (asserta(lifecycle_scope(Test),Scope),asserta(lifecycle_fixture(Token),Fixture)),
        (lifecycle_stage(fixture_enter(Test)),
         call_cleanup(
             with_test_nodes(Specs,
                 (lifecycle_stage(server_started(Test)),
                  call_cleanup(Goal,
                      call_cleanup(cleanup_lifecycle_monitors(Token),
                                   lifecycle_stage(before_server_teardown(Test)))))),
             lifecycle_stage(after_server_teardown(Test)))),
        (erase(Fixture),erase(Scope),retractall(lifecycle_owned_monitor(Token,_,_,_)))).

lifecycle_spawn(Goal,Pid,Options) :-
    self(Self),spawn(Goal,Pid,Options),
    (memberchk(monitor(true),Options) -> own_lifecycle_monitor(Self,Pid,Pid);true).
lifecycle_monitor(Pid,Ref) :-
    self(Self),monitor(Pid,Ref),own_lifecycle_monitor(Self,Pid,Ref).
own_lifecycle_monitor(Self,Pid,Ref) :-
    (lifecycle_fixture(Token) ->
        actors:canonical_pid(Pid,Canonical),
        assertz(lifecycle_owned_monitor(Token,Self,Canonical,Ref))
    ;true).

cleanup_lifecycle_monitors(Token) :-
    lifecycle_control_before_cleanup,
    findall(owned(Self,Pid,Ref),lifecycle_owned_monitor(Token,Self,Pid,Ref),Owned),
    % Use the same lock order as local retirement and wire delivery. Once these
    % rows are withdrawn, any prior delivery has finished; future delivery has
    % no fixture-owned watcher to notify. Do not remove other watchers or refs.
    with_mutex(actors_registry,
        with_mutex(actors_monitor_lifecycle,
            forall(member(owned(Self,Pid,Ref),Owned),
                (retractall(actors:monitor(Self,Pid,Ref)),
                 retractall(node_controller:remote_monitor_(Self,Pid,Ref)))))),
    lifecycle_diag(monitors_retired(Owned)),
    forall(member(owned(_,Pid,Ref),Owned),flush_lifecycle_down(Pid,Ref)),
    retractall(lifecycle_owned_monitor(Token,_,_,_)).
flush_lifecycle_down(Pid,Ref) :-
    receive({down(Pid,Ref,_) -> flush_lifecycle_down(Pid,Ref)},
            [timeout(0),on_timeout(true)]).

lifecycle_diag_enabled :- getenv('WP_LIFECYCLE_DIAGNOSTICS','1').
lifecycle_diag(Event) :-
    (lifecycle_diag_enabled -> ignore(catch(lifecycle_diag_write(Event),_,true));true).
lifecycle_diag_write(Event) :-
    get_time(Time),thread_self(Thread),
    (lifecycle_scope(Test)->true;Test=outside_fixture),
    flag(lifecycle_diag_sequence,Seq,Seq+1),
    format(string(Line),'~q.~n',[lifecycle_stage(Seq,Time,Thread,Test,Event)]),
    getenv('WP_LIFECYCLE_LOG',File),
    with_mutex(lifecycle_diagnostic_output,
        setup_call_cleanup(open(File,append,S,[encoding(utf8)]),
                           format(S,'~s',[Line]),close(S))).
lifecycle_stage(Stage) :-
    (lifecycle_diag_enabled -> catch(
        (findall(URL,nb_current(node_url_b,URL),URLs),
         findall(M,actors:deferred(M),Deferred),
         lifecycle_diag(snapshot(Stage,URLs,Deferred))),_,true);true),
    lifecycle_control_stage(Stage).

% Temporary observational wrappers are installed by the diagnostic runner.
% They do not change runtime source files or alter a selected reply.
enable_lifecycle_diagnostics :-
    wrap_predicate(actors:spawn(G,P,O),lifecycle_diag,W1,
        (W1,plunit_cross_node_lifecycle:lifecycle_diag(spawned(P,G,O)))),
    wrap_predicate(toplevel_actors:toplevel_spawn(P,O),lifecycle_diag,W2,
        (W2,plunit_cross_node_lifecycle:lifecycle_diag(toplevel_spawned(P,O)))),
    wrap_predicate(actors:monitor(P,R),lifecycle_diag,W3,
        (W3,plunit_cross_node_lifecycle:lifecycle_diag(monitored(P,R)))),
    wrap_predicate(actors:select_body(C,M,_Mod,_B),lifecycle_diag,W4,
        (W4,(nonvar(M),M=down(_,_,_)
             -> plunit_cross_node_lifecycle:lifecycle_diag(selected(M,C));true))),
    wrap_predicate(actors:send_system(To,M),lifecycle_diag,W5,
        ((nonvar(M),M=down(_,_,_)
           -> plunit_cross_node_lifecycle:log_lifecycle_delivery(To,M);true),W5,
         (nonvar(M),M=down(_,_,_)
           -> plunit_cross_node_lifecycle:lifecycle_diag(delivered(To,M));true))),
    wrap_predicate(distribution:deliver_remote_down_via_controller(P,D),lifecycle_diag,W6,
        setup_call_cleanup(
            asserta(plunit_cross_node_lifecycle:lifecycle_origin(remote_wire(P,D)),Origin),
            (plunit_cross_node_lifecycle:lifecycle_diag(wire_down(P,D)),
             W6),erase(Origin))),
    wrap_predicate(distribution:remote_ws_connection_closed(N),lifecycle_diag,W7,
        setup_call_cleanup(
            asserta(plunit_cross_node_lifecycle:lifecycle_origin(connection_closed(N)),Origin),
            (plunit_cross_node_lifecycle:lifecycle_diag(connection_closed(N)),W7),erase(Origin))),
    wrap_predicate(actors:stop(P,Parent),lifecycle_diag,W8,
        setup_call_cleanup(
            asserta(plunit_cross_node_lifecycle:lifecycle_origin(actor_stop(P,Parent)),Origin),
            (plunit_cross_node_lifecycle:lifecycle_diag(actor_stop(P,Parent)),W8),erase(Origin))).
% The regression holds the old fixture's wire delivery until the following
% fixture has flushed. This private coordinator is off in ordinary tests.
:- dynamic lifecycle_control_queue/1, lifecycle_control_held/1, lifecycle_control_ack/1.
start_lifecycle_schedule_control :-
    message_queue_create(Q),assertz(lifecycle_control_queue(Q)),
    wrap_predicate(distribution:deliver_remote_down_via_controller(P,D),lifecycle_schedule,W,
        (plunit_cross_node_lifecycle:maybe_hold_lifecycle_wire(P,D),W,
         plunit_cross_node_lifecycle:lifecycle_wire_finished(P,D))).
stop_lifecycle_schedule_control :-
    forall(lifecycle_control_queue(Q),
        call_cleanup(
            (thread_send_message(Q,release),
             ((lifecycle_control_held(P), \+ lifecycle_control_ack(P))
              -> ignore(thread_get_message(Q,finished(P),[timeout(2)]));true)),
            (retractall(lifecycle_control_queue(Q)),message_queue_destroy(Q)))),
    retractall(lifecycle_control_held(_)),retractall(lifecycle_control_ack(_)),
    unwrap_predicate(distribution:deliver_remote_down_via_controller/2,lifecycle_schedule).

maybe_hold_lifecycle_wire(P,D) :-
    (get_dict(reason,D,"custom_test_reason"),lifecycle_control_queue(Q)
    -> assertz(lifecycle_control_held(P)),thread_send_message(Q,held(P)),
       lifecycle_diag(control_holding_wire(P)),
       (thread_get_message(Q,release,[timeout(2)])
        -> lifecycle_diag(control_released_wire(P))
        ; throw(error(lifecycle_control_timeout(release),_)))
    ;true).
lifecycle_wire_finished(P,D) :-
    (get_dict(reason,D,"custom_test_reason"),lifecycle_control_queue(Q)
     -> lifecycle_diag(control_wire_finished(P)),thread_send_message(Q,finished(P))
     ;true).
lifecycle_control_before_cleanup :-
    (lifecycle_scope(down_event_preserves_custom_exit_reason),lifecycle_control_queue(Q)
     -> (thread_get_message(Q,held(_),[timeout(2)]) -> true
         ;throw(error(lifecycle_control_timeout(held),_)))
     ;true).
lifecycle_control_stage(fixture_enter(explicit_monitor_2_carries_user_ref)) :-
    lifecycle_control_queue(Q),!,
    lifecycle_diag(control_release_after_flush),thread_send_message(Q,release).
lifecycle_control_stage(_).

log_lifecycle_delivery(To,M) :-
    (lifecycle_origin(Origin)->true;Origin=other),
    lifecycle_diag(delivering(To,M,Origin)).
disable_lifecycle_diagnostics :-
    forall(member(PI,[actors:spawn/3,toplevel_actors:toplevel_spawn/2,
                     actors:monitor/2,actors:select_body/4,actors:send_system/2,
                     distribution:deliver_remote_down_via_controller/2,
                     distribution:remote_ws_connection_closed/1,actors:stop/2]),
           unwrap_predicate(PI,lifecycle_diag)).

flush_mailbox :-
    lifecycle_stage(before_flush),
    receive({_ -> flush_mailbox}, [timeout(0), on_timeout(true)]),
    lifecycle_stage(after_flush).

remote_only_actor_url(URLB) :-
    nb_getval(node_url_b, URLB).


%  -------------------- monitor delivery (down/3) --------------------

test(remote_spawn_monitor_fires_down,
     [setup(flush_mailbox), Result == ok]) :-
    with_lifecycle_nodes(remote_spawn_monitor_fires_down,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            lifecycle_spawn(true, Pid, [node(URLB), monitor(true)]),
            receive({
                down(P, Ref, Reason) ->
                    assertion(P == Pid),
                    %  monitor(true) uses Ref = Pid as the convention.
                    assertion(Ref == Pid),
                    %  Natural exit reason is `true` for a thread
                    %  that returned successfully.
                    assertion(Reason == true)
            }, [timeout(5), on_timeout(fail)]),
            Result = ok
        )).


test(remote_retirement_withdraws_registered_alias,
     [setup(flush_mailbox)]) :-
    with_lifecycle_nodes(remote_retirement_withdraws_registered_alias,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            lifecycle_spawn(sleep(60), Pid, [node(URLB), monitor(true), link(false)]),
            gensym(remote_retired_alias_, Name),
            setup_call_cleanup(register(Name, Pid),
                (   whereis(Name, Before), assertion(Before == Pid),
                    exit(Pid, alias_test_done),
                    receive({down(Pid,Pid,alias_test_done) -> true},
                            [timeout(5), on_timeout(fail)]),
                    whereis(Name, After), assertion(After == undefined)
                ),
                unregister(Name))
        )).


test(remote_synchronous_call_reports_toplevel_termination,
     [setup(flush_mailbox),timeout(5)]) :-
    with_lifecycle_nodes(remote_synchronous_call_reports_toplevel_termination,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            toplevel_spawn(Pid, [node(URLB), session(true)]),
            setup_call_cleanup(true,
                (catch(toplevel_call_synch(Pid,exit(remote_sync_exit),_),Error,true),
                 assertion(Error == toplevel_down(remote_sync_exit))),
                toplevel_halt(Pid,true))
        )).


test(remote_synchronous_correlation,
     [setup(flush_mailbox),forall(test_toplevel_synch:correlation_case(Case))]) :-
    with_lifecycle_nodes(remote_synchronous_correlation,
        [node_spec(b, [profile(actor), auth(open)])],
        (remote_only_actor_url(URLB),
         toplevel_spawn(Pid, [node(URLB), session(true),time_limit(0.15)]),
         setup_call_cleanup(true,
             test_toplevel_synch:correlation_scenario(Pid,Case),
             toplevel_halt(Pid,true)))).

% Correlated answers must not follow the creation-time controller target.
% A subsequent asynchronous call still uses that original target.
test(remote_synchronous_target_and_async_default, [setup(flush_mailbox)]) :-
    with_lifecycle_nodes(remote_synchronous_target_and_async_default, [node_spec(b,[profile(actor),auth(open)])],
        (remote_only_actor_url(URLB), self(Self),
         setup_call_cleanup(lifecycle_spawn(forward_sync_test(Self),Sink,[link(false)]),
             (toplevel_spawn(Pid,[node(URLB),session(true),target(Sink)]),
              setup_call_cleanup(true,
                  (toplevel_call_synch(Pid,true,A,[timeout(2),on_timeout(throw(misrouted))]),
                   assertion(A == success(Pid,[true],false)),
                   toplevel_call(Pid,fail),
                   receive({forwarded(failure(Pid)) -> true},
                           [timeout(2),on_timeout(throw(lost_async_target))])),
                  toplevel_halt(Pid,true))),
             exit(Sink,true)))).

forward_sync_test(Self) :-
    receive({Message -> send(Self,forwarded(Message)),forward_sync_test(Self)}).

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
    with_lifecycle_nodes(remote_spawn_link_propagates_on_parent_kill,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            lifecycle_spawn(parent_with_remote_child(URLB, Self), ParentPid,
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
%  Pins synchronous termination over the generic distributed monitor/exit
%  path and preserves the historical Reply = true interface.

test(remote_toplevel_halt_returns_atom_true,
     [setup(flush_mailbox), Result == ok]) :-
    with_lifecycle_nodes(remote_toplevel_halt_returns_atom_true,
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
    with_lifecycle_nodes(remote_toplevel_halt_cleans_up_local_target,
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
    with_lifecycle_nodes(cross_node_exit_succeeds_silently,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            lifecycle_spawn(sleep(60), Pid, [node(URLB), monitor(true)]),
            wait_until(node_ws_actor_count(URLB, 1), 5),
            exit(Pid, normal),
            receive({ down(P, _, _) -> true },
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
    custom_exit_fixture(Result).

custom_exit_fixture(Result) :-
    with_lifecycle_nodes(down_event_preserves_custom_exit_reason,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            lifecycle_spawn(sleep(60), Pid, [node(URLB), monitor(true)]),
            wait_until(node_ws_actor_count(URLB, 1), 5),
            exit(Pid, custom_test_reason),
            receive({ down(P, Ref, Reason) ->
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
    explicit_monitor_fixture(Result).

explicit_monitor_fixture(Result) :-
    with_lifecycle_nodes(explicit_monitor_2_carries_user_ref,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            lifecycle_spawn(sleep(60), Pid, [node(URLB)]),
            lifecycle_monitor(Pid, Ref),
            assertion(Ref \== Pid),
            exit(Pid, normal),
            receive({ down(P, DownRef, _) ->
                        assertion(P == Pid),
                        assertion(DownRef == Ref)
                    },
                    [timeout(5), on_timeout(fail)]),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            Result = ok
        )).


test(late_previous_fixture_notification_is_retired,
     [setup(flush_mailbox),timeout(10)]) :-
    setup_call_cleanup(start_lifecycle_schedule_control,
        (custom_exit_fixture(Custom),assertion(Custom==ok),
         flush_mailbox,
         explicit_monitor_fixture(Explicit),assertion(Explicit==ok),
         lifecycle_control_queue(Q),lifecycle_control_held(Old),
         thread_get_message(Q,finished(Old),[timeout(2)]),
         assertz(lifecycle_control_ack(Old)),
         assertion(\+ node_controller:remote_monitor_(_,Old,_)),
         receive({down(Old,_,_) -> Late=true},[timeout(0),on_timeout(Late=false)]),
         assertion(Late==false)),
        stop_lifecycle_schedule_control).

test(fixture_cleanup_preserves_other_watchers_and_messages,
     [setup(flush_mailbox)]) :-
    with_lifecycle_nodes(cleanup_is_scoped,
        [node_spec(b,[profile(actor),auth(open)])],
        (remote_only_actor_url(URL),self(Self),
         lifecycle_spawn(sleep(60),Pid,[node(URL),monitor(true)]),
         lifecycle_fixture(Token),OtherWatcher=unrelated_fixture_watcher,
         setup_call_cleanup(
             (assertz(actors:monitor(OtherWatcher,Pid,Pid)),
              assertz(node_controller:remote_monitor_(OtherWatcher,Pid,Pid))),
             (send(Self,down(unrelated_fixture_pid,unrelated_fixture_ref,kept)),
              send(Self,down(Pid,unrelated_fixture_ref,kept_same_pid)),
              send(Self,down(unrelated_fixture_pid,Pid,kept_same_ref)),
              send(Self,down(Pid,Pid,owned_pending)),
              cleanup_lifecycle_monitors(Token),
              assertion(\+ actors:monitor(Self,Pid,Pid)),
              assertion(\+ node_controller:remote_monitor_(Self,Pid,Pid)),
              assertion(actors:monitor(OtherWatcher,Pid,Pid)),
              assertion(node_controller:remote_monitor_(OtherWatcher,Pid,Pid)),
              receive({down(unrelated_fixture_pid,unrelated_fixture_ref,kept)->true},
                      [timeout(0),on_timeout(fail)]),
              receive({down(Pid,unrelated_fixture_ref,kept_same_pid)->true},
                      [timeout(0),on_timeout(fail)]),
              receive({down(unrelated_fixture_pid,Pid,kept_same_ref)->true},
                      [timeout(0),on_timeout(fail)]),
              receive({down(Pid,Pid,_)->Left=true},[timeout(0),on_timeout(Left=false)]),
              assertion(Left==false)),
             (retractall(actors:monitor(OtherWatcher,Pid,Pid)),
              retractall(node_controller:remote_monitor_(OtherWatcher,Pid,Pid)),
              exit(Pid,normal),wait_until(node_ws_actor_count(URL,0),5))))).

%  -- node_controller mirror invariants (proxy-less migration, step 2) --
%
%  These tests pin the invariant that the node_controller tables
%  stay in sync with the proxy era's state.  When step 3+ switches
%  readers over to the controller, these invariants are what make
%  that switch safe.

test(controller_mirrors_target_monitor_link_on_remote_spawn,
     [setup(flush_mailbox), Result == ok]) :-
    with_lifecycle_nodes(controller_mirrors_target_monitor_link_on_remote_spawn,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            lifecycle_spawn(sleep(60), Pid, [node(URLB), monitor(true)]),
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
    with_lifecycle_nodes(controller_drops_monitor_on_demonitor,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            lifecycle_spawn(sleep(60), Pid, [node(URLB)]),
            lifecycle_monitor(Pid, Ref),
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
    with_lifecycle_nodes(cross_node_send_round_trip,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            lifecycle_spawn(receive({ ping(From) -> send(From, pong) }),
                  Pid, [node(URLB), monitor(true)]),
            %  Outbound: test thread -> remote actor.  Exercises
            %  the new send/2 wire-direct clause for Id@Node.
            send(Pid, ping(Self)),
            %  Inbound: remote actor -> test thread.
            receive({ pong -> true },
                    [timeout(5), on_timeout(fail)]),
            %  Wait for the natural down notification (remote actor
            %  exits after sending pong).
            receive({ down(P, _, _) -> assertion(P == Pid) },
                    [timeout(5), on_timeout(fail)]),
            wait_until(node_ws_actor_count(URLB, 0), 5),
            Result = ok
        )).


%  All sends issued through one remote addressing channel share the
%  connection send mutex.  The collector records arrival order in reverse;
%  five sequential sends must therefore produce [5,4,3,2,1].
test(cross_node_send_preserves_single_channel_fifo,
     [setup(flush_mailbox), Result == ok]) :-
    with_lifecycle_nodes(cross_node_send_preserves_single_channel_fifo,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            self(Self),
            lifecycle_spawn(collector(Self, 5, []), Pid, [
                node(URLB),
                monitor(true),
                src_text("
collector(Parent, 0, Acc) :-
    send(Parent, sequence(Acc)).
collector(Parent, N, Acc) :-
    N > 0,
    receive({item(X) -> true}),
    N1 is N - 1,
    collector(Parent, N1, [X|Acc]).
")
            ]),
            forall(between(1, 5, N), send(Pid, item(N))),
            receive({
                sequence(Sequence) ->
                    assertion(Sequence == [5,4,3,2,1])
            }, [timeout(5), on_timeout(fail)]),
            receive({ down(Pid, _, true) -> true },
                    [timeout(5), on_timeout(fail)]),
            Result = ok
        )).


%  A qualified name is a public-service address, not a namespace probe.
%  Sending to an absent service on a live node is therefore a silent no-op.
test(absent_remote_service_send_is_non_revealing,
     [setup(flush_mailbox), Result == ok]) :-
    with_lifecycle_nodes(absent_remote_service_send_is_non_revealing,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            catch(send(definitely_absent_service@URLB, probe), Error, true),
            assertion(var(Error)),
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
    with_lifecycle_nodes(rpc_round_trip_to_remote_node,
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


%  ---- D5: remote toplevel answers and errors keep their exact terms ----
%
%  A node peer receives toplevel events with a `term` field holding
%  canonical term text, so variable sharing within a solution, '$VAR'
%  terms, strings and exception terms survive the hop.

test(remote_toplevel_answers_keep_exact_terms,
     [setup(flush_mailbox), Result == ok]) :-
    with_lifecycle_nodes(remote_toplevel_answers_keep_exact_terms,
        [node_spec(b, [profile(actor), auth(open)])],
        (   remote_only_actor_url(URLB),
            toplevel_spawn(Pid, [node(URLB), session(true)]),
            toplevel_call(Pid, T = f(X, X, '$VAR'(1), "s", 'a b',
                                     '€', nested('漢字','😀'), _),
                          [template(T)]),
            receive({ success(Pid, [Row], false) -> true },
                    [timeout(5), on_timeout(throw(no_answer))]),
            Row = f(A, B, V, S, Q, Euro, Nested, C),
            assertion(A == B),
            assertion(A \== C),
            assertion(V == '$VAR'(1)),
            assertion(S == "s"),
            assertion(Q == 'a b'),
            assertion(Euro == '€'),
            assertion(Nested == nested('漢字','😀')),
            toplevel_call_synch(Pid,
                throw(error(unicode('€', Z, Z), context('漢字','😀'))),
                UnicodeError, [timeout(5)]),
            UnicodeError = error(Pid,error(unicode('€', UnicodeA, UnicodeB),context('漢字','😀'))),
            assertion(var(UnicodeA)), assertion(UnicodeA == UnicodeB), assertion(var(Z)),
            toplevel_call(Pid, atom_length(_, _), []),
            receive({ error(Pid, E) -> true },
                    [timeout(5), on_timeout(throw(no_error))]),
            assertion(subsumes_term(error(instantiation_error, _), E)),
            toplevel_call(Pid, dif(Y, a), [template(Y)]),
            receive({ error(Pid, E2) -> true },
                    [timeout(5), on_timeout(throw(no_error))]),
            assertion(subsumes_term(error(representation_error(constraints), _), E2)),
            toplevel_halt(Pid, _),
            Result = ok
        )).

:- end_tests(cross_node_lifecycle).
