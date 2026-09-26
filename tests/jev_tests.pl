:- ['../load.pl'].

:- use_module('../examples/jev/jev_http').
:- use_module('../examples/jev/jev').
:- use_module('../examples/jev/deployment_observation').
:- use_module('../examples/jev/jev_actor').
:- use_module('../examples/jev/jev_sxml_demo').
:- use_module('../examples/services/jev_service').
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/websocket)).
:- use_module(library(readutil)).
:- use_module(library(socket)).

:- dynamic fixture_endpoint/1, seen_request/2.

:- http_handler(root(systemone), jev_fixture, []).

start_jev_fixture :-
    retractall(seen_request(_, _)),
    tcp_socket(Socket),
    tcp_bind(Socket, Port),
    tcp_close_socket(Socket),
    http_server(http_dispatch, [port(Port)]),
    format(atom(Endpoint), 'http://localhost:~d/systemone', [Port]),
    assertz(fixture_endpoint(Endpoint-Port)).

stop_jev_fixture :-
    forall(retract(fixture_endpoint(_-Port)), http_stop_server(Port, [])),
    retractall(seen_request(_, _)).

jev_fixture(Request) :-
    memberchk(authorization(Authorization), Request),
    http_read_json_dict(Request, Payload),
    assertz(seen_request(Payload, Authorization)),
    fixture_choice(Payload, Choice, ChoiceProbabilities, ChoiceConfidence),
    reply_json_dict(_{
        model:"jev-fixture-1",
        answers:_{
            intent:_{
                type:"choice", choice:Choice,
                probabilities:ChoiceProbabilities,
                confidence:ChoiceConfidence,
                fixture_extension:"preserved in raw response"
            },
            urgency:_{
                type:"score", score:1.25,
                legend:_{'0':"Routine", '1':"Time-sensitive",
                         '2':"Emergency"},
                probabilities:_{'0':0.05, '1':0.65, '2':0.30},
                confidence:0.62
            },
            is_question:_{type:"noul", noul:0.18}
        },
        usage:_{input_tokens:123, output_tokens:17},
        response_extension:_{trace_id:"fixture-42"}
    }).

fixture_choice(Payload, Choice, Probabilities, Confidence) :-
    (   get_dict(state, Payload, State),
        is_dict(State),
        get_dict(message, State, Text),
        fixture_text_choice(Text, Choice0, Confidence0)
    ->  Choice = Choice0,
        Confidence = Confidence0,
        Base = _{request_deploy:0.01, affirm:0.01, deny:0.01,
                 status:0.01, other:0.01},
        put_dict(Choice, Base, 0.96, Probabilities)
    ;   Choice = request_deploy,
        Confidence = 0.87,
        Probabilities = _{request_deploy:0.90, affirm:0.02,
                          deny:0.01, status:0.04, other:0.03}
    ).

fixture_text_choice("yes", affirm, 0.96).
fixture_text_choice("no", deny, 0.96).
fixture_text_choice("status", status, 0.96).
fixture_text_choice("maybe", other, 0.20).
fixture_text_choice("prepare deployment", request_deploy, 0.96).

:- begin_tests(jev, [setup(start_jev_fixture), cleanup(stop_jev_fixture)]).

test(raw_http_contract_and_complete_response) :-
    retractall(user:seen_request(_, _)),
    user:fixture_endpoint(Endpoint-_),
    Payload = _{model:"jev-latest", state:"hello",
                questions:_{q:_{type:"noul", instructions:"A question?"}}},
    jev_http_request(Payload, Response,
                     [endpoint(Endpoint), api_key("fixture-key")]),
    assertion(Response.response_extension.trace_id == "fixture-42"),
    user:seen_request(Seen, Authorization),
    assertion(Seen.model == "jev-latest"),
    assertion(Seen.state == "hello"),
    assertion(Authorization == 'Bearer fixture-key').

