:- ['../load.pl'].
:- use_module('../examples/services/linda_service.pl').
:- use_module('../examples/services/node_resident_services.pl').
:- use_module(library(plunit)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(socket)).
:- use_module(library(web_prolog/node_runtime_state),
              [with_node_port_context/2, update_current_node_runtime/1]).

:- begin_tests(linda).

test(read_take_duplicates_and_repeated_variables) :-
    setup_call_cleanup(linda_service:start_linda(S),
        (space_out(S, pair(a,b)),
         space_out(S, pair(c,c)),
         space_out(S, pair(c,c)),
         space_rd(S, pair(X,X)), assertion(X == c),
         space_inp(S, pair(c,c)),
         space_inp(S, pair(c,c)),
         assertion(\+ space_rdp(S, pair(c,c))),
         space_inp(S, pair(a,b))),
        exit(S, kill)).

test(waiters_fifo_reads_share_takes_compete) :-
    setup_call_cleanup(linda_service:start_linda(S),
        (request(S, rd(item(_)), R1), request(S, in(item(_)), R2),
         request(S, in(item(_)), R3),
         space_out(S, unrelated),
         assertion(\+ receive({linda_reply(R1,_)->true}, [timeout(0),on_timeout(fail)])),
         space_out(S, item(first)),
         reply(R1, tuple(item(first))), reply(R2, tuple(item(first))),
         assertion(\+ receive({linda_reply(R3,_)->true}, [timeout(0),on_timeout(fail)])),
         space_out(S, item(second)),
         reply(R3, tuple(item(second))),
         assertion(\+ space_inp(S, item(_)))),
        exit(S, kill)).

test(cancel_does_not_consume_later_tuple) :-
    setup_call_cleanup(linda_service:start_linda(S),
        (request(S, in(job(_)), R), self(Me), S ! linda_cancel(Me,R),
         space_out(S, job(kept)),
         space_inp(S, job(kept))),
        exit(S, kill)).

test(invalid_request_does_not_kill_space) :-
    setup_call_cleanup(linda_service:start_linda(S),
        (catch(space_out(S, p(_)), E, true),
         assertion(E == linda_error(invalid_tuple)),
         request(S, bogus, R), reply(R, error(invalid_operation)),
         space_out(S, still_alive),
         space_inp(S, still_alive)),
        exit(S, kill)).

test(public_drawer_and_different_users_share_service) :-
    tcp_socket(Socket), tcp_bind(Socket, Port), tcp_close_socket(Socket),
    setenv('WP_ACK_PUBLIC', yes),
    setup_call_cleanup(
        (node(Port, [auth(open),profile(actor),sandbox(blacklist),
                     load_shared_db_file('examples/services/service_directory.pl'),
                     load_shared_db_file('examples/services/linda_client.pl')]),
         with_node_port_context(Port, update_current_node_runtime(
             _{anon_per_ws_connection:true})),
         start_example_services(_, _)),
        (different_users_example(Port), public_data_example(Port)),
        (stop_example_services, http_stop_server(Port, []))).

:- end_tests(linda).

request(S, Op, Ref) :- self(Me), make_ref(Ref), S ! linda(Me,Ref,Op).
reply(Ref, Reply) :-
    receive({linda_reply(Ref,R)->Reply=R},
            [timeout(5),on_timeout(throw(missing_reply(Ref)))]).

% Each call uses a fresh connection and principal; Alice leaves before Bob
% takes her tuple. Public calls come entirely from the owner shared database.
different_users_example(Port) :-
    run_public_goal(Port, "(linda_out(message(my_group,hello)),writeln(verified))"),
    run_public_goal(Port, "(linda_in(message(my_group,M)),M=hello,writeln(verified))").

public_data_example(Port) :-
    run_public_goal(Port, "(linda_out(setting(my_group,colour,green)),writeln(verified))"),
    run_public_goal(Port, "(linda_rd(setting(my_group,colour,C)),C=green,writeln(verified))"),
    run_public_goal(Port, "(linda_rdp(setting(my_group,colour,green)),linda_inp(setting(my_group,colour,green)),\\+linda_rdp(setting(my_group,colour,_)),writeln(verified))").

space_out(S,T) :- linda_service:linda_call(S,out(T),ok).
space_in(S,T) :- linda_service:linda_call(S,in(T),tuple(T)).
space_rd(S,T) :- linda_service:linda_call(S,rd(T),tuple(T)).
space_inp(S,T) :- linda_service:linda_call(S,inp(T),tuple(T)).
space_rdp(S,T) :- linda_service:linda_call(S,rdp(T),tuple(T)).

run_public_goal(Port, Goal) :-
    read_file_to_string('examples/actors/25 linda.pl', Source, []),
    term_string([src_text(Source)], Options),
    format(atom(URL), 'http://localhost:~d/ws', [Port]),
    setup_call_cleanup(http_open_websocket(URL, WS, []),
        (atom_json_dict(JSON, _{command:spawn,goal:Goal,options:Options}, []),
         ws_send(WS, text(JSON)), call_with_time_limit(10, await_output(WS, false, _))),
        catch(ws_close(WS, 1000, ""), _, close(WS,[force(true)]))).

await_output(WS, Seen, Pid) :-
    ws_receive(WS, Frame), atom_json_dict(Frame.data, Reply, []),
    ( Reply.type == "error" -> throw(public_error(Reply))
    ; Reply.type == "spawned" -> await_output(WS, Seen, Reply.pid)
    ; Reply.type == "down", Reply.pid == Pid -> (Seen == true -> true ; throw(no_output(Reply)))
    ; Reply.type == "output" -> term_string(verified, Reply.data), await_output(WS, true, Pid)
    ; await_output(WS, Seen, Pid) ).
