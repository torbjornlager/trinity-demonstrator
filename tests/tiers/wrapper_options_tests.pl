:- module(test_wrapper_options, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module('../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../prolog/web_prolog/server_actor.pl').
:- use_module('../../prolog/web_prolog/supervisor_actor.pl').
:- use_module('../../prolog/web_prolog/statechart_actor.pl').
:- use_module(library(plunit)).
:- use_module(library(gensym)).

callback(get, State, State, State).

invoke(toplevel, Options, Pid) :- toplevel_spawn(Pid, Options).
invoke(server, Options, Pid) :- server_spawn(callback,0,Pid,Options).
invoke(supervisor, Options, Pid) :- supervisor_spawn([],Pid,Options).
invoke(statechart, Options, Pid) :- statechart_spawn(Pid,Options).

wrapper_pi(toplevel,toplevel_actors:toplevel_spawn/2).
wrapper_pi(server,server_actor:server_spawn/4).
wrapper_pi(supervisor,supervisor_actor:supervisor_spawn/3).
wrapper_pi(statechart,statechart_actor:statechart_spawn/2).

:- meta_predicate with_wrapper(+,+,-,0).
with_wrapper(Kind,Options,Pid,Goal) :-
    (   Kind == statechart
    ->  All=[trace(false),src_text('<statechart version="0.2" initial="s"><state id="s"/></statechart>')|Options]
    ;   All=Options
    ),
    setup_call_cleanup(invoke(Kind,[monitor(true)|All],Pid), Goal,
        (exit(Pid,true),receive({down(Pid,Pid,_)->true},
                               [timeout(2),on_timeout(throw(missing_wrapper_down))]))).

:- begin_tests(wrapper_options).

test(unknown_options_before_source_or_dispatch,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    wrapper_pi(Kind,PI),
    catch(invoke(Kind,[node('http://127.0.0.1:1'),src_uri('/no-such-wrapper-source'),typo(1)],Pid),Error,true),
    assertion(Error=error(domain_error(spawn_option,typo(1)),context(PI,_))),
    assertion(var(Pid)).
test(non_list,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    catch(invoke(Kind,bad,Pid),Error,true),
    assertion(Error=error(type_error(list,bad),_)),assertion(var(Pid)).
test(variable_option_preserved,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    catch(invoke(Kind,[Option],Pid),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Option)),assertion(var(Pid)).
test(name_checked_before_creation,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    catch(invoke(Kind,[name(17)],Pid),Error,true),
    assertion(Error=error(type_error(atom,17),_)),assertion(var(Pid)).
test(unbound_name_not_bound,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    catch(invoke(Kind,[name(Name)],Pid),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Name)),assertion(var(Pid)).
test(forwarded_options_checked_before_creation,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    catch(invoke(Kind,[monitor(ture)],Pid),Error,true),
    assertion(Error=error(type_error(boolean,ture),_)),assertion(var(Pid)).
test(wrapper_names_do_not_leak_into_spawn,
     [forall(member(Option,[name(n),session(true),time_limit(1),idle_limit(1),
                           strategy(one_for_one),intensity(1),period(1),trace(false)]))]) :-
    catch(spawn(true,_,[Option]),Error,true),
    assertion(Error=error(domain_error(spawn_option,Option),_)).
test(misplaced_wrapper_options,
     [forall(member(Kind-Option,[server-session(true),toplevel-strategy(one_for_one),
                               supervisor-trace(false),statechart-period(1)]))]) :-
    catch(invoke(Kind,[Option],Pid),Error,true),
    assertion(Error=error(domain_error(spawn_option,Option),_)),assertion(var(Pid)).
test(all_duplicate_values_checked,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    catch(invoke(Kind,[name(valid),name(17)],Pid),Error,true),
    assertion(Error=error(type_error(atom,17),_)),assertion(var(Pid)).
test(valid_named_wrappers_and_first_occurrence,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    gensym(wrapper_validation_,Name),gensym(wrapper_unused_,Other),
    with_wrapper(Kind,[name(Name),name(Other)],Pid,
        (whereis(Name,Named),assertion(Named==Pid),
         whereis(Other,Unused),assertion(Unused==undefined))).
test(framework_metadata_preserved,
     [forall(member(Kind,[toplevel,server,supervisor,statechart]))]) :-
    with_wrapper(Kind,[source_module(test_wrapper_options),
                      inherit_goal_module(false),isolation_io(generated)],_Pid,true).
test(toplevel_invalid_own_options,
     [forall(member(Option,[session(maybe),time_limit(0),time_limit(-1),
                           idle_limit(0),idle_limit(bad)]))]) :-
    catch(toplevel_spawn(Pid,[Option]),Error,true),assertion(nonvar(Error)),assertion(var(Pid)).
test(toplevel_unbound_limit_not_bound) :-
    catch(toplevel_spawn(Pid,[time_limit(Limit)]),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Limit)),assertion(var(Pid)).
test(toplevel_defaults_and_limits) :-
    with_wrapper(toplevel,[session(true),time_limit(0.5),idle_limit(infinite)],Pid,
        (toplevel_call_synch(Pid,true,A,[timeout(2)]),assertion(A==success(Pid,[true],false)),
         toplevel_call_synch(Pid,true,B,[timeout(2)]),assertion(B==success(Pid,[true],false)))).
test(server_callback_still_works) :-
    with_wrapper(server,[],Pid,(server_request(Pid,get,Value),assertion(Value==0))).
test(supervisor_invalid_settings,
     [forall(member(Option,[strategy(unknown),intensity(-1),intensity(1.5),
                           period(0),period(-1),period(bad)]))]) :-
    catch(supervisor_spawn([],Pid,[Option]),Error,true),assertion(nonvar(Error)),assertion(var(Pid)).
test(supervisor_supported_strategies_and_numeric_period,
     [forall(member(Strategy,[one_for_one,one_for_all,rest_for_one]))]) :-
    with_wrapper(supervisor,[strategy(Strategy),intensity(0),period(0.5)],Pid,
        (supervisor_count_children(Pid,Counts),assertion(memberchk(active-0,Counts)))).
test(supervisor_invalid_name_does_not_start_children) :-
    setup_call_cleanup(message_queue_create(Q),
        (catch(supervisor_spawn([child(test,[start(thread_send_message(Q,ran))])],Pid,[name(17)]),Error,true),
         assertion(Error=error(type_error(atom,17),_)),assertion(var(Pid)),
         assertion(\+thread_get_message(Q,_,[timeout(0)]))),
        message_queue_destroy(Q)).
test(statechart_duplicate_trace_preserved,
     [throws(error(permission_error(duplicate,statechart_option,trace),_))]) :-
    statechart_spawn(_,[trace(false),trace(true)]).
test(statechart_missing_source_preserved,
     [throws(error(existence_error(option,src_uri_or_src_text),_))]) :- statechart_spawn(_,[]).
test(statechart_multiple_sources_preserved,
     [throws(error(domain_error(single_statechart_source_option,_),_))]) :-
    statechart_spawn(_,[src_text('one'),src_text('two')]).
test(statechart_unbound_trace_not_bound) :-
    catch(statechart_spawn(Pid,[trace(Trace)]),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Trace)),assertion(var(Pid)).

:- end_tests(wrapper_options).