test(typed_questions_bind_uncertainty_and_keep_raw_response) :-
    retractall(user:seen_request(_, _)),
    user:fixture_endpoint(Endpoint-_),
    jev_decide(_{message:"Please prepare a deployment"}, [
        choice(intent, "What is the intent?",
               [request_deploy-"prepare", affirm-"yes", deny-"no",
                status-"status", other-"other"], Intent),
        score(urgency, "How urgent?",
              ["Routine", "Time-sensitive", "Emergency"], Urgency),
        noul(is_question, "Is this a question?", IsQuestion)
    ], Raw, [endpoint(Endpoint), api_key("fixture-key")]),
    Intent = choice(request_deploy, Probabilities, 0.87),
    assertion(Probabilities.request_deploy =:= 0.90),
    assertion(Urgency = score(1.25, _, _, 0.62)),
    assertion(IsQuestion == noul(0.18)),
    assertion(Raw.response_extension.trace_id == "fixture-42"),
    assertion(Raw.model == "jev-fixture-1").

test(decision_becomes_shared_application_observation) :-
    user:fixture_endpoint(Endpoint-_),
    setup_call_cleanup(
        ( setenv('TYPESAFE_API_KEY', 'fixture-key'),
          setenv('TYPESAFE_ENDPOINT', Endpoint) ),
        ( deployment_observation("Prepare it", Observation),
          Observation = observation(
              choice(request_deploy, _, 0.87),
              score(1.25, _, _, 0.62),
              noul(0.18),
              provenance(Raw)),
          assertion(Raw.model == "jev-fixture-1") ),
        ( unsetenv('TYPESAFE_API_KEY'),
          unsetenv('TYPESAFE_ENDPOINT') )).

test(missing_configuration_is_not_a_negative_intent) :-
    setup_call_cleanup(
        ( getenv('TYPESAFE_API_KEY', OldKey) -> HadKey = true ; HadKey = false ),
        ( unsetenv('TYPESAFE_API_KEY'),
          unsetenv('TYPESAFE_ENDPOINT'),
          deployment_observation("no", Observation),
          assertion(Observation == unavailable(configuration)),
          assertion(Observation \= observation(choice(deny, _, _), _, _, _)) ),
        ( HadKey == true -> setenv('TYPESAFE_API_KEY', OldKey) ; true )).

test(owner_service_is_fixed_and_rate_bounded) :-
    retractall(user:seen_request(_, _)),
    user:fixture_endpoint(Endpoint-_),
    setup_call_cleanup(
        ( setenv('TYPESAFE_API_KEY', 'fixture-key'),
          setenv('TYPESAFE_ENDPOINT', Endpoint) ),
        ( configure_jev_service,
          jev_deployment_observation("Prepare it", First),
          assertion(First = observation(choice(request_deploy, _, _),
                                        score(_, _, _, _), noul(_),
                                        provenance(_))),
          jev_deployment_observation("Again", Second),
          assertion(Second == unavailable(rate_limited)),
          user:seen_request(Payload, _),
          assertion(get_dict(request_deploy,
                             Payload.questions.intent.criteria, _)),
          assertion(\+ get_dict(endpoint, Payload, _)),
          assertion(\+ get_dict(api_key, Payload, _)) ),
        ( unsetenv('TYPESAFE_API_KEY'),
          unsetenv('TYPESAFE_ENDPOINT') )).

test(stage1_observe_think_act_paths) :-
    setup_call_cleanup(
        deployment_actor_spawn(Pid, user:mock_deployment_sensor),
        ( stage1_call(Pid, deploy, "Please prepare a deployment", Deploy),
          assertion(Deploy = report(_, _, action(prepare_preview),
                                   reply(prepared, _))),
          stage1_call(Pid, status, "status", Status),
          assertion(Status = report(_, _, action(show_status),
                                   reply(status, _))),
          stage1_call(Pid, ambiguous, "maybe", Ambiguous),
          assertion(Ambiguous = report(_, _, action(clarify),
                                      reply(clarification, _))),
          stage1_call(Pid, unavailable, "offline", Unavailable),
          assertion(Unavailable = report(_, unavailable(transport),
                                        action(retry_later),
                                        reply(unavailable(transport), _))) ),
        exit(Pid, kill)).

