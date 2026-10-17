:- module(test_remote_alias_cleanup, []).

:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/distribution.pl', []).
:- use_module('../../../prolog/web_prolog/node_controller.pl', []).
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- op(200, xfx, @).
:- thread_local alias_namespace/1.
:- multifile actors:hook_namespace/1.
actors:hook_namespace(NS) :- test_remote_alias_cleanup:alias_namespace(NS).

:- meta_predicate in_namespace(+, 0), with_aliases(-, 0).
in_namespace(NS, Goal) :-
    setup_call_cleanup(asserta(alias_namespace(NS), Ref), Goal, erase(Ref)).

% Unique namespaces keep the fixture independent of other node tests.
with_aliases(fixture(One,Two,Name,Remote,Peer,Other,Local), Goal) :-
    gensym(alias_ns_,One), gensym(alias_ns_,Two), gensym(alias_name_,Name),
    Remote=101@'http://alias-lost.invalid:12345',
    Peer=102@'http://alias-lost.invalid:12345',
    Other=101@'http://alias-other.invalid:12345', self(Local),
    setup_call_cleanup(
      (in_namespace(One,
         (register(Name,Remote),register(peer,Peer),register(other,Other),register(local,Local))),
       in_namespace(Two,register(Name,Remote))),
      Goal,
      (with_mutex(actors_registry,
         (retractall(actors:registered(One,_,_)),retractall(actors:registered(Two,_,_)))),
       node_controller:forget_remote_target(Remote),
       node_controller:remove_remote_monitor_by_pid(Remote),
       retractall(actors:monitor(_,Remote,_)),
       retractall(distribution:ws_pending_event('http://alias-lost.invalid:12345',_,_)))).

observed_down(Remote) :-
    distribution:deliver_remote_down_via_controller(Remote, _{type:"down",reason:"normal"}).
lookup(NS,Name,Expected) :-
    in_namespace(NS,(whereis(Name,Found),assertion(Found==Expected))).

:- begin_tests(remote_alias_cleanup).

test(down_clears_exact_pid_across_namespaces_before_notification) :-
    with_aliases(fixture(One,Two,Name,Remote,Peer,Other,Local),
      (self(Self),node_controller:register_remote_target(Remote,Self),
       monitor(Remote,Ref),observed_down(Remote),
       receive({down(Remote,Ref,normal)->true},[timeout(2),on_timeout(throw(missing_alias_down))]),
       lookup(One,Name,undefined),lookup(Two,Name,undefined),
       lookup(One,peer,Peer),lookup(One,other,Other),lookup(One,local,Local),
       assertion(\+node_controller:current_remote_target(Remote,_)),
       assertion(\+actors:monitor(_,Remote,_)))).

test(connection_loss_clears_unmonitored_aliases_on_node) :-
    with_aliases(fixture(One,Two,Name,Remote,_Peer,Other,Local),
      (assertion(\+actors:monitor(_,Remote,_)),
       distribution:remote_ws_connection_closed('http://alias-lost.invalid:12345'),
       lookup(One,Name,undefined),lookup(Two,Name,undefined),lookup(One,peer,undefined),
       lookup(One,other,Other),lookup(One,local,Local))).

test(buffered_down_already_withdraws_aliases) :-
    with_aliases(fixture(One,Two,Name,_Remote,Peer,_,_),
      (distribution:remote_ws_dispatch('http://alias-lost.invalid:12345',unused,
                                      _{type:"down",pid:101,reason:"normal"}),
       lookup(One,Name,undefined),lookup(Two,Name,undefined),lookup(One,peer,Peer),
       assertion(distribution:ws_pending_event('http://alias-lost.invalid:12345',101,_)))).

test(reused_name_survives_duplicate_retirement_of_old_pid) :-
    with_aliases(fixture(One,_,Name,Remote,_,Other,_),
      (observed_down(Remote),
       in_namespace(One,(unregister(other),register(Name,Other))),
       observed_down(Remote),lookup(One,Name,Other))).

test(late_registration_remains_allowed_without_implicit_monitoring) :-
    with_aliases(fixture(One,_,Name,Remote,_,_,_),
      (distribution:remote_ws_connection_closed('http://alias-lost.invalid:12345'),
       in_namespace(One,register(Name,Remote)),lookup(One,Name,Remote),
       assertion(\+actors:monitor(_,Remote,_)),
       assertion(\+node_controller:remote_monitor_(_,Remote,_)))).

test(concurrent_retirement_preserves_replacement_binding) :-
    with_aliases(fixture(One,_,Name,Remote,_,Other,_),
      setup_call_cleanup(message_queue_create(Events),
        (with_mutex(actors_registry,
           (thread_create((thread_send_message(Events,started),observed_down(Remote)),Thread,[]),
            thread_get_message(Events,started,[timeout(2)]),
            in_namespace(One,(unregister(Name),unregister(other),register(Name,Other))))),
         thread_join(Thread,Status),assertion(Status==true),lookup(One,Name,Other)),
        message_queue_destroy(Events))).

:- end_tests(remote_alias_cleanup).
