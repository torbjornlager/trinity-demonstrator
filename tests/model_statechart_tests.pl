/* Reuse the bounded fake backend and conversation assertions from example 19. */
:- ['model_service_tests.pl'].

spawn_model_chart(Pid) :- spawn_model_chart(normal, Pid).
spawn_model_chart(Mode, Pid) :-
    read_file_to_string('examples/statecharts/19 model-statechart.xml', Source, []),
    ( Mode == timeout
    -> atomic_list_concat(Parts, 'after="45"', Source),
       atomic_list_concat(Parts, 'after="0.05"', XML)
    ; XML = Source ),
    statechart_spawn(Pid, [src_text(XML), trace(false),
        src_list([(model_chat(Messages, Result) :-
                     model_service:model_chat(Messages, Result))])]).

:- begin_tests(model_statechart,
               [setup(start_fixture(Port)), cleanup(stop_fixture(Port))]).

test(independent_histories_reset_and_errors) :-
    reset_fixture(ok),
    setup_call_cleanup(
        (spawn_model_chart(A), spawn_model_chart(B)),
        conversation_scenario(A, B),
        (exit(A,kill), exit(B,kill))).

test(invalid_prompt_does_not_call_backend) :-
    reset_fixture(ok),
    setup_call_cleanup(spawn_model_chart(Pid),
        (chat_ask(Pid, not_a_string, error(invalid_prompt)),
         assertion(\+ seen(_))),
        exit(Pid,kill)).

test(stop_reaches_final) :-
    setup_call_cleanup(spawn_model_chart(Pid),
        (monitor(Pid, Ref), send(Pid,stop),
         receive({down(Pid,Ref,_)->true},
                 [timeout(3),on_timeout(throw(chart_did_not_stop))])),
        exit(Pid,kill)).

test(reset_during_inference_and_stale_reply) :-
    reset_fixture(block), with_blocked_chart(normal, reset_while_thinking).

test(timeout_keeps_history_and_backend_slot) :-
    reset_fixture(block), with_blocked_chart(timeout, timeout_while_thinking).

test(public_websocket_runs_sxml_source) :-
    reset_fixture(ok),
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    setenv('WP_ACK_PUBLIC', yes),
    setup_call_cleanup(
        node(Port, [auth(open), profile(actor), sandbox(blacklist),
                    load_shared_db_file('Deployment/shared_db_n3.pl')]),
        public_model_chart(Port),
        http_stop_server(Port, [])).

:- end_tests(model_statechart).

:- meta_predicate with_blocked_chart(+, 3).
with_blocked_chart(Mode, Goal) :-
    setup_call_cleanup(
        (message_queue_create(Started), message_queue_create(Release),
         assertz(signals(Started,Release)), spawn_model_chart(Mode,Pid)),
        call(Goal,Pid,Started,Release),
        (thread_send_message(Release,continue),
         call_with_time_limit(5,wait_for_idle), exit(Pid,kill),
         retractall(signals(_,_)), message_queue_destroy(Started),
         message_queue_destroy(Release))).

reset_while_thinking(Pid, Started, _Release) :-
    self(Me), send(Pid,ask(Me,slow,"Remember Alice")),
    thread_get_message(Started,started,[timeout(3)]),
    % The stale event must not complete the request or exit thinking.
    send(Pid,model_result(stale,answer("FORGED"))),
    chat_ask(Pid,"Concurrent request",error(busy)),
    send(Pid,reset(Me,reset_pending)),
    receive({model_error(slow,reset)->true},[timeout(3)]),
    receive({reset(reset_pending)->true},[timeout(3)]),
    assertion(model_service:model_chat([user("Still busy")],error(busy))),
    % Back in ready, bad prompts are rejected locally (not as thinking/busy).
    chat_ask(Pid,not_a_string,error(invalid_prompt)),
    receive({answer(slow,_)->throw(stale_reply_accepted)},
            [timeout(0),on_timeout(true)]).

timeout_while_thinking(Pid, Started, Release) :-
    retractall(backend_mode(_)), assertz(backend_mode(ok)),
    chat_ask(Pid,"Original conversation",answer(_)), allow_next,
    retractall(backend_mode(_)), assertz(backend_mode(block)),
    self(Me), send(Pid,ask(Me,timed,"Remember Bob")),
    thread_get_message(Started,started,[timeout(3)]),
    receive({model_error(timed,timeout)->true},
            [timeout(3),on_timeout(throw(missing_timeout))]),
    assertion(model_service:model_chat([user("Still busy")],error(busy))),
    chat_ask(Pid,not_a_string,error(invalid_prompt)),
    thread_send_message(Release,continue), call_with_time_limit(5,wait_for_idle),
    allow_next, retractall(backend_mode(_)), assertz(backend_mode(ok)),
    chat_ask(Pid,"Retry",answer(_)), last_messages(Messages),
    assertion(Messages = [_{role:"user",content:"Original conversation"},
                          _{role:"assistant",content:"Stockholm."},
                          _{role:"user",content:"Retry"}]).

public_model_chart(Port) :-
    read_file_to_string('examples/statecharts/19 model-statechart.xml', XML, []),
    Goal = (self(Me), statechart_spawn(C, [src_text(XML),trace(false)]),
            send(C,ask(Me,chart_one,"What is the capital of Sweden? Answer briefly.")),
            receive({answer(chart_one,Text)->writeln(Text);
                     model_error(chart_one,Reason)->writeln(Reason)}),
            send(C,stop)),
    term_string(Goal, GoalText),
    format(atom(URL), 'http://localhost:~d/ws', [Port]),
    setup_call_cleanup(
        http_open_websocket(URL, WS, []),
        (atom_json_dict(JSON, _{command:spawn,goal:GoalText,options:"[]"}, []),
         ws_send(WS,text(JSON)),
         call_with_time_limit(10,await_model_output(WS,10))),
        catch(ws_close(WS,1000,""),
              error(websocket_error(unexpected_message,_),_),
              close(WS,[force(true)]))).