test(stage1_malformed_sensor_result_is_explicit) :-
    setup_call_cleanup(
        deployment_actor_spawn(Pid, user:malformed_sensor),
        ( stage1_call(Pid, malformed, "anything", Report),
          assertion(Report = report(_, unavailable(malformed_observation),
                                    action(retry_later), _)) ),
        exit(Pid, kill)).

test(malformed_provider_result_is_explicit) :-
    observe_with(user:malformed_provider_sensor, "anything", Observation),
    assertion(Observation == unavailable(malformed_response)).

test(non_object_json_is_a_malformed_response) :-
    catch(jev_http:parse_json_response("[]", _), Error, true),
    assertion(Error = error(jev_invalid_response(_), _)),
    observe_with(user:non_object_provider_sensor, "anything", Observation),
    assertion(Observation == unavailable(malformed_response)).

test(invalid_probability_distribution_is_rejected) :-
    user:mock_deployment_sensor("yes", Candidate),
    Candidate = observation(choice(affirm, _, Confidence), Score, Noul,
                            Provenance),
    Invalid = observation(choice(affirm, _{affirm:1.2}, Confidence),
                          Score, Noul, Provenance),
    normalize_observation(Invalid, Observation),
    assertion(Observation == unavailable(malformed_observation)).

test(stage2_affirm_in_idle_does_not_deploy) :-
    setup_call_cleanup(
        demo_spawn(Pid, user:mock_deployment_sensor),
        ( stage2_call(Pid, idle_yes, "yes", Report),
          assertion(Report = report("yes", _, state(idle), transition(none),
                                   action(explain_context), _)) ),
        exit(Pid, kill)).

test(stage2_affirm_confirms_pending_request) :-
    setup_call_cleanup(
        demo_spawn(Pid, user:mock_deployment_sensor),
        ( stage2_call(Pid, deploy, "Please prepare a deployment", Prepared),
          assertion(Prepared = report(_, _, state(idle),
                                     transition(idle-awaiting_confirmation),
                                     action(ask_confirmation), _)),
          stage2_call(Pid, yes, "yes", Confirmed),
          assertion(Confirmed = report("yes", _, state(awaiting_confirmation),
                                      transition(awaiting_confirmation-idle),
                                      action(simulate_deploy(
                                          proposal(deploy,
                                                   "Please prepare a deployment",
                                                   _))), _)),
          stage2_call(Pid, repeated_yes, "yes", Repeated),
          assertion(Repeated = report("yes", _, state(idle), transition(none),
                                     action(explain_context), _)) ),
        exit(Pid, kill)).

test(stage2_deny_cancels_pending_request) :-
    setup_call_cleanup(
        demo_spawn(Pid, user:mock_deployment_sensor),
        ( stage2_call(Pid, deploy, "Please prepare a deployment", _),
          stage2_call(Pid, no, "no", Cancelled),
          assertion(Cancelled = report("no", _, state(awaiting_confirmation),
                                      transition(awaiting_confirmation-idle),
                                      action(cancel(
                                          proposal(deploy,
                                                   "Please prepare a deployment",
                                                   _))), _)) ),
        exit(Pid, kill)).

test(stage2_ambiguous_observation_preserves_state) :-
    setup_call_cleanup(
        demo_spawn(Pid, user:mock_deployment_sensor),
        ( stage2_call(Pid, deploy, "Please prepare a deployment", _),
          stage2_call(Pid, ambiguous, "maybe", Ambiguous),
          assertion(Ambiguous = report("maybe", _,
                                      state(awaiting_confirmation),
                                      transition(none), action(clarify), _)),
          stage2_call(Pid, yes, "yes", Confirmed),
          assertion(Confirmed = report(_, _, state(awaiting_confirmation),
                                      transition(awaiting_confirmation-idle),
                                      action(simulate_deploy(
                                          proposal(deploy,
                                                   "Please prepare a deployment",
                                                   _))), _)) ),
        exit(Pid, kill)).

