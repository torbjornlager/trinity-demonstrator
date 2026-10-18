:- module(test_remote_named_creation, []).

:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/distribution.pl', []).
:- use_module('../../../prolog/web_prolog/node_controller.pl', []).
:- use_module('../../../prolog/web_prolog/node_execution_context.pl').
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../../prolog/web_prolog/server_actor.pl').
:- use_module('../../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../../prolog/web_prolog/statechart_actor.pl').
:- use_module('multi_node_harness.pl').
:- use_module('../../../prolog/web_prolog/node_ws.pl', []).
:- use_module(library(plunit)).
:- use_module(library(gensym)).
:- use_module(library(prolog_wrap)).
:- use_module(library(time)).
:- op(200,xfx,@).

:- thread_local spawn_mock/4, fault_alarm/1.
:- thread_local deny_named_spawn/0.
:- thread_local pause_target_lookup/2.
:- multifile actors:hook_check_spawn/1.
actors:hook_check_spawn(_) :-
    test_remote_named_creation:deny_named_spawn,throw(named_admission_rejected).
:- meta_predicate with_mock(+,-,-,-,0), in_mock(+,+,+,+,0).

% Fault injection replaces only the transport round trip in the controlled
% caller. Routing, reservations, buffered-event processing and publication run
% through production code. Other threads and real-node tests use the transport.
in_mock(Node,Id,Action,Events,Goal) :-
    setup_call_cleanup(asserta(spawn_mock(Node,Id,Action,Events),Ref),Goal,erase(Ref)).
with_mock(Action, Name, Pid, Events, Goal) :-
    gensym(remote_named_ns_,Tag),NS=ws_client(Tag),gensym(remote_named_alias_,Name),
    distribution:make_id(Id),Node='http://named-startup.invalid:12345',Pid=Id@Node,
    setup_call_cleanup(message_queue_create(Events),
      setup_call_cleanup(open_client_namespace(NS),
        setup_call_cleanup(
          (wrap_predicate(distribution:remote_request_spawn(N,C,P),named_test,W1,
              (test_remote_named_creation:mock_for_node(N,_,_,_)
              -> test_remote_named_creation:mock_spawn(N,C,P);W1)),
           wrap_predicate(distribution:safe_remote_kill_send(N,P,_,Command),named_test,W2,
              (test_remote_named_creation:mock_for_node(N,_,Action,Q)
              -> thread_send_message(Q,stopped(P)),thread_send_message(Q,kill_command(Command)),
                 (Action==keep_monitor -> true
                 ;distribution:deliver_remote_down_via_controller(P@N,_{reason:"normal"}))
              ;W2))),
          with_public_execution_namespace(NS,in_mock(Node,Id,Action,Events,Goal)),
          (unwrap_predicate(distribution:remote_request_spawn/3,named_test),
           unwrap_predicate(distribution:safe_remote_kill_send/4,named_test),
           forall(retract(fault_alarm(A)),catch(remove_alarm(A),_,true)),
           node_controller:forget_remote_target(Pid),
           node_controller:remove_remote_monitor_by_pid(Pid),
           retractall(actors:monitor(_,Pid,_)),retractall(actors:link(_,Pid)),
           retractall(node_controller:remote_link_(_,Pid)),
           retractall(distribution:ws_pending_event(Node,Id,_)))),
        close_client_namespace(NS)),
      message_queue_destroy(Events)).

mock_spawn(Node, _, Id) :-
    mock_for_node(Node,Id,Action,Events),thread_send_message(Events,requested),
    distribution:record_named_request(Node,"test-request"),
    (Action=before_ack(Goal) -> call(Goal);true),
    (Action=throw_before(Error) -> throw(Error);true),
    (Action==no_ack_record -> true
    ;Action==uncorrelated
    -> distribution:record_named_ack(Node,_{},Id)
    ; distribution:record_named_ack(Node,_{request_id:"test-request"},Id)),
    (Action=after_ack(Goal) -> call(Goal);true).

mock_for_node(Node,Id,Action,Events) :-
    spawn_mock(Stored,Id,Action,Events),distribution:same_remote_node(Node,Stored).

