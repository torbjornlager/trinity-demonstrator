:- module(test_supervisor_startup, []).
:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../prolog/web_prolog/supervisor_startup.pl', []).
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- multifile isolation:prepare_module/3.
% Fail preparation after provisional child admission, without a URL fetch.
% Relative-URL errors vary between platforms and available local services.
isolation:prepare_module(_, _, Options) :-
    memberchk(src_text('% supervisor startup failure probe'), Options),
    throw(error(startup_source_probe, test_supervisor_startup)).

:- multifile actors:hook_admit_spawn/3, actors:hook_check_monitor/1,
             actors:hook_check_send/2, actors:hook_spawn_commit/2.
actors:hook_admit_spawn(Pid0, _, _) :-
    nb_current('$startup_test_observer', Observer),
    nb_current('$sup_starting_child', _),
    actors:canonical_pid(Pid0, Pid),
    thread_send_message(Observer, reserved(Pid)).
actors:hook_check_monitor(_) :-
    nb_current('$startup_monitor_fault', Error),
    nb_delete('$startup_monitor_fault'), throw(Error).
actors:hook_check_send(Pid, '$stop'(_, _)) :-
    nb_current('$startup_test_observer', Observer),
    thread_send_message(Observer, stop_seen(Pid)),
    (nb_current('$startup_cleanup_fault', true)
    -> nb_delete('$startup_cleanup_fault'), throw(cleanup_probe_error)
    ; true).

actors:hook_spawn_commit(_, _) :-
    nb_current('$sup_starting_child', _),
    nb_current('$startup_commit_fault', Error),
    nb_delete('$startup_commit_fault'), throw(Error).

enable(Observer) :- nb_setval('$startup_test_observer', Observer).
callback(hold, Observer, ok, Observer) :- !,
    thread_send_message(Observer, held), receive({never -> true}).
callback(_, State, ok, State).

:- meta_predicate with_events(-,0).
with_events(Events, Goal) :-
    gensym(supervisor_startup_events_, Events),
    setup_call_cleanup(message_queue_create(_, [alias(Events)]), Goal,
        (maplist(nb_delete, ['$startup_test_observer','$startup_commit_fault',
                             '$startup_monitor_fault','$startup_cleanup_fault']),
         message_queue_destroy(Events))).

stop_actor(Pid) :-
    setup_call_cleanup(monitor(Pid, Ref),
        (exit(Pid, kill), receive({down(Pid, Ref, _) -> true},
             [timeout(3), on_timeout(throw(test_cleanup_timeout))])),
        demonitor(Ref, [flush])).

server_spec(Id, Policy, spec(Id,server(test_supervisor_startup:callback,[]),temporary,Policy,worker)).
bad_start(server(test_supervisor_startup:callback,[src_text('% supervisor startup failure probe')])).
reserved(Events, Pid) :-
    thread_get_message(Events, reserved(Pid), [timeout(3)]).
stopped(Events, Pid) :- thread_get_message(Events, stop_seen(Pid), [timeout(3)]).
assert_dead(Pid) :- assertion(\+ actors:resolve_actor_thread(Pid, _)).
assert_no_private_messages(Pids) :-
    receive({down(Pid,_,_) if memberchk(Pid,Pids) -> fail}, [timeout(0)]).

:- op(1000, xfy, if).
:- begin_tests(supervisor_startup).

test(initial_exception_reclaims_prior_children_in_reverse_order) :-
    with_events(Events,
      (bad_start(Bad),
       supervisor_spawn(test_supervisor_startup:[
           child(startup_a,[start(server(callback,[]))]),
           child(startup_b,[start(server(callback,[]))]),
           child(startup_bad,[start(Bad)])], Sup,
           [monitor(true),src_list([(:- test_supervisor_startup:enable(Events))])]),
       receive({down(Sup,Sup,exception(Error)) -> true}, [timeout(4),on_timeout(fail)]),
       assertion(nonvar(Error)),
       assertion(Error=error(startup_source_probe,_)),
       reserved(Events,A), reserved(Events,B), reserved(Events,C),
       stopped(Events,C), stopped(Events,B), stopped(Events,A),
       maplist(assert_dead,[A,B,C]),
       whereis(startup_a,undefined),whereis(startup_b,undefined),whereis(startup_bad,undefined))).

test(initial_failure_preserves_init_failed) :-
    with_events(Events,
      (server_spec(startup_duplicate,0.1,Spec),
       spawn((test_supervisor_startup:enable(Events),
              supervisor_actor:sup_init([Spec,Spec],sup(one_for_one,1,5,[],[]))),Sup,[monitor(true)]),
       receive({down(Sup,Sup,init_failed) -> true},[timeout(3),on_timeout(fail)]),
       reserved(Events,Pid),stopped(Events,Pid),assert_dead(Pid),
       whereis(startup_duplicate,undefined))).

test(provisional_child_monitor_failure_is_reclaimed) :-
    with_events(Events,
      (enable(Events),server_spec(startup_provisional,0.1,Spec),
       nb_setval('$startup_monitor_fault',before_admission),
       catch(supervisor_startup:with_startup_scope(
           supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),_)),Error,true),
       assertion(Error == before_admission),reserved(Events,Pid),stopped(Events,Pid),
       assert_dead(Pid),whereis(startup_provisional,undefined),assert_no_private_messages([Pid]))).

test(activation_exception_reclaims_provisional_plain_child) :-
    with_events(Events,
      (enable(Events),
       Spec=spec(startup_activated,system:thread_get_message(never),temporary,brutal_kill,worker),
       nb_setval('$startup_commit_fault',after_activation),
       catch(supervisor_startup:with_startup_scope(
           supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),_)),Error,true),
       assertion(Error == after_activation),reserved(Events,Pid),assert_dead(Pid),
       assert_no_private_messages([Pid]))).