test(english_and_swedish_affirm_share_symbolic_boundary) :-
    user:mock_deployment_sensor("yes", English),
    user:mock_deployment_sensor("ja", Swedish),
    assertion(English =@= Swedish).

test(canonical_statechart_source_contains_no_external_jev_call) :-
    read_file_to_string('examples/statecharts/20 jev-deployment-assistant.xml',
                        Source, []),
    assertion(\+ sub_string(Source, _, _, _, 'jev_deployment_observation(')),
    assertion(\+ sub_string(Source, _, _, _, 'http_open(')),
    assertion(\+ sub_string(Source, _, _, _, 'jev_decide(')).

test(public_websocket_runs_both_drawer_stages) :-
    user:fixture_endpoint(Endpoint-_),
    tcp_socket(Socket),
    tcp_bind(Socket, Port),
    tcp_close_socket(Socket),
    setup_call_cleanup(
        ( setenv('WP_ACK_PUBLIC', yes),
          setenv('TYPESAFE_API_KEY', 'fixture-key'),
          setenv('TYPESAFE_ENDPOINT', Endpoint),
          configure_jev_service,
          node(Port, [auth(open), profile(actor), sandbox(blacklist),
                      load_shared_db_file('Deployment/shared_db_n3.pl')]) ),
        ( public_drawer_example(
              Port, 'examples/actors/23 jev-agent.pl',
              "(self(Me),jev_agent_spawn(Pid),Pid ! say(Me,one,\"prepare deployment\"),receive({agent_reply(one,R)->writeln(R)},[timeout(5),on_timeout(throw(missing_jev_reply))]),Pid ! stop,receive({down(Pid,_,_)->true},[timeout(3),on_timeout(true)]))",
              "prepare_preview"),
          sleep(0.3),
          public_drawer_example(
              Port, 'examples/actors/23 jev-agent.pl',
              "(self(Me),jev_agent_spawn(Pid),Pid ! say(Me,status,\"status\"),receive({agent_reply(status,R)->writeln(R)},[timeout(5),on_timeout(throw(missing_jev_reply))]),Pid ! stop,receive({down(Pid,_,_)->true},[timeout(3),on_timeout(true)]))",
              "show_status"),
          sleep(0.3),
          public_drawer_example(
              Port, 'examples/actors/23 jev-agent.pl',
              "(self(Me),jev_agent_spawn(Pid),Pid ! say(Me,maybe,\"maybe\"),receive({agent_reply(maybe,R)->writeln(R)},[timeout(5),on_timeout(throw(missing_jev_reply))]),Pid ! stop,receive({down(Pid,_,_)->true},[timeout(3),on_timeout(true)]))",
              "clarify"),
          sleep(0.3),
          public_drawer_example(
              Port, 'examples/actors/24 jev-sxml-agent.pl',
              "(self(Me),jev_sxml_agent_spawn(Pid),Pid ! say(Me,idle_yes,\"yes\"),receive({demo_reply(idle_yes,R1)->writeln(R1)},[timeout(5),on_timeout(throw(missing_jev_reply))]),sleep(0.3),Pid ! say(Me,deploy,\"prepare deployment\"),receive({demo_reply(deploy,R2)->writeln(R2)},[timeout(5),on_timeout(throw(missing_jev_reply))]),sleep(0.3),Pid ! say(Me,confirm,\"yes\"),receive({demo_reply(confirm,R3)->writeln(R3)},[timeout(5),on_timeout(throw(missing_jev_reply))]),Pid ! stop,receive({down(Pid,_,_)->true},[timeout(3),on_timeout(true)]))",
              "simulate_deploy") ),
        ( http_stop_server(Port, []),
          unsetenv('TYPESAFE_API_KEY'),
          unsetenv('TYPESAFE_ENDPOINT') )).

