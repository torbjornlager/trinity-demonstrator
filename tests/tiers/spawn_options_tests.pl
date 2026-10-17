:- module(test_spawn_options, []).

:- use_module('../../prolog/web_prolog/actors.pl').
:- use_module(library(plunit)).
:- use_module(library(error)).

:- multifile actors:hook_spawn_option/3.
actors:hook_spawn_option(spawn_validation_test, public, error:must_be(integer)).

source_fact(a).

:- begin_tests(spawn_options).

test(unknown_option_before_dispatch,
     [forall(member(Option,[monitr(true),name(test),session(true),limit(1),
                           monitor,monitor(true,false),17]))]) :-
    catch(spawn(true,Pid,[node('http://127.0.0.1:1'),Option]),Error,true),
    assertion(Error=error(domain_error(spawn_option,Option),context(actors:spawn/3,_))),
    assertion(var(Pid)).
test(boolean_options,
     [forall(member(Option,[link(ture),monitor(yes),link(1),monitor(0)]))]) :-
    catch(spawn(true,Pid,[Option]),Error,true),
    assertion(Error=error(type_error(boolean,_),_)),assertion(var(Pid)).
test(variable_option_not_instantiated) :-
    catch(spawn(true,Pid,[Option]),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Option)),assertion(var(Pid)).
test(variable_values_not_instantiated,
     [forall(member(Option,[link(_),monitor(_),node(_),target(_),io_target(_)]))]) :-
    arg(1,Option,Value),catch(spawn(true,Pid,[Option]),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Value)),assertion(var(Pid)).
test(non_list, [throws(error(type_error(list,bad),_))]) :- spawn(true,_,bad).
test(partial_list) :-
    catch(spawn(true,Pid,[monitor(true)|Tail]),Error,true),
    assertion(Error=error(instantiation_error,_)),assertion(var(Tail)),assertion(var(Pid)).
test(invalid_node, [throws(error(type_error(atom_or_string,17),_))]) :-
    spawn(true,_,[node(17)]).
test(all_duplicates_validated, [throws(error(type_error(boolean,bad),_))]) :-
    spawn(true,_,[monitor(false),monitor(bad)]).
test(hook_extension) :-
    validate_spawn_options([spawn_validation_test(1)],public),
    catch(spawn(true,_,[spawn_validation_test(bad)]),Error,true),
    assertion(Error=error(type_error(integer,bad),_)).
test(internal_options_rejected_at_raw_boundary,
     [forall(member(Option,[monitor_target(main),monitor_ref(test_ref)]))]) :-
    catch(validate_spawn_options([Option],public),Error,true),
    assertion(Error=error(permission_error(option,internal_spawn_option,Option),_)).
test(preconfigured_monitor_preserved) :-
    self(Self),spawn(true,Pid,[link(false),monitor_target(Self),monitor_ref(test_ref)]),
    receive({down(Pid,test_ref,Reason)->assertion(Reason==true)},
            [timeout(2),on_timeout(throw(missing_preconfigured_monitor))]).
test(first_monitor_option_kept) :-
    spawn(true,Pid,[link(false),monitor(true),monitor(false)]),
    receive({down(Pid,Pid,Reason)->assertion(Reason==true)},
            [timeout(2),on_timeout(throw(missing_spawn_monitor))]).
test(rejection_has_no_child_effects) :-
    setup_call_cleanup(message_queue_create(Q),
        (catch(spawn(thread_send_message(Q,ran),Pid,[monitor(true),link(bad)]),Error,true),
         assertion(nonvar(Error)),assertion(var(Pid)),
         assertion(\+ thread_get_message(Q,_,[timeout(0)]))),
        message_queue_destroy(Q)).

:- end_tests(spawn_options).

% Loaded with isolation in T1/T4; not run in the stand-alone actor tier.
:- begin_tests(spawn_source_options).

test(invalid_source_before_preparation,
     [forall(member(Option,[src_text(17),src_list(bad),src_uri(17),
                           src_predicates([p]),src_predicates([p/(-1)])]))]) :-
    catch(spawn(true,Pid,[src_uri('/no-such-spawn-source'),Option]),Error,true),
    assertion(Error=error(_,context(actors:spawn/3,_))),assertion(var(Pid)).
test(unknown_after_source_before_fetch) :-
    catch(spawn(true,Pid,[src_uri('/no-such-spawn-source'),typo(1)]),Error,true),
    assertion(Error=error(domain_error(spawn_option,typo(1)),_)),assertion(var(Pid)).
test(source_variables_preserved) :-
    Options=[src_list([same(X,X)]),src_predicates([source_fact/0])],
    validate_spawn_options(Options,runtime),assertion(var(X)),
    Options=[src_list([same(A,B)])|_],assertion(A==B).
test(native_text_representations,
     [forall(member(Text,['p.',"p.",[112,46],[p,'.']]))]) :-
    validate_spawn_options([src_text(Text)],public).
test(internal_isolation_options,
     [forall(member(Option,[source_module(test_spawn_options),
                           inherit_goal_module(false),isolation_io(generated)]))]) :-
    validate_spawn_options([Option],runtime),
    catch(validate_spawn_options([Option],public),Error,true),
    assertion(Error=error(permission_error(option,internal_spawn_option,Option),_)).
test(invalid_isolation_metadata,
     [forall(member(Option,[source_module(17),inherit_goal_module(bad),isolation_io(bad)]))]) :-
    catch(spawn(true,Pid,[Option]),Error,true),assertion(nonvar(Error)),assertion(var(Pid)).
test(source_order_and_monitoring) :-
    self(Self),
    spawn((findall(X,spawn_option_fact(X),Xs),send(Self,spawn_source_data(Xs))),Pid,
          [link(false),monitor(true),
           src_text(':- multifile spawn_option_fact/1. spawn_option_fact(a).'),
           src_list([spawn_option_fact(b)])]),
    receive({spawn_source_data(Data)->assertion(Data==[a,b])},
            [timeout(2),on_timeout(throw(missing_source_answer))]),
    receive({down(Pid,Pid,Reason)->assertion(Reason==true)},
            [timeout(2),on_timeout(throw(missing_source_down))]).
test(framework_source_metadata_preserved) :-
    self(Self),
    spawn((source_fact(X),send(Self,spawn_metadata_data(X))),Pid,
          [link(false),monitor(true),source_module(test_spawn_options),
           inherit_goal_module(false),isolation_io(generated),
           src_predicates([source_fact/1])]),
    receive({spawn_metadata_data(Data)->assertion(Data==a)},
            [timeout(2),on_timeout(throw(missing_metadata_answer))]),
    receive({down(Pid,Pid,Reason)->assertion(Reason==true)},
            [timeout(2),on_timeout(throw(missing_metadata_down))]).

:- end_tests(spawn_source_options).
