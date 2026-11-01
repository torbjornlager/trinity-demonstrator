:- module(demonstrator_integration_tests, [run/0]).

/* Consumer contracts for the actual owner-installed example services.
   Runtime/protocol semantics are tested by the pinned upstream tiers. */
:- ['../load.pl'].
:- use_module('../examples/services/node_resident_services.pl').
:- use_module(library(web_prolog)).
:- use_module(library(plunit)).
:- use_module(library(socket)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).

:- dynamic example_node/2.

start_examples :-
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    start_service_demo_node(Port),
    format(atom(URL), 'http://localhost:~d', [Port]),
    assertz(example_node(Port, URL)).

stop_examples :-
    stop_example_services,
    forall(retract(example_node(Port, _)), http_stop_server(Port, [])).

counter_value(URL, Value) :-
    self(Me),
    send(counter@URL, count(Me)),
    receive({count(Value) -> true}, [timeout(2), on_timeout(fail)]).

run :- run_tests(demonstrator_examples).

:- begin_tests(demonstrator_examples,
               [setup(start_examples), cleanup(stop_examples)]).

% Keep the demonstrator's exact catalogue contract here. Upstream checks
% discovery against whichever directory an external asset owner supplies.
test(catalogue_lists_the_three_demonstrator_services,
     Sorted == [counter-meta(actor, protocol(count_v1)),
                linda-meta(actor, protocol(linda_v1)),
                pubsub_service-meta(actor, protocol(pubsub_v1))]) :-
    example_node(_, URL),
    findall(Name-Meta, rpc(URL, service(Name, Meta)), Services),
    sort(Services, Sorted).

test(bootstrap_publishes_every_advertised_service) :-
    example_node(_, URL),
    atom_concat(URL, '/node_info', InfoURL),
    setup_call_cleanup(http_open(InfoURL, Stream, [timeout(5)]),
                       json_read_dict(Stream, Info), close(Stream)),
    sort(Info.services, Services),
    assertion(Services == ["counter", "linda", "pubsub_service"]).

test(counter_state_survives_separate_client_calls, [First, Second] == [1, 2]) :-
    example_node(_, URL),
    counter_value(URL, First),
    counter_value(URL, Second).

test(pubsub_example_delivers_published_messages, Message == hello) :-
    example_node(_, URL),
    self(Me),
    send(pubsub_service@URL, subscribe(Me)),
    send(pubsub_service@URL, publish(hello)),
    receive({msg(Message) -> true}, [timeout(2), on_timeout(fail)]).

test(bootstrap_loads_the_owner_linda_client, Value == shared) :-
    example_node(_, URL),
    rpc(URL, (linda_out(ticket(shared)), linda_in(ticket(Value)))).

:- end_tests(demonstrator_examples).
