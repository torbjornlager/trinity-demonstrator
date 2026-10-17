:- module(test_supervisor_child_specs, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../prolog/web_prolog/server_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).

forever :- receive({}).
callback(Shared,get,State,seen(Shared,State),State).

:- meta_predicate with_supervisor(+,-,0).
with_supervisor(Specs,Sup,Goal) :-
    setup_call_cleanup(supervisor_spawn(Specs,Sup,[monitor(true)]),
        (supervisor_count_children(Sup,_),Goal),
        (exit(Sup,true),receive({down(Sup,Sup,_)->true},
                              [timeout(2),on_timeout(throw(missing_supervisor_down))]))).

:- begin_tests(supervisor_child_specs).

test(non_list, [throws(error(type_error(list,bad),_))]) :- supervisor_spawn(bad,_).
test(variable_spec_not_instantiated) :-
    catch(supervisor_spawn([Spec],Pid),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Spec)),assertion(var(Pid)).
test(partial_list) :-
    catch(supervisor_spawn([child(a,[start(true)])|Tail],Pid),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Tail)),assertion(var(Pid)).
test(malformed_spec,
     [forall(member(Spec,[wrong(a,[]),child(a),child(a,[],extra),17]))]) :-
    catch(supervisor_spawn([Spec],Pid),Error,true),
    assertion(Error=error(type_error(supervisor_child_spec,Spec),_)),assertion(var(Pid)).
test(non_ground_id) :-
    catch(supervisor_spawn([child(worker(X),[start(true)])],Pid),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(X)),assertion(var(Pid)).
test(unknown_child_options,
     [forall(member(Option,[restarts(permanent),limit(1),start,start(true,false)]))]) :-
    catch(supervisor_spawn([child(a,[start(true),Option])],Pid),Error,true),
    assertion(Error=error(domain_error(supervisor_child_option,Option),_)),assertion(var(Pid)).
test(missing_start_preserved, [throws(error(missing_start_option(a),supervisor))]) :-
    supervisor_spawn([child(a,[])],_).
test(bad_values,
     [forall(member(Option,[start(17),restart(unknown),type(unknown),shutdown(-1),shutdown(bad)]))]) :-
    catch(supervisor_spawn([child(a,[Option,start(true)])],Pid),Error,true),
    assertion(nonvar(Error)),assertion(var(Pid)).
test(unbound_values_not_instantiated,
     [forall(member(Name,[start,restart,type,shutdown]))]) :-
    Option=..[Name,Value],
    catch(supervisor_spawn([child(a,[Option,start(true)])],Pid),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Value)),assertion(var(Pid)).
test(module_qualifications,
     [forall(member(Start,[17:true,_:true,test_supervisor_child_specs:_]))]) :-
    catch(supervisor_spawn([child(a,[start(Start)])],Pid),Error,true),
    assertion(nonvar(Error)),assertion(var(Pid)).
test(defaults) :-
    supervisor_actor:normalise_child_spec(test_supervisor_child_specs,
        child(a,[start(forever)]),Worker),
    assertion(Worker==spec(a,test_supervisor_child_specs:forever,permanent,5,worker)),
    supervisor_actor:normalise_child_spec(test_supervisor_child_specs,
        child(a,[start(forever),type(supervisor)]),Supervisor),
    assertion(Supervisor==spec(a,test_supervisor_child_specs:forever,permanent,infinity,supervisor)).
test(first_occurrence_kept) :-
    supervisor_actor:normalise_child_spec(test_supervisor_child_specs,
        child(a,[start(forever),start(fail),restart(temporary),restart(permanent),
                 type(worker),type(supervisor),shutdown(0),shutdown(brutal_kill)]),Spec),
    assertion(Spec==spec(a,test_supervisor_child_specs:forever,temporary,0,worker)).
test(all_occurrences_validated, [throws(error(_,_))]) :-
    supervisor_spawn([child(a,[start(true),restart(temporary),restart(bad)])],_).
test(accepted_shutdown_values,
     [forall(member(Value,[brutal_kill,infinity,0,0.25,5]))]) :-
    supervisor_actor:normalise_child_spec(test_supervisor_child_specs,
        child(a,[start(forever),shutdown(Value)]),spec(a,_,_,Value,_)).
test(goal_availability_not_checked_and_variables_shared) :-
    supervisor_actor:normalise_child_spec(test_supervisor_child_specs,
        child(a,[start(not_defined(X,X))]),spec(a,Goal,_,_,_)),
    assertion(Goal==test_supervisor_child_specs:not_defined(X,X)),assertion(var(X)).
