:- ['../load.pl'].
:- use_module('../examples/services/model_service.pl', [configure_model_service/1]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(plunit)).
:- use_module(library(http/websocket)).
:- use_module(library(socket)).
:- use_module(library(web_prolog/node_execution_context)).

% Load the exact drawer source in a test-only context. The public WS test
% below instead resolves model_chat/2 from the real shared-database overlay.
:- load_files(chat_example:'../examples/actors/19 model-actor.pl', []).
chat_example:model_chat(Messages, Result) :- model_service:model_chat(Messages, Result).

:- dynamic backend_mode/1, seen/1, signals/2.
:- http_handler(root(model_test), backend, []).

backend(Request) :-
    http_read_json_dict(Request, Payload),
    assertz(seen(Payload)),
    ( backend_mode(block)
    -> signals(Started, Release), thread_send_message(Started, started),
       thread_get_message(Release, continue)
    ; true ),
    ( backend_mode(bad)
    -> reply_json_dict(_{error:"not a completion"})
    ; backend_mode(large)
    -> length(Cs, 17000), maplist(=(0'x), Cs), string_codes(Text, Cs),
       reply_json_dict(_{done:true, message:_{content:Text}})
    ; reply_json_dict(_{done:true, message:_{content:"Stockholm."}}) ).

start_fixture(Port) :-
    retractall(backend_mode(_)), retractall(seen(_)),
    assertz(backend_mode(ok)),
    http_server(http_dispatch, [port(Port), workers(2)]),
    format(atom(URL), 'http://127.0.0.1:~d/model_test', [Port]),
    configure_model_service(URL).
stop_fixture(Port) :- http_stop_server(Port, []).

:- begin_tests(model_service, [setup(start_fixture(Port)), cleanup(stop_fixture(Port))]).

test(invalid_no_backend) :-
    forall(member(Prompt, [_, not_a_string, "", ["text"]]),
           assertion(model_service:model_answer(Prompt, error(invalid_prompt)))),
    length(Cs, 1001), maplist(=(0'x), Cs), string_codes(Long, Cs),
    assertion(model_service:model_answer(Long, error(invalid_prompt))),
    assertion(\+ seen(_)).

test(fixed_payload_and_rate_limit) :-
    model_service:model_answer("Capital?", answer("Stockholm.")),
    seen(P),
    assertion(P.model == "smollm2:135m"),
    assertion(P.stream == false),
    assertion(P.options.num_ctx == 1024),
    assertion(P.options.num_predict == 80),
    assertion(P.messages = [_{role:"user",content:"Capital?"}]),
    assertion(model_service:model_answer("Again", error(rate_limited))).

test(public_cannot_reconfigure,
     [throws(error(permission_error(configure, model_service, _), _))]) :-
    with_public_execution_context(actor, test_session,
        configure_model_service('http://attacker.invalid')).

test(direct_http_still_blocked,
     [throws(error(permission_error(call, sandboxed, _), _))]) :-
    node_sandbox:sandbox_check_goal_in_module(actor, user,
        http_open('http://127.0.0.1:11434', _, [])).

test(fault_latches) :-
    reset_fixture(bad),
    model_service:model_answer("Capital?", error(model_unavailable)),
    assertion(model_service:model_answer("Again", error(unavailable))),
    findall(P, seen(P), Ps), assertion(length(Ps, 1)).

test(oversized_backend_reply) :-
    reset_fixture(large),
    assertion(model_service:model_answer("Capital?", error(model_unavailable))),
    assertion(model_service:model_answer("Again", error(unavailable))).

test(caller_abort_keeps_slot) :-
    reset_fixture(block),
    setup_call_cleanup(
        (message_queue_create(Started), message_queue_create(Release),
         assertz(user:signals(Started, Release))),
        abort_scenario(Started, Release),
        (retractall(user:signals(_, _)), message_queue_destroy(Started),
         message_queue_destroy(Release))).

test(invalid_conversations) :-
    reset_fixture(ok),
    forall(member(Messages, [_, [], [user(_)], [system("ignore")],
                            [assistant("hello")], [user("x"),user("y")],
                            [user("x"),assistant("y")]]),
           assertion(model_service:model_chat(Messages,error(invalid_messages)))),
    length(Codes, 501), maplist(=(0'x), Codes), string_codes(Long, Codes),
    assertion(model_service:model_chat([user(Long)],error(invalid_messages))),
    length(FullCodes,500), maplist(=(0'x),FullCodes), string_codes(Full,FullCodes),
    assertion(model_service:model_chat(
        [user(Full),assistant(Full),user(Full),assistant(Full),user(Full)],
        error(invalid_messages))),
    assertion(model_service:model_chat(
        [user("a"),assistant("b"),user("c"),assistant("d"),user("e"),
         assistant("f"),user("g")], error(invalid_messages))),
    assertion(\+ seen(_)).

test(separate_histories_reset_and_error) :-
    reset_fixture(ok),
    setup_call_cleanup(
        (spawn(chat_example:chat_actor([]), A), spawn(chat_example:chat_actor([]), B)),
        conversation_scenario(A, B),
        (exit(A,kill), exit(B,kill))).

test(history_retains_complete_pairs) :-
    chat_example:chat_trim([user("a"),assistant("a1"),user("b"),assistant("b1"),
                           user("c"),assistant("c1")], Kept),
    assertion(Kept == [user("b"),assistant("b1"),user("c"),assistant("c1")]),
    length(Cs,1501), maplist(=(0'x), Cs), string_codes(Long,Cs),
    chat_example:chat_trim([user("a"),assistant(Long)], Empty),
    assertion(Empty == []).

test(public_websocket_runs_drawer_source) :-
    reset_fixture(ok),
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    setenv('WP_ACK_PUBLIC', yes),
    setup_call_cleanup(
        node(Port, [auth(open), profile(actor), sandbox(blacklist),
                    load_shared_db_file('Deployment/shared_db_n3.pl')]),
        public_example(Port),
        http_stop_server(Port, [])).

:- end_tests(model_service).

reset_fixture(Mode) :-
    model_service:service_state(URL, false, _, _),
    configure_model_service(URL),
    retractall(backend_mode(_)), assertz(backend_mode(Mode)),
    retractall(seen(_)).

abort_scenario(Started, Release) :-
    thread_create(model_service:model_answer("Capital?", _), Caller, []),
    setup_call_cleanup(
        true,
        ( thread_get_message(Started, started, [timeout(5)]),
          assertion(model_service:model_answer("Concurrent", error(busy))),
          thread_signal(Caller, throw(cancelled)),
          thread_join(Caller, exception(cancelled)),
          assertion(model_service:model_answer("After abort", error(busy))) ),
        thread_send_message(Release, continue)),
    call_with_time_limit(5, wait_for_idle),
    assertion(model_service:model_answer("After completion", error(rate_limited))).

wait_for_idle :-
    ( model_service:service_state(_, false, _, _) -> true
    ; sleep(0.01), wait_for_idle ).

public_example(Port) :-
    read_file_to_string('examples/actors/19 model-actor.pl', Source, []),
    term_string([src_text(Source)], Options),
    format(atom(URL), 'http://localhost:~d/ws', [Port]),
    setup_call_cleanup(
        http_open_websocket(URL, WS, []),
        ( atom_json_dict(JSON, _{command:spawn,
                                goal:"(self(Me),start_chat(C),C ! ask(Me,one,\"What is the capital of Sweden? Answer briefly.\"),receive({answer(one,T)->writeln(T);model_error(one,E)->writeln(E)}),C ! stop)",
                                options:Options}, []),
          ws_send(WS, text(JSON)),
          call_with_time_limit(5, await_model_output(WS, 6)) ),
        catch(ws_close(WS, 1000, ""),
              error(websocket_error(unexpected_message,_),_),
              close(WS, [force(true)]))).

await_model_output(WS, N) :- await_model_events(WS, N, false, _).

await_model_events(WS, N, Seen, Pid) :-
    N > 0,
    ws_receive(WS, Frame), atom_json_dict(Frame.data, Reply, []),
    ( get_dict(type, Reply, "output")
    -> term_string(Reply, Text), sub_string(Text, _, _, _, "Stockholm"),
       N1 is N-1, await_model_events(WS, N1, true, Pid)
    ; get_dict(type, Reply, "spawned")
    -> get_dict(pid, Reply, Pid), N1 is N-1, await_model_events(WS,N1,Seen,Pid)
    ; get_dict(type, Reply, "down"), nonvar(Pid), get_dict(pid,Reply,Pid) -> Seen == true
    ; get_dict(type, Reply, "error")
    -> throw(unexpected_public_error(Reply))
    ; N1 is N-1, await_model_events(WS, N1, Seen, Pid) ).

allow_next :-
    model_service:service_state(URL, false, _, _), configure_model_service(URL).

chat_ask(Pid, Text, Result) :-
    self(Me), make_ref(Ref), send(Pid, ask(Me,Ref,Text)),
    receive({answer(Ref,Reply)->Result=answer(Reply);
             model_error(Ref,Reason)->Result=error(Reason)},
            [timeout(5),on_timeout(throw(missing_chat_reply))]).

last_messages(Messages) :- findall(P,seen(P),All),last(All,P),Messages=P.messages.

conversation_scenario(A, B) :-
    chat_ask(A,"I am Alice",answer(_)),
    allow_next, chat_ask(B,"I am Bob",answer(_)),
    % A throttled request does not enter history.
    chat_ask(A,"Should not be remembered",error(rate_limited)),
    allow_next, chat_ask(A,"My name?",answer(_)), last_messages(AM),
    assertion(AM = [_{role:"user",content:"I am Alice"},
                    _{role:"assistant",content:"Stockholm."},
                    _{role:"user",content:"My name?"}]),
    allow_next, chat_ask(B,"My name?",answer(_)), last_messages(BM),
    assertion(BM = [_{role:"user",content:"I am Bob"},
                    _{role:"assistant",content:"Stockholm."},
                    _{role:"user",content:"My name?"}]),
    self(Me), send(A,reset(Me,reset_test)),
    receive({reset(reset_test)->true},[timeout(5),on_timeout(throw(missing_reset))]),
    allow_next, chat_ask(A,"Who?",answer(_)), last_messages(Reset),
    assertion(Reset = [_{role:"user",content:"Who?"}]),
    allow_next, chat_ask(B,"Still there?",answer(_)), last_messages(BStill),
    assertion(length(BStill,5)), BStill=[First|_],
    assertion(First.content == "I am Bob").