test(committed_state_preserves_specification_variable_sharing) :-
    with_events(Events,
      (enable(Events),
       Spec=spec(shared_child,system:thread_get_message(Shared),temporary,brutal_kill,worker),
       supervisor_startup:with_startup_scope(
           supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),State)),
       setup_call_cleanup(true,
           (State=sup(_,_,_,[ch(_,_,Stored)],_), assertion(Stored == Spec), assertion(var(Shared))),
           (State=sup(_,_,_,Children,_), supervisor_actor:shutdown_children(Children))))).

test(rollback_respects_shutdown_and_preserves_application_monitor,
     [forall(member(Policy-Expected,[0.1-true,infinity-true,brutal_kill-kill]))]) :-
    with_events(Events,
      (enable(Events),server_spec(startup_policy,Policy,Spec),
       Saved=saved(none),self(Self),send(Self,unrelated_startup_message),
       catch(supervisor_startup:with_startup_scope(
         (supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),sup(_,_,_,[ch(_,Pid,_)],_)),
          monitor(Pid,AppRef),nb_setarg(1,Saved,Pid-AppRef),throw(policy_probe))),Error,true),
       assertion(Error == policy_probe),arg(1,Saved,P-R),
       receive({down(P,R,Reason) -> true},[timeout(2),on_timeout(fail)]),
       assertion(Reason == Expected),assert_dead(P),whereis(startup_policy,undefined),
       receive({unrelated_startup_message -> true},[timeout(0),on_timeout(fail)]),
       assert_no_private_messages([P]))).

test(rollback_numeric_timeout_forces_blocked_server) :-
    with_events(Events,
      (enable(Events),Spec=spec(startup_blocked,server(test_supervisor_startup:callback,[initial_state(Events)]),temporary,0.02,worker),
       Saved=saved(none),self(Self),
       catch(supervisor_startup:with_startup_scope(
         (supervisor_actor:do_start_child(Spec,sup(one_for_one,1,5,[],[]),sup(_,_,_,[ch(_,Pid,_)],_)),
          monitor(Pid,AppRef),nb_setarg(1,Saved,Pid-AppRef),make_ref(Req),
          send(Pid,'$call'(Self,Req,hold)),thread_get_message(Events,held,[timeout(2)]),throw(blocked_probe))),Error,true),
       assertion(Error == blocked_probe),arg(1,Saved,P-R),
       receive({down(P,R,shutdown) -> true},[timeout(2),on_timeout(fail)]),assert_dead(P),
       assert_no_private_messages([P]))).

test(cleanup_error_does_not_replace_primary_or_skip_siblings) :-
    with_events(Events,
      (enable(Events),server_spec(startup_cleanup_a,0.1,A),server_spec(startup_cleanup_b,0.1,B),
       catch(supervisor_startup:with_startup_scope(
          (supervisor_actor:do_start_child(A,sup(one_for_one,1,5,[],[]),S1),
           supervisor_actor:do_start_child(B,S1,_),
           nb_setval('$startup_cleanup_fault',true),throw(primary_startup_error))),Error,true),
       assertion(Error == primary_startup_error),reserved(Events,P),reserved(Events,Q),
       assert_dead(P),assert_dead(Q),whereis(startup_cleanup_a,undefined),whereis(startup_cleanup_b,undefined))).

test(dynamic_exception_preserves_siblings_and_allows_retry) :-
    with_events(Events,
      setup_call_cleanup(
       supervisor_spawn(test_supervisor_startup:[child(startup_stable,[start(receive({never -> true}))])],Sup,
           [src_list([(:- test_supervisor_startup:enable(Events))])]),
       (supervisor_which_children(Sup,Before),bad_start(Bad),
        supervisor_spawn_child(Sup,test_supervisor_startup:child(startup_retry,[start(Bad)]),Reply),
        assertion(nonvar(Reply)),
        assertion(Reply=error(error(startup_source_probe,_))),
        supervisor_which_children(Sup,After),assertion(Before==After),
        supervisor_spawn_child(Sup,test_supervisor_startup:child(startup_retry,[start(server(callback,[]))]),Added),
        assertion(Added==ok),supervisor_count_children(Sup,Counts),assertion(memberchk(active-2,Counts))),
       stop_actor(Sup))).

test(committed_supervisor_exit_retains_parent_link_containment) :-
    self(Self),
    setup_call_cleanup(
      spawn((supervisor_startup:with_startup_scope(
          (supervisor_actor:do_start_child(
              spec(exit_child,system:thread_get_message(never),temporary,brutal_kill,worker),
              sup(one_for_one,1,5,[],[]),sup(_,_,_,[ch(_,P,_)],_)),
           send(Self,owned_startup_child(P)),receive({finish -> exit(startup_stopped)})))),Sup,[monitor(true)]),
      (receive({owned_startup_child(Child) -> true},[timeout(2),on_timeout(fail)]),
       setup_call_cleanup(monitor(Child,Ref),
         (send(Sup,finish),
          receive({down(Sup,Sup,startup_stopped) -> true},[timeout(2),on_timeout(fail)]),
          receive({down(Child,Ref,kill) -> true},[timeout(2),on_timeout(fail)]),assert_dead(Child)),
         demonitor(Ref,[flush]))),
      (demonitor(Sup,[flush]),stop_actor(Sup))).

test(reserved_controls_are_not_addition_replies,
     [forall(member(Control,['$abort_goal','$ptcp_time_limit']))]) :-
    catch(supervisor_actor:startup_error_reply(Control,_),Error,true),assertion(Error==Control).

:- end_tests(supervisor_startup).