invoke(toplevel,Name,Node,Pid) :- toplevel_spawn(Pid,[name(Name),node(Node),session(true),monitor(true)]).
invoke(server,Name,Node,Pid) :- server_spawn(callback,0,Pid,[name(Name),node(Node),monitor(true)]).
invoke(supervisor,Name,Node,Pid) :- supervisor_spawn([],Pid,[name(Name),node(Node),monitor(true)]).
invoke(statechart,Name,Node,Pid) :- statechart_spawn(Pid,[name(Name),node(Node),monitor(true),trace(false),
    src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>')]).
callback(get,State,State,State).

assert_no_startup(Pid,Name) :-
    whereis(Name,Found),assertion(Found==undefined),
    assertion(\+actors:spawn_name_reservation(_,_,Name,_,_,_)),
    Pid=Id@Node,assertion(\+distribution:remote_named_start(_,Node,_,_,_)),
    assertion(\+node_controller:current_remote_target(Pid,_)),
    assertion(\+actors:monitor(_,Pid,_)),assertion(\+actors:link(_,Pid)),
    assertion(\+distribution:ws_pending_event(Node,Id,_)).
assert_stopped(Events,Id) :- thread_get_message(Events,stopped(Id),[timeout(1)]).
interrupt_ack :-
    alarm(0.001,throw(named_start_interrupted),A,[]),assertz(fault_alarm(A)),sleep(0.02).

:- begin_tests(remote_named_creation).

test(occupied_name_sends_no_request,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    with_mock(ok,Name,_Pid,Events,
      (self(Self),register(Name,Self),
       catch(invoke(Kind,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error==name_is_in_use(Name)),whereis(Name,Found),assertion(Found==Self),
       assertion(\+thread_get_message(Events,requested,[timeout(0)])))).

test(named_generic_wrappers_preserve_spawn_admission_checks,
     [forall(member(Kind,[server,supervisor,statechart]))]) :-
    with_mock(ok,Name,Pid,Events,
      setup_call_cleanup(asserta(test_remote_named_creation:deny_named_spawn,Ref),
        (catch(invoke(Kind,Name,'http://named-startup.invalid:12345',_),Error,true),
         assertion(Error==named_admission_rejected),assert_no_startup(Pid,Name),
         assertion(\+thread_get_message(Events,requested,[timeout(0)]))),erase(Ref))).

test(all_remote_wrappers_publish_caller_alias,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    with_mock(ok,Name,Expected,_Events,
      (invoke(Kind,Name,'http://named-startup.invalid:12345',Pid),assertion(Pid==Expected),
       whereis(Name,Found),assertion(Found==Pid),
       assertion(\+actors:spawn_name_reservation(_,_,Name,_,_,_)))).

test(accepted_node_forms_retain_canonical_alias_semantics,
     [forall((member(Kind,[toplevel,server,supervisor,statechart]),
              member(Form,[string,trailing_slash])))]) :-
    with_mock(ok,Name,Expected,_Events,
      (Expected=_@Node,
       (Form==string -> atom_string(Node,Given);atom_concat(Node,'/',Given)),
       invoke(Kind,Name,Given,Created),whereis(Name,Found),assertion(Found==Expected),
       distribution:deliver_remote_down_via_controller(Created,_{reason:"normal"}),
       whereis(Name,After),assertion(After==undefined),demonitor(Created,[flush]))).

test(error_before_ack_releases_name_without_inventing_pid) :-
    with_mock(throw_before(named_transport_error),Name,Pid,Events,
      (catch(invoke(server,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error==named_transport_error),assert_no_startup(Pid,Name),
       assertion(\+thread_get_message(Events,stopped(_),[timeout(0)])))).

test(uncorrelated_peer_reply_rejected_without_claiming_ambiguous_pid,
     [forall(member(Action,[uncorrelated,no_ack_record]))]) :-
    with_mock(Action,Name,Pid,Events,
      (catch(invoke(toplevel,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error=error(remote_spawn_failed(uncorrelated_spawn_reply),_)),
       assert_no_startup(Pid,Name),
       assertion(\+thread_get_message(Events,stopped(_),[timeout(0)])))).

test(error_failure_or_interruption_after_ack_stops_known_pid,
     [forall((member(Kind,[toplevel,server,supervisor,statechart]),
              member(Action,[throw(named_setup_error),fail,interrupt_ack])))]) :-
    with_mock(after_ack(test_remote_named_creation:Action),Name,Pid,Events,
      (catch(invoke(Kind,Name,'http://named-startup.invalid:12345',_),Error,true),
       (Action=throw(Expected) -> assertion(Error==Expected)
       ;Action==fail -> assertion(Error=error(remote_spawn_failed(startup_failed),_))
       ;assertion(Error==named_start_interrupted)),
       Pid=Id@_,assert_stopped(Events,Id),assert_no_startup(Pid,Name))).

test(buffered_early_down_prevents_alias_publication,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    with_mock(before_ack(test_remote_named_creation:early_down),Name,Pid,Events,
      (catch(invoke(Kind,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error=error(remote_spawn_failed(terminated),_)),
       Pid=Id@_,assert_stopped(Events,Id),assert_no_startup(Pid,Name))).

test(connection_loss_before_or_after_ack_prevents_publication,
     [forall(member(When,[before_ack,after_ack]))]) :-
    Action=..[When,distribution:remote_ws_connection_closed('http://named-startup.invalid:12345')],
    with_mock(Action,Name,Pid,Events,
      (catch(invoke(toplevel,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error=error(remote_spawn_failed(connection_closed),_)),
       Pid=Id@_,assert_stopped(Events,Id),assert_no_startup(Pid,Name))).

test(namespace_close_during_startup_rejects_publication_and_stops_actor) :-
    with_mock(after_ack(test_remote_named_creation:close_current_namespace),Name,Pid,Events,
      (catch(invoke(supervisor,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error=error(permission_error(register,closed_namespace,_),_)),
       Pid=Id@_,assert_stopped(Events,Id),assert_no_startup(Pid,Name))).

test(pid_named_during_startup_preserves_one_name_per_pid_rule) :-
    with_mock(after_ack(test_remote_named_creation:name_current_remote_pid),Name,Pid,Events,
      (catch(invoke(server,Name,'http://named-startup.invalid:12345',_),Error,true),
       assertion(Error==process_already_has_a_name(Pid)),
       Pid=Id@_,assert_stopped(Events,Id),assert_no_startup(Pid,Name))).

test(publication_error_rolls_back_published_alias_and_routing) :-
    with_mock(ok,Name,Pid,Events,
      setup_call_cleanup(
        wrap_predicate(actors:publish_spawn_name(_,_,_),named_publish,W,
            (W,throw(named_publication_error))),
        (catch(invoke(server,Name,'http://named-startup.invalid:12345',_),Error,true),
         assertion(Error==named_publication_error),Pid=Id@_,assert_stopped(Events,Id),
         assert_no_startup(Pid,Name)),
        unwrap_predicate(actors:publish_spawn_name/3,named_publish))).

test(pending_name_is_hidden_and_prevents_competing_remote_creation,
     [forall(member(Mode,[complete,interrupt])),timeout(5)]) :-
    setup_call_cleanup(message_queue_create(Gate),
      with_mock(before_ack((thread_send_message(Events,pending),thread_get_message(Gate,go))),
        Name,Pid,Events,
        (current_public_execution_namespace(NS),Pid=Id@Node,
         thread_create(with_public_execution_namespace(NS,
           test_remote_named_creation:in_mock(Node,Id,
             before_ack((thread_send_message(Events,pending),thread_get_message(Gate,go))),Events,
             (catch((invoke(server,Name,Node,Created),Result=ok(Created)),
                    SpawnError,Result=error(SpawnError)),
              thread_send_message(Events,result(Result))))),Thread,[]),
         setup_call_cleanup(true,
           (thread_get_message(Events,pending,[timeout(2)]),
            whereis(Name,Hidden),assertion(Hidden==undefined),
            self(Self),catch(register(Name,Self),RegError,true),assertion(RegError==name_is_in_use(Name)),
            unregister(Name),catch(invoke(toplevel,Name,Node,_),Error,true),
            assertion(Error==name_is_in_use(Name)),
            thread_get_message(Events,requested,[timeout(0)]),
            assertion(\+thread_get_message(Events,requested,[timeout(0)])),
            (Mode==complete
            -> thread_send_message(Gate,go),thread_get_message(Events,result(ok(Created)),[timeout(2)]),
               assertion(Created==Pid),whereis(Name,Found),assertion(Found==Pid)
            ; thread_signal(Thread,throw(named_cancelled)),
              thread_get_message(Events,result(error(named_cancelled)),[timeout(2)]),
              assert_no_startup(Pid,Name),register(Name,Self),unregister(Name))),
           (thread_send_message(Gate,go),thread_join(Thread,_))))),
      message_queue_destroy(Gate)).

test(cleanup_error_does_not_replace_original_error) :-
    with_mock(after_ack(throw(named_original_error)),Name,Pid,_Events,
      setup_call_cleanup(
        wrap_predicate(distribution:safe_remote_kill_send(_,_,_,_),kill_failure,_W,
                       throw(named_kill_error)),
        (catch(invoke(server,Name,'http://named-startup.invalid:12345',_),Error,true),
         assertion(Error==named_original_error),assert_no_startup(Pid,Name)),
        unwrap_predicate(distribution:safe_remote_kill_send/4,kill_failure))).

test(cleanup_rejection_cannot_be_mistaken_for_next_spawn_reply) :-
    with_mock(after_ack(throw(named_setup_error)),Name,_Pid,Events,
      setup_call_cleanup(message_queue_create(Queue),
        (catch(invoke(server,Name,'http://named-startup.invalid:12345',_),Error,true),
         assertion(Error==named_setup_error),
         thread_get_message(Events,kill_command(Command),[timeout(1)]),
         get_dict(request_id,Command,CleanupId),
         distribution:remote_ws_dispatch('http://named-startup.invalid:12345',Queue,
              _{type:"error",data:"exit rejected",request_id:CleanupId}),
         thread_send_message(Queue,spawn_reply("next-spawn",spawned(123))),
         distribution:remote_wait_spawned(Queue,"next-spawn",Next),assertion(Next==123)),
        message_queue_destroy(Queue))).

test(publication_failure_preserves_unrelated_monitor_and_messages) :-
    with_mock(keep_monitor,Name,Pid,Events,
      setup_call_cleanup(
        wrap_predicate(actors:publish_spawn_name(_,_,_),extra_monitor,_W,
          (actors:monitor(Pid,Extra),thread_send_message(Events,extra(Extra)),
           actors:self(Self),actors:send(Self,named_unrelated),throw(named_publication_error))),
        (catch(invoke(server,Name,'http://named-startup.invalid:12345',_),Error,true),
         assertion(Error==named_publication_error),
         thread_get_message(Events,extra(Extra),[timeout(1)]),
         self(Self),assertion(actors:monitor(Self,Pid,Extra)),
         assertion(\+actors:monitor(Self,Pid,Pid)),
         receive({named_unrelated -> true},[timeout(0),on_timeout(fail)]),
         distribution:deliver_remote_down_via_controller(Pid,_{reason:"normal"}),
         receive({down(Pid,Extra,_) -> true},[timeout(1),on_timeout(fail)]),
         assert_no_startup(Pid,Name)),
        unwrap_predicate(actors:publish_spawn_name/3,extra_monitor))).

test(real_remote_wrappers_publish_and_retire_aliases,
     [forall(member(Kind,[toplevel,server,supervisor,statechart])),timeout(10)]) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
      (nb_getval(node_url_b,Node),gensym(real_remote_named_,Name),
       setup_call_cleanup(invoke(Kind,Name,Node,Pid),
         (whereis(Name,Found),assertion(Found==Pid),
          assertion(\+actors:spawn_name_reservation(_,_,Name,_,_,_)),
          exit(Pid,named_test_done),
          receive({down(Pid,Pid,named_test_done) -> true},[timeout(3),on_timeout(fail)]),
          whereis(Name,After),assertion(After==undefined)),
         (unregister(Name),exit(Pid,kill))))).

test(real_publication_failure_reclaims_remote_actor, [timeout(10)]) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
      (nb_getval(node_url_b,Node),gensym(real_remote_failed_name_,Name),
       setup_call_cleanup(
         wrap_predicate(actors:publish_spawn_name(_,_,_),remote_publish_failure,W,
           (distribution:remote_named_scope(_) -> throw(named_publication_error);W)),
         (catch(invoke(toplevel,Name,Node,_),Error,true),assertion(Error==named_publication_error),
          whereis(Name,Found),assertion(Found==undefined),
          wait_until(node_ws_actor_count(Node,0),3),assert_no_orphans(Node)),
         unwrap_predicate(actors:publish_spawn_name/3,remote_publish_failure)))).

test(early_down_buffer_handoff_cannot_miss_initial_flush, [timeout(5)]) :-
    setup_call_cleanup(message_queue_create(Gate),
      with_mock(ok,_Name,Pid,Events,
        (Pid=Id@Node,self(Self),actors:make_ref(Ref),
         setup_call_cleanup(
           (assertz(actors:monitor(Self,Pid,Ref)),node_controller:add_remote_monitor(Self,Pid,Ref),
            wrap_predicate(node_controller:current_remote_target(_,_),handoff,W,
              (test_remote_named_creation:pause_target_lookup(E,G)
              -> (W -> true;thread_send_message(E,no_target),thread_get_message(G,go),fail)
              ; W))),
           (thread_create((assertz(test_remote_named_creation:pause_target_lookup(Events,Gate)),
                           distribution:remote_ws_dispatch(Node,unused,
                               _{type:"down",pid:Id,reason:"normal"})),Reader,[]),
            setup_call_cleanup(true,
              (thread_get_message(Events,no_target,[timeout(2)]),
               thread_create((thread_send_message(Events,registering),
                              distribution:register_remote_pid(Pid,Self),
                              distribution:flush_pending_for_pid(Node,Id),
                              thread_send_message(Events,registered)),Registrar,[]),
               thread_get_message(Events,registering,[timeout(2)]),
               assertion(\+thread_get_message(Events,registered,[timeout(0.02)])),
               thread_send_message(Gate,go),thread_join(Registrar,RegStatus),assertion(RegStatus==true),
               receive({down(Pid,Ref,normal) -> true},[timeout(2),on_timeout(fail)]),
               assertion(\+distribution:ws_pending_event(Node,Id,_))),
              (thread_send_message(Gate,go),thread_join(Reader,_)))),
           (unwrap_predicate(node_controller:current_remote_target/2,handoff),demonitor(Ref,[flush]))))),
      message_queue_destroy(Gate)).

test(command_error_retains_request_id_after_unwinding) :-
    setup_call_cleanup(message_queue_create(Q),
      ( node_ws:ws_dispatch_frame('{"command":{},"request_id":"regression-ref"}', Q, anonymous, _{}),
        thread_get_message(Q, Reply, [timeout(1)]),
        assertion(Reply = spawn_reply("regression-ref",error(_))) ),
      message_queue_destroy(Q)).

test(legacy_command_error_remains_untagged) :-
    setup_call_cleanup(message_queue_create(Q),
      ( node_ws:ws_dispatch_frame('{"command":{}}', Q, anonymous, _{}),
        thread_get_message(Q, Reply, [timeout(1)]), assertion(Reply = error(_)) ),
      message_queue_destroy(Q)).

test(invalid_json_error_remains_untagged) :-
    setup_call_cleanup(message_queue_create(Q),
      ( node_ws:ws_dispatch_frame('{invalid', Q, anonymous, _{}),
        thread_get_message(Q, Reply, [timeout(1)]), assertion(Reply = error(_)) ),
      message_queue_destroy(Q)).

:- end_tests(remote_named_creation).

early_down :-
    spawn_mock(Node,Id,_,_),
    distribution:remote_ws_dispatch(Node,unused,_{type:"down",pid:Id,reason:"normal"}).
close_current_namespace :- current_public_execution_namespace(NS),close_client_namespace(NS).
name_current_remote_pid :- spawn_mock(Node,Id,_,_),register(already_named_remote,Id@Node).