test(duplicates_rejected_before_any_child_starts) :-
    setup_call_cleanup(message_queue_create(Q),
        (catch(supervisor_spawn(
            [child(worker(1),[start(thread_send_message(Q,ran))]),
             child(worker(1),[start(true)])],Pid),Error,true),
         assertion(Error=error(permission_error(duplicate,supervisor_child_id,worker(1)),_)),
         assertion(var(Pid)),assertion(\+thread_get_message(Q,_,[timeout(0)]))),
        message_queue_destroy(Q)).
test(malformed_later_child_before_any_child_starts) :-
    setup_call_cleanup(message_queue_create(Q),
        (catch(supervisor_spawn(
            [child(first,[start(thread_send_message(Q,ran))]),
             child(second,[start(true),restart(bad)])],Pid),Error,true),
         assertion(nonvar(Error)),assertion(var(Pid)),
         assertion(\+thread_get_message(Q,_,[timeout(0)]))),
        message_queue_destroy(Q)).
test(server_id_must_be_atom, [throws(error(type_error(atom,worker(1)),_))]) :-
    supervisor_spawn([child(worker(1),[start(server(callback(_),[]))])],_).
test(server_contents_checked_before_start,
     [forall(member(Start,[server(17,[]),server(_ ,[]),server(callback(_),bad),
                           server(callback(_),[initial_state(_),typo(1)]),
                           server(callback(_),[name(17)]),
                           server(callback(_),[src_uri('/no-such-child-source'),link(bad)])]))]) :-
    catch(supervisor_spawn([child(server_name,[start(Start)])],Pid),Error,true),
    assertion(nonvar(Error)),assertion(var(Pid)).
test(server_state_and_callback_sharing_preserved) :-
    gensym(child_spec_server_,Id),
    with_supervisor([child(Id,[start(server(callback(X),[initial_state(state(X,X))]))])],Sup,
        (supervisor_which_children(Sup,[info(Id,Pid,worker,permanent)]),
         server_request(Pid,get,seen(A,state(B,C))),
         assertion(var(A)),assertion(A==B),assertion(B==C),assertion(var(X)))).
test(nested_contents_checked_before_parent_start,
     [forall(member(Start,
        [start_sub_supervisor([child(x,[start(true),unknown(1)])],[]),
         start_sub_supervisor([], [strategy(bad)]),
         supervisor_actor:start_sub_supervisor([child(x,[start(true)]),child(x,[start(true)])],[])]))]) :-
    catch(supervisor_spawn([child(nested,[start(Start),type(supervisor)])],Pid),Error,true),
    assertion(nonvar(Error)),assertion(var(Pid)).
test(qualified_nested_lists_and_sharing_preserved) :-
    Children=[child(inner,[start(not_defined(X,X))])],
    Input=supervisor_actor:start_sub_supervisor(user:(test_supervisor_child_specs:Children),[]),
    supervisor_actor:normalise_child_spec(test_supervisor_child_specs,
        child(outer,[start(Input),type(supervisor)]),spec(outer,Start,_,_,_)),
    assertion(Start==Input),assertion(var(X)).
test(cyclic_specification_rejected, [throws(error(representation_error(cyclic_term),_))]) :-
    Spec=child(nested,[start(start_sub_supervisor([Spec],[]))]),supervisor_spawn([Spec],_).
test(dynamic_invalid_spec_does_not_change_supervisor) :-
    with_supervisor([],Sup,
        (catch(supervisor_spawn_child(Sup,child(worker(1),[start(forever),restart(bad)]),_),Error,true),
         assertion(nonvar(Error)),supervisor_which_children(Sup,Children),assertion(Children==[]),
         supervisor_spawn_child(Sup,child(worker(1),[start(forever)]),Reply),assertion(Reply==ok),
         supervisor_spawn_child(Sup,child(worker(1),[start(forever)]),Duplicate),
         assertion(Duplicate==error(already_present)),
         supervisor_which_children(Sup,[info(worker(1),_,worker,permanent)]))).
test(dynamic_rejected_before_contact,
     [throws(error(domain_error(supervisor_child_option,typo(1)),_))]) :-
    supervisor_spawn_child(nonexistent,child(a,[start(true),typo(1)]),_).
test(compound_ids_and_initial_order_preserved) :-
    with_supervisor([child(worker(2),[start(forever)]),child(worker(1),[start(forever)])],Sup,
        (supervisor_which_children(Sup,Children),
         assertion(Children=[info(worker(2),_,worker,permanent),info(worker(1),_,worker,permanent)]))).

:- end_tests(supervisor_child_specs).
