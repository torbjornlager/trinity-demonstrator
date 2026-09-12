:- ['../load.pl'].
:- use_module(library(plunit)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).
:- use_module(library(socket)).
:- load_files(expert_example:'../examples/actors/20 expert-system-agent.pl', []).

:- begin_tests(expert_system_agent).

test(backtracking_changes_questions) :-
    expert_conversation([], [yes,yes,no,yes,yes], Outcome, Questions),
    assertion(Outcome == proved),
    assertion(Questions == ['Does it have feathers?', 'Does it tweet?',
                            'Is it small?', 'Is it cuddly?', 'Is it yellow?']).

test(private_fact_skips_question_and_does_not_leak) :-
    expert_conversation([yellow(tweety)], [yes,yes,no,yes], First, Known),
    assertion(First == proved),
    assertion(\+ member('Is it yellow?', Known)),
    expert_conversation([], [yes,yes,no,yes,no], Second, Fresh),
    assertion(Second == not_proved),
    assertion(member('Is it yellow?', Fresh)).

test(first_rule_needs_only_three_answers) :-
    expert_conversation([], [yes,yes,yes], Outcome, Questions),
    assertion(Outcome == proved),
    assertion(Questions == ['Does it have feathers?', 'Does it tweet?', 'Is it small?']).

test(book_simulation) :-
    with_output_to(string(Text),
        call_with_time_limit(5, expert_example:simulation([]))),
    assertion(sub_string(Text, _, _, _, 'A1: Is ')),
    assertion(sub_string(Text, _, _, _, 'a good pet.')),
    mailbox_empty.

test(public_actor_source_shipping) :-
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    setup_call_cleanup(
        node(Port, [auth(open), profile(actor), sandbox(blacklist)]),
        public_expert_example(Port),
        http_stop_server(Port, [])).

:- end_tests(expert_system_agent).

mailbox_empty :-
    receive({Message -> throw(unexpected_expert_message(Message))},
            [timeout(0), on_timeout(true)]).

public_expert_example(Port) :-
    read_file_to_string('examples/actors/20 expert-system-agent.pl', Source, []),
    term_string([src_text(Source)], Options),
    format(atom(URL), 'http://localhost:~d/ws', [Port]),
    setup_call_cleanup(
        http_open_websocket(URL, WS, []),
        ( atom_json_dict(JSON, _{command:spawn,
            goal:"(simulation([]),simulation([src_list([yellow(tweety)])]),catch(expert_ask(good_pet(tweety),_,[src_list([(bad :- shell(true))])]),E,true),nonvar(E),E=error(permission_error(_,_,_),_),writeln(expert_checks_passed))",
            options:Options}, []),
          ws_send(WS, text(JSON)),
          call_with_time_limit(10, await_expert_output(WS, _)) ),
        catch(ws_close(WS, 1000, ""), _, close(WS, [force(true)]))).

await_expert_output(WS, Root) :-
    ws_receive(WS, Frame),
    ( Frame.opcode == close -> throw(expert_socket_closed) ; true ),
    atom_json_dict(Frame.data, Reply, []),
    ( get_dict(type, Reply, "output"),
      term_string(Reply, Text), sub_string(Text, _, _, _, "expert_checks_passed")
    -> true
    ; get_dict(type, Reply, "error") -> throw(expert_public_error(Reply))
    ; get_dict(type, Reply, "spawned") ->
        get_dict(pid, Reply, Root), await_expert_output(WS, Root)
    ; get_dict(type, Reply, "down"), get_dict(pid, Reply, Root)
    -> throw(expert_public_stopped(Reply))
    ; await_expert_output(WS, Root) ).

% Deterministic partners belong in the tests, not in the teaching example.
expert_conversation(Facts, Answers, Outcome, Questions) :-
    expert_example:expert_ask(good_pet(tweety), Pid, [src_list(Facts)]),
    setup_call_cleanup(true,
        answer_expert(Pid, Answers, Outcome, Questions), exit(Pid, kill)),
    mailbox_empty.

answer_expert(Pid, Answers, Outcome, Questions) :-
    receive({
        prompt(Pid, Question) ->
            Answers = [Answer|Rest], Questions = [Question|Tail],
            respond(Pid, Answer), answer_expert(Pid, Rest, Outcome, Tail) ;
        success(Pid, _, false) -> Outcome = proved, Questions = [] ;
        failure(Pid) -> Outcome = not_proved, Questions = [] ;
        error(Pid, Error) -> throw(Error)
    }, [timeout(3), on_timeout(throw(expert_test_timeout))]).
