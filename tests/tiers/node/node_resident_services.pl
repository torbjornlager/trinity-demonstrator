:- module(node_resident_services, [
    service_directory_file/1,
    service_directory_options/1,
    start_service_demo_node/1,
    start_service_demo_node/3,
    start_counter_service/1,
    start_pubsub_service/1,
    start_example_services/2,
    stop_service/1,
    stop_example_services/0,
    count_actor/1,
    pubsub_actor/1
]).

:- use_module('../../../prolog/web_prolog/actor_api.pl', [
    spawn/3,
    register_service/2,
    unregister_service/1,
    whereis_service/2,
    exit/2,
    receive/1,
    (!)/2,
    op(800, xfx, !),
    op(200, xfx, @),
    op(1000, xfy, if)
]).
:- use_module('../../../prolog/web_prolog/node.pl', [node/2]).
:- use_module(library(http/thread_httpd), [http_stop_server/2]).
:- use_module(library(lists), [select/3]).

:- dynamic service_examples_directory/1.
%  This adapted copy lives in tests/tiers/node/; the service data
%  files stayed in examples/services/ at the repository root.
:- prolog_load_context(directory, NodeTierDir),
   file_directory_name(NodeTierDir, TiersDir),
   file_directory_name(TiersDir, TestsDir),
   file_directory_name(TestsDir, RepoDir),
   directory_file_path(RepoDir, 'examples/services', ServiceExamplesDirectory),
   asserta(service_examples_directory(ServiceExamplesDirectory)).


service_directory_file(File) :-
    service_examples_directory(Dir),
    directory_file_path(Dir, 'service_directory.pl', File).


service_directory_options([load_shared_db_file(File)]) :-
    service_directory_file(File).


start_service_demo_node(Port) :-
    start_service_demo_node(Port, _CounterPid, _PubSubPid).


start_service_demo_node(Port, CounterPid, PubSubPid) :-
    service_directory_options(Options),
    node(Port, [profile(actor)|Options]),
    catch(
        start_example_services(CounterPid, PubSubPid),
        Error,
        (
            catch(stop_example_services, _, true),
            catch(http_stop_server(Port, []), _, true),
            throw(Error)
        )
    ).


start_counter_service(Pid) :-
    start_named_service(counter, count_actor(0), Pid).


start_pubsub_service(Pid) :-
    start_named_service(pubsub_service, pubsub_actor([]), Pid).


start_example_services(CounterPid, PubSubPid) :-
    start_counter_service(CounterPid),
    start_pubsub_service(PubSubPid).


stop_example_services :-
    stop_service(counter),
    stop_service(pubsub_service).


stop_service(Name) :-
    (   whereis_service(Name, Pid),
        Pid \== undefined
    ->  catch(exit(Pid, kill), _, true),
        catch(unregister_service(Name), _, true)
    ;   catch(unregister_service(Name), _, true)
    ).


start_named_service(Name, Goal, Pid) :-
    stop_service(Name),
    spawn(Goal, Pid, [link(false)]),
    register_service(Name, Pid).


count_actor(Count0) :-
    receive({
        count(From) ->
            Count is Count0 + 1,
            From ! count(Count),
            count_actor(Count) ;
        stop ->
            true
    }).


pubsub_actor(Subscribers0) :-
    receive({
        publish(Msg) ->
            forall(member(Pid, Subscribers0), Pid ! msg(Msg)),
            pubsub_actor(Subscribers0) ;
        subscribe(Pid) ->
            pubsub_actor([Pid|Subscribers0]) ;
        unsubscribe(Pid) ->
            (   select(Pid, Subscribers0, Subscribers)
            ->  pubsub_actor(Subscribers)
            ;   pubsub_actor(Subscribers0)
            )
    }).
