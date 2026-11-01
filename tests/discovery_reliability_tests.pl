:- module(discovery_reliability_tests, [run/0]).

:- ['../load.pl'].
:- use_module(library(web_prolog)).
:- use_module('../examples/services/discovery_hub.pl', []).
:- use_module(library(plunit)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).

:- dynamic probe_queue/1, node_record_gen/3, current_gen/1.
:- http_handler(root('reliability/node_info'), probe_info, []).
:- http_handler(root('reliability/readyz'), probe_ready, []).

probe_info(_) :-
    probe_queue(Queue),
    thread_send_message(Queue, probed),
    reply_json_dict(_{profile:actor, auth:open, services:[], provides:[]}).

probe_ready(_) :-
    sleep(0.3),
    reply_json_dict(_{ready:true}).

fixture(Port, Queue, URL) :-
    message_queue_create(Queue),
    assertz(probe_queue(Queue)),
    http_server(http_dispatch, [port(Port), workers(2)]),
    format(atom(URL), 'http://localhost:~d/reliability', [Port]).

cleanup(Port, Queue) :-
    http_stop_server(Port, []),
    retractall(probe_queue(_)),
    message_queue_destroy(Queue),
    retractall(node_record_gen(_, _, _)),
    retractall(current_gen(_)).

busy_registry(URL, Queue) :-
    Node = node{id:peer, url:URL, probe_url:URL, last_seen:0, last_error:0},
    State = hub{module:discovery_reliability_tests, gen:0, nodes:[Node]},
    get_time(Now), Deadline is Now + 0.15,
    self(Me),
    setup_call_cleanup(
        spawn(discovery_hub:registry_actor(State, Deadline), Registry, [link(false)]),
        ( forall(between(1, 25, _),
                 ( Registry ! nodes(Me),
                   receive({nodes(_) -> true},
                           [timeout(1), on_timeout(throw(registry_unresponsive))]),
                   sleep(0.02) )),
          thread_get_message(Queue, probed, [timeout(0.2)]) ),
        exit(Registry, kill)).

run :- run_tests(discovery_reliability).

:- begin_tests(discovery_reliability).

% The old loop restarted its 30s wait on each nodes/1 request and would
% never probe during this exchange. The first sweep is due after 150ms.
test(busy_mailbox_cannot_postpone_sweep) :-
    setup_call_cleanup(
        discovery_reliability_tests:fixture(Port, Queue, URL),
        discovery_reliability_tests:busy_registry(URL, Queue),
        discovery_reliability_tests:cleanup(Port, Queue)).

test(late_sweep_skips_ticks_without_changing_cadence,
     [Sweep, Deadline, Wait] == [true, 220, 25]) :-
    discovery_hub:sweep_schedule(195, 100, Sweep, Deadline, Wait).

test(readiness_delay_is_excluded_from_node_info_latency) :-
    setup_call_cleanup(
        discovery_reliability_tests:fixture(Port, Queue, URL),
        ( get_time(Start),
          discovery_hub:fetch_info(URL, Info, Latency),
          get_time(End),
          ElapsedMs is (End - Start) * 1000,
          assertion(Info.maintenance == false),
          assertion(ElapsedMs >= 300),
          assertion(Latency < ElapsedMs - 250) ),
        discovery_reliability_tests:cleanup(Port, Queue)).

:- end_tests(discovery_reliability).