:- end_tests(jev).

stage1_call(Pid, Ref, Text, Report) :-
    self(Me),
    Pid ! say(Me, Ref, Text),
    receive({agent_reply(Ref, Report) -> true}, [timeout(3)]).

stage2_call(Pid, Ref, Text, Report) :-
    self(Me),
    Pid ! say(Me, Ref, Text),
    receive({demo_reply(Ref, Report) -> true}, [timeout(3)]).

malformed_sensor(_, not_an_observation).

malformed_provider_sensor(_, _) :-
    throw(error(existence_error(jev_answer_field, confidence), fixture)).

non_object_provider_sensor(_, _) :-
    throw(error(jev_invalid_response([]), fixture)).

mock_deployment_sensor(Text,
        observation(choice(Intent, Probabilities, Confidence),
                    score(0.0, _{'0':"Routine"}, _{'0':1.0}, 1.0),
                    noul(0.0),
                    provenance(_{model:"fixture", usage:_{input_tokens:1,
                                                             output_tokens:1}}))) :-
    Text \== "offline",
    mock_intent(Text, Intent),
    mock_confidence(Text, Confidence),
    Base = _{request_deploy:0.01, affirm:0.01, deny:0.01,
             status:0.01, other:0.01},
    put_dict(Intent, Base, 0.96, Probabilities).
mock_deployment_sensor("offline", _) :-
    throw(error(jev_unavailable(connection_failed), _)).

mock_confidence("maybe", 0.20) :- !.
mock_confidence(_, 0.96).

mock_intent("Please prepare a deployment", request_deploy) :- !.
mock_intent("prepare deployment", request_deploy) :- !.
mock_intent("status", status) :- !.
mock_intent("yes", affirm) :- !.
mock_intent("ja", affirm) :- !.
mock_intent("no", deny) :- !.
mock_intent("nej", deny) :- !.
mock_intent(_, other).

public_drawer_example(Port, File, Goal, ExpectedText) :-
    read_file_to_string(File, Source, []),
    term_string([src_text(Source)], Options),
    format(atom(URL), 'http://localhost:~d/ws', [Port]),
    setup_call_cleanup(
        http_open_websocket(URL, WS, []),
        ( atom_json_dict(JSON, _{command:spawn, goal:Goal, options:Options}, []),
          ws_send(WS, text(JSON)),
          call_with_time_limit(10,
              await_drawer_output(WS, 80, ExpectedText, false, _)) ),
        catch(ws_close(WS, 1000, ""),
              error(websocket_error(unexpected_message,_),_),
              close(WS, [force(true)]))).

await_drawer_output(_, 0, Expected, _, _) :-
    throw(missing_jev_output(Expected)).
await_drawer_output(WS, Attempts, Expected, Seen, Pid) :-
    Attempts > 0,
    ws_receive(WS, Frame),
    atom_json_dict(Frame.data, Reply, []),
    (   get_dict(type, Reply, "output")
    ->  term_string(Reply, Text),
        ( sub_string(Text, _, _, _, Expected) -> Seen1 = true ; Seen1 = Seen ),
        Next is Attempts - 1,
        await_drawer_output(WS, Next, Expected, Seen1, Pid)
    ;   get_dict(type, Reply, "spawned")
    ->  get_dict(pid, Reply, Pid),
        Next is Attempts - 1,
        await_drawer_output(WS, Next, Expected, Seen, Pid)
    ;   get_dict(type, Reply, "error")
    ->  throw(unexpected_public_error(Reply))
    ;   get_dict(type, Reply, "down"), nonvar(Pid), get_dict(pid, Reply, Pid)
    ->  Seen == true
    ;   Next is Attempts - 1,
        await_drawer_output(WS, Next, Expected, Seen, Pid)
    ).
