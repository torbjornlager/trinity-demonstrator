:- module(test_named_creation, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/isolation.pl', []).
:- use_module('../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../prolog/web_prolog/server_actor.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../prolog/web_prolog/statechart_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).

:- thread_local test_namespace/1, already_paused/0.
:- multifile actors:hook_namespace/1, actors:hook_spawn_option/3,
             actors:hook_admit_spawn/2, isolation:prepare_module/3.
actors:hook_namespace(NS) :- test_named_creation:test_namespace(NS).
actors:hook_spawn_option(name_test_pause, internal, error:must_be(nonvar)).
actors:hook_spawn_option(name_test_event, internal, error:must_be(nonvar)).
actors:hook_spawn_option(name_test_reject, internal, error:must_be(boolean)).
actors:hook_admit_spawn(_,Options) :-
    memberchk(name_test_reject(true),Options), throw(named_admission_rejected).
isolation:prepare_module(_,_,Options) :-
    (   memberchk(name_test_event(Q),Options) -> thread_send_message(Q,child_prepared) ; true),
    (   memberchk(name_test_pause(control(Events,Gate)),Options),
        \+ test_named_creation:already_paused
    ->  asserta(test_named_creation:already_paused), self(Pid),
        thread_send_message(Events,prepared(Pid)), thread_get_message(Gate,go)
    ;   true
    ).

:- meta_predicate with_namespace(+,0), with_actor(-,0), with_creator(+,-,-,-,0).
with_namespace(NS,Goal) :-
    setup_call_cleanup(asserta(test_namespace(NS),Ref),Goal,erase(Ref)).
with_actor(Pid,Goal) :-
    setup_call_cleanup(spawn(receive({}),Pid,[link(false)]),Goal,stop_actor(Pid)).
stop_actor(Pid) :-
    monitor(Pid,Ref),exit(Pid,true),
    receive({down(Pid,Ref,_)->true},[timeout(2),on_timeout(throw(missing_test_down))]).

callback(get,State,State,State).
invoke(toplevel,Name,Options,Pid) :- toplevel_spawn(Pid,[name(Name),session(true)|Options]).
invoke(server,Name,Options,Pid) :- server_spawn(callback,0,Pid,[name(Name)|Options]).
invoke(supervisor,Name,Options,Pid) :- supervisor_spawn([],Pid,[name(Name)|Options]).
invoke(statechart,Name,Options,Pid) :-
    statechart_spawn(Pid,[name(Name),trace(false),
        src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>')|Options]).

creator(Name,Events,Gate) :-
    catch((spawn_with_name((thread_send_message(Events,application_ran),receive({})),Pid,
                          [link(false),name_test_pause(control(Events,Gate))],[name(Name)]),
           Result=ok(Pid)),Error,Result=error(Error)),
    thread_send_message(Events,result(Result)).
with_creator(Name,Thread,Events,Gate,Goal) :-
    setup_call_cleanup(message_queue_create(Events),
      setup_call_cleanup(message_queue_create(Gate),
        setup_call_cleanup(thread_create(creator(Name,Events,Gate),Thread,[]),Goal,
            (thread_send_message(Gate,go),
             catch(thread_signal(Thread,throw(test_cleanup)),_,true),
             catch(thread_join(Thread,_),_,true))),
        message_queue_destroy(Gate)),
      message_queue_destroy(Events)).

:- begin_tests(named_creation).

test(occupied_name_does_not_start_any_wrapper,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    gensym(named_occupied_,Name),
    setup_call_cleanup(message_queue_create(Q),
        with_actor(Existing,
            (register(Name,Existing),
             catch(invoke(Kind,Name,[name_test_event(Q)],Pid),Error,true),
             assertion(Error==name_is_in_use(Name)),assertion(var(Pid)),
             assertion(\+thread_get_message(Q,_,[timeout(0)])),
             whereis(Name,Found),assertion(Found==Existing))),
        message_queue_destroy(Q)).
test(all_wrappers_publish_local_names,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    gensym(named_wrapper_,Name),
    setup_call_cleanup(invoke(Kind,Name,[],Pid),
                       (whereis(Name,Found),assertion(Found==Pid)),stop_actor(Pid)),
    whereis(Name,After),assertion(After==undefined).
test(name_available_to_application_goal) :-
    gensym(named_entry_,Name),self(Parent),
    spawn_with_name((self(Self),whereis(Name,Found),send(Parent,entry(Self,Found))),Pid,
                    [monitor(true)],[name(Name)]),
    receive({entry(Self,Found)->assertion(Self==Pid),assertion(Found==Pid)},
            [timeout(2),on_timeout(throw(missing_named_entry))]),
    receive({down(Pid,Pid,_)->true},[timeout(2),on_timeout(throw(missing_entry_down))]),
    whereis(Name,After),assertion(After==undefined).
test(immediate_exit_and_name_reuse) :-
    gensym(named_fast_,Name),
    forall(between(1,20,_),
        (spawn_with_name(true,Pid,[monitor(true)],[name(Name)]),
         receive({down(Pid,Pid,_)->true},[timeout(2),on_timeout(throw(missing_fast_down))]),
         whereis(Name,After),assertion(After==undefined))).
test(preparation_failure_releases_name_and_does_not_remove_replacement) :-
    gensym(named_failed_,Name),
    catch(server_spawn(callback,0,_,[name(Name),src_uri('/no-such-named-source')]),Error,true),
    assertion(nonvar(Error)),whereis(Name,Absent),assertion(Absent==undefined),
    setup_call_cleanup(invoke(server,Name,[],Pid),
        (server_request(Pid,get,Value),assertion(Value==0),whereis(Name,Found),assertion(Found==Pid)),
        stop_actor(Pid)).
test(admission_failure_releases_name) :-
    gensym(named_admission_,Name),
    catch(invoke(server,Name,[name_test_reject(true)],_),Error,true),
    assertion(Error==named_admission_rejected),
    setup_call_cleanup(invoke(server,Name,[],Pid),
                       (whereis(Name,Found),assertion(Found==Pid)),stop_actor(Pid)).
test(pending_reservation_hidden_and_respected_by_register) :-
    gensym(named_pending_,Name),
    with_creator(Name,_Thread,Events,Gate,
      (thread_get_message(Events,prepared(Child),[timeout(2)]),
       setup_call_cleanup(true,
        (whereis(Name,Hidden),assertion(Hidden==undefined),
         self(Self),catch(register(Name,Self),Error,true),assertion(Error==name_is_in_use(Name)),
         unregister(Name),
         catch(invoke(supervisor,Name,[],_),Again,true),assertion(Again==name_is_in_use(Name)),
         thread_send_message(Gate,go),thread_get_message(Events,result(ok(Pid)),[timeout(2)]),
         assertion(Pid==Child),whereis(Name,Found),assertion(Found==Pid)),
        stop_actor(Child)))).
test(concurrent_creators_one_wins) :-
    gensym(named_race_,Name),
    with_creator(Name,_T1,E1,G1,
      (thread_get_message(E1,prepared(Child),[timeout(2)]),
       setup_call_cleanup(true,
        with_creator(Name,_T2,E2,_G2,
          (thread_get_message(E2,result(Result),[timeout(2)]),
           assertion(Result==error(name_is_in_use(Name))),
           thread_send_message(G1,go),thread_get_message(E1,result(ok(Pid)),[timeout(2)]),
           assertion(Pid==Child))),stop_actor(Child)))).
test(cancellation_releases_pending_name_without_late_publication) :-
    gensym(named_cancel_,Name),
    with_creator(Name,Thread,Events,Gate,
      (thread_get_message(Events,prepared(Old),[timeout(2)]),
       setup_call_cleanup(true,
        (thread_signal(Thread,throw(cancelled_named_spawn)),
         thread_get_message(Events,result(Result),[timeout(2)]),
         assertion(Result==error(cancelled_named_spawn)),
         setup_call_cleanup(invoke(server,Name,[],New),
           (thread_send_message(Gate,go),
            stop_actor(Old),whereis(Name,Found),assertion(Found==New),
            assertion(\+thread_get_message(Events,application_ran,[timeout(0)]))),stop_actor(New))),
        stop_actor(Old)))).
test(namespace_isolation_and_cleanup) :-
    gensym(named_namespace_,Name),
    setup_call_cleanup(with_namespace(ns_one,invoke(server,Name,[],One)),
      setup_call_cleanup(with_namespace(ns_two,invoke(server,Name,[],Two)),
        (assertion(One\==Two),
         with_namespace(ns_one,(whereis(Name,A),assertion(A==One))),
         with_namespace(ns_two,(whereis(Name,B),assertion(B==Two))),
         whereis(Name,Hidden),assertion(Hidden==undefined)),stop_actor(Two)),stop_actor(One)),
    with_namespace(ns_one,(whereis(Name,End),assertion(End==undefined))).
test(explicit_unregister_and_rename_from_application_goal) :-
    gensym(named_old_,Old),gensym(named_new_,New),self(Parent),
    spawn_with_name((unregister(Old),self(Self),register(New,Self),send(Parent,renamed),receive({})),
                    Pid,[],[name(Old)]),
    setup_call_cleanup(true,
        (receive({renamed->true},[timeout(2),on_timeout(throw(missing_rename))]),
         whereis(Old,Absent),assertion(Absent==undefined),whereis(New,Found),assertion(Found==Pid)),
        stop_actor(Pid)).
test(register_rejects_retired_local_pid) :-
    gensym(register_retired_,Name),
    spawn(receive({}),Pid,[link(false)]),stop_actor(Pid),
    catch(register(Name,Pid),Error,true),
    assertion(nonvar(Error)),
    assertion(Error=error(existence_error(process,Pid),context(actors:register/2,_))),
    whereis(Name,Found),assertion(Found==undefined).
test(register_termination_race_leaves_no_binding) :-
    forall(between(1,30,_),
      (gensym(register_race_,Name),
       spawn(receive({}),Pid,[link(false)]),
       setup_call_cleanup(message_queue_create(Gate),
         setup_call_cleanup(
           thread_create((thread_get_message(Gate,go),
                          catch(register(Name,Pid),
                                error(existence_error(process,Pid),_),true)),Thread,[]),
           (thread_send_message(Gate,go),stop_actor(Pid),
            thread_join(Thread,Status),assertion(Status==true),
            whereis(Name,Found),assertion(Found==undefined)),
           (catch(thread_join(Thread,_),_,true),stop_actor(Pid))),
         message_queue_destroy(Gate)))).
test(register_stale_local_pid_in_other_namespaces) :-
    gensym(register_stale_ns_,Name),
    spawn(receive({}),Pid,[link(false)]),stop_actor(Pid),
    forall(member(NS,[register_ns_one,register_ns_two]),
      with_namespace(NS,
        (catch(register(Name,Pid),Error,true),
         assertion(nonvar(Error)),
         assertion(Error=error(existence_error(process,Pid),_)),
         whereis(Name,Found),assertion(Found==undefined)))).
test(register_local_pid_forms,
     [condition(current_predicate(pid_utils:canonical_pid/2))]) :-
    with_actor(Pid,
      (actors:pid_local(Pid,Local),
       term_string(Pid,String),term_to_atom(Pid,Atom),
       forall(member(Form,[Pid,Local,String,Atom]),
         (gensym(register_form_,Name),
          setup_call_cleanup(register(Name,Form),
            (whereis(Name,Found),assertion(Found==Pid)),unregister(Name)))),
       stop_actor(Pid),
       forall(member(Form,[Pid,Local,String,Atom]),
         (gensym(register_dead_form_,Name),catch(register(Name,Form),Error,true),
          assertion(nonvar(Error)),
         assertion(Error=error(existence_error(process,Form),_)))))).
test(register_remote_alias_still_unchecked) :-
    gensym(register_remote_,Name),Remote='@'(987654321,'http://remote.invalid:12345'),
    setup_call_cleanup(register(Name,Remote),
      (whereis(Name,Found),assertion(Found==Remote)),unregister(Name)).
test(register_main_still_supported) :-
    gensym(register_main_,Name),
    setup_call_cleanup(register(Name,main),
      (whereis(Name,Found),assertion(Found==main)),unregister(Name)).
test(plain_spawn_still_rejects_name,
     [throws(error(domain_error(spawn_option,name(test)),_))]) :- spawn(true,_,[name(test)]).

:- end_tests(named_creation).
