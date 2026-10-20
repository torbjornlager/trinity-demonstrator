:- module(test_supervisor_startup_ownership, []).
:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/node_lifetime.pl', [with_owner_context/4]).
:- use_module('../../../prolog/web_prolog/supervisor_startup.pl', []).
:- use_module('../supervisor_startup_tests.pl', []).
:- use_module(library(plunit)).

:- begin_tests(supervisor_startup_ownership).

test(activated_failed_spawn_can_be_reclaimed_under_its_original_owner) :-
    test_supervisor_startup:with_events(Events,test_supervisor_startup_ownership:
      (test_supervisor_startup:enable(Events),
       nb_setval('$startup_commit_fault',owned_activation_error),
       with_owner_context(principal{id:"startup-owner",capabilities:[execute],unknown:false},
           startup_probe, local,
           catch(supervisor_startup:with_startup_scope(supervisor_actor:do_start_child(
               spec(owned_startup,system:thread_get_message(never),temporary,brutal_kill,worker),
               sup(one_for_one,1,5,[],[]),_)),Error,true)),
       test_supervisor_startup:reserved(Events,Pid),
       setup_call_cleanup(true,
           (assertion(Error==owned_activation_error),
            assertion(\+ actors:resolve_actor_thread(Pid,_)),
            assertion(\+ node_lifetime:actor_owner(Pid,_))),
           test_supervisor_startup:stop_actor(Pid)))).

test(never_activated_spawn_still_releases_ownership_immediately) :-
    with_owner_context(principal{id:"unactivated-owner",capabilities:[execute],unknown:false},
      startup_probe, local,
      (actors:make_pid(Local), actors:canonical_pid(Local,Pid),
       setup_call_cleanup(node_lifetime:admit_actor(Local,[]),
         (assertion(node_lifetime:actor_owner(Pid,_)),
          assertion(\+ actors:resolve_actor_thread(Pid,_)),
          forall(actors:hook_spawn_failed(Local),true),
          assertion(\+ node_lifetime:actor_owner(Pid,_)),
          assertion(\+ node_lifetime:mailbox_count(Pid,_))),
         node_lifetime:forget_actor(Pid)))).

:- end_tests(supervisor_startup_ownership).
