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
    reply_json_dict(_{profile:actor, auth:open, services:[], provides:[],
                      implementation:"SWI-Prolog", version:"10.1.19",
                      description:"  A test\n   node.  "}).

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

% Everything a card shows about a node is harvested from its /node_info,
% with whitespace collapsed; nothing comes from the seed.
test(node_reported_fields_are_harvested,
     [Impl, Ver, Desc] == ['SWI-Prolog', "10.1.19", "A test node."]) :-
    setup_call_cleanup(
        discovery_reliability_tests:fixture(Port, Queue, URL),
        ( discovery_hub:fetch_info(URL, Info, Latency),
          discovery_hub:apply_outcome(ok(Info, Latency), 1,
              node{id:peer, url:URL, implementation:'', version:"",
                   description:""}, Node),
          Impl = Node.implementation, Ver = Node.version,
          Desc = Node.description ),
        discovery_reliability_tests:cleanup(Port, Queue)).

test(long_or_missing_node_text_is_bounded,
     [Short, Empty] == ["abcdefghi…", ""]) :-
    discovery_hub:info_text(description, _{description:"abcdefghijklmnop"},
                            10, Short),
    discovery_hub:info_text(description, _{description:null}, 10, Empty).

% The production seeds hold addresses only; the hub adds its own row.
test(production_seeds_hold_addresses_only,
     [cleanup(discovery_hub:clear_seed)]) :-
    forall(member(File, ['Deployment/discovery-seed.coexist.pl',
                         'Deployment/discovery-seed.elfenbenstornet.pl',
                         'Deployment/discovery-seed.n6-local.pl']),
           ( discovery_hub:load_seed_file(File),
             discovery_hub:read_seed_terms(File, Terms),
             assertion(forall(member(T, Terms),
                              ( T = seed_node(_, _) ; T = seed_probe_url(_, _) ))) )),
    discovery_hub:load_seed_file('Deployment/discovery-seed.coexist.pl'),
    discovery_hub:ensure_seed('http://localhost'),
    findall(Id, discovery_hub:seed_node(Id, _), Ids0),
    sort(Ids0, Ids),
    assertion(Ids == [n0, n1, n2, n3, n4, n5, n6, n7]),
    forall(discovery_hub:seed_to_node(Node),
           ( assertion(Node.implementation == ''),
             assertion(Node.description == "") )).

% An older seed still loads; its prose and labels are dropped.
test(legacy_seed_terms_keep_only_the_address,
     [Url-Desc == 'https://old.example'-"",
      cleanup(discovery_hub:clear_seed)]) :-
    discovery_hub:set_seed([seed_node(old, 'https://old.example',
                                      "hub prose", "db prose", "note"),
                            seed_implementation(old, 'Some Prolog')]),
    discovery_hub:seed_to_node(Node),
    Url = Node.url, Desc = Node.description.

:- end_tests(discovery_reliability).
