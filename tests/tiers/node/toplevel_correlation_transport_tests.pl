:- module(test_toplevel_correlation_transport, []).
:- op(200,xfx,@).

:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../../prolog/web_prolog/distribution.pl', []).
:- use_module('../../../prolog/web_prolog/remote_protocol.pl', []).
:- use_module('multi_node_harness.pl').
:- use_module(library(plunit)).
:- use_module(library(process)).
:- use_module(library(http/http_client)).
:- use_module('../../../prolog/web_prolog/pid_utils.pl', []).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/websocket)).
:- use_module(library(http/json)).

:- dynamic legacy_endpoint/1, legacy_command/1.
:- multifile distribution:hook_ws_endpoint_override/2.
distribution:hook_ws_endpoint_override('http://correlation-legacy.invalid', URL) :-
    test_toplevel_correlation_transport:legacy_endpoint(URL).

:- http_handler('/test_correlation_legacy', legacy_upgrade, []).
legacy_upgrade(Request) :-
    http_upgrade_to_websocket(legacy_peer, [], Request).

% A pre-correlation peer accepts the connection and arbitrary actor sends,
% but selects no subprotocol. No request acknowledgement is needed to detect it.
legacy_peer(WS) :-
    ws_receive(WS, Frame, []),
    (Frame.opcode == close -> true
    ; atom_json_dict(Frame.data, Dict, []),
      assertz(legacy_command(Dict)), legacy_peer(WS)).

:- http_handler('/test_correlation_answers', answer_upgrade, []).
answer_upgrade(Request) :-
    http_upgrade_to_websocket(answer_peer,
                              [subprotocols(['web-prolog-sync-v1'])],Request).
answer_peer(WS) :-
    forall(member(Answer,[success(42,[pair(X,X)],false),failure(42),error(42,wire_error)]),
           node_ws:ws_relay_message(WS,unused,'$toplevel_reply'(12345,Answer))),
    ws_receive(WS,_,[]).

:- http_handler('/test_browser_answer_terms', browser_answer_upgrade, []).
browser_answer_upgrade(Request) :-
    http_upgrade_to_websocket(browser_answer_peer, [], Request).
browser_answer_peer(WS) :-
    setup_call_cleanup(message_queue_create(Q),
        ( ws_receive(WS,Hello,[format(json)]),
          node_ws:ws_action_transport_hello(Hello.data,Q),
          thread_get_message(Q,Welcome),node_ws:ws_relay_message(WS,Q,Welcome),
          node_ws:ws_relay_message(WS,Q,success(42,[pair(X,X),pair(_Y,_Z),'a b',"text",'$VAR'(1)],false)),
          node_ws:ws_relay_message(WS,Q,error(42,error(probe,context(remote,_Detail)))),
          ws_receive(WS,_,[]) ),
        (retractall(node_ws:ws_answer_terms(Q)),message_queue_destroy(Q))).

unsupported_request(call, Pid) :- toplevel_call_synch(Pid,true,_,[timeout(0)]).
unsupported_request(next, Pid) :- toplevel_next_synch(Pid,_,[timeout(0)]).

start_native_peer(Process, URL) :-
    pick_free_port(Port), format(atom(URL),'http://localhost:~w',[Port]),
    source_file(legacy_upgrade(_), ThisFile), file_directory_name(ThisFile, Dir),
    absolute_file_name('../../../prolog/web_prolog/node.pl',NodeFile,
                       [relative_to(Dir),access(read)]),
    format(atom(Goal),'use_module(~q),node(~w,[profile(actor),auth(open)]),pid_utils:register_node_self(~q)',
           [NodeFile,Port,URL]),
    current_prolog_flag(executable, Exe),
    process_create(Exe,['-q','-g',Goal,'-t','thread_get_message(stop)'],
                   [process(Process),stdout(null)]),
    atom_concat(URL,'/version',VersionURL),
    catch(wait_until(catch(http_get(VersionURL,_,[timeout(0.2)]),_,fail),5),
          Error,(stop_native_peer(Process),throw(Error))).

stop_native_peer(Process) :-
    catch(process_kill(Process,term),_,true),process_wait(Process,_).

restore_self_url(some(URL)) :- pid_utils:register_node_self(URL).
restore_self_url(none) :- retractall(pid_utils:self_node(_)).

:- begin_tests(toplevel_correlation_transport).

test(unsupported_peer_rejected_before_query,
     [forall(member(Kind,[call,next])),cleanup(retractall(test_toplevel_correlation_transport:legacy_command(_)))]) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
        (nb_getval(node_url_b, URL),
         atom_concat(URL, '/test_correlation_legacy', Endpoint),
         setup_call_cleanup(assertz(test_toplevel_correlation_transport:legacy_endpoint(Endpoint)),
             (Pid = 4242424242@'http://correlation-legacy.invalid',
              self(Self), findall(R,actors:monitor(Self,Pid,R),Before),
              catch(unsupported_request(Kind,Pid),Error,true),
              assertion(Error = error(permission_error(use,toplevel_correlation,
                                         'http://correlation-legacy.invalid'),_)),
              findall(R,actors:monitor(Self,Pid,R),After), assertion(After == Before),
              % An async send on the same unsupported connection still works.
              toplevel_call(Pid,true),
              wait_until((legacy_command(D), D.command == "send"),2),
              findall(D,(legacy_command(D),D.command=="send"),Sends),
              assertion(Sends = [_]),
              Sends = [Sent], assertion(\+ get_dict(toplevel_correlation,Sent,_))),
             (distribution:remote_drop_connection('http://correlation-legacy.invalid'),
              retractall(test_toplevel_correlation_transport:legacy_endpoint(_)))))).

test(native_peer_in_separate_process, [timeout(15)]) :-
    (pid_utils:registered_self_node_url(Old) -> Previous = some(Old); Previous = none),
    setup_call_cleanup(true,
        with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
            (nb_getval(node_url_b,LocalURL),pid_utils:register_node_self(LocalURL),
             setup_call_cleanup(start_native_peer(Process,RemoteURL),
                 forall(test_toplevel_synch:correlation_case(Case),
                     (toplevel_spawn(Pid,[node(RemoteURL),session(true),time_limit(0.15)]),
                      setup_call_cleanup(true,
                          test_toplevel_synch:correlation_scenario(Pid,Case),
                          toplevel_halt(Pid,true)))),
                 stop_native_peer(Process)))),
        restore_self_url(Previous)).

test(queue_answer_wire_roundtrip) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
        (nb_getval(node_url_b,URL), atom_concat(URL,'/test_correlation_answers',Endpoint),
         setup_call_cleanup(http_open_websocket(Endpoint,WS,[]),
             (ws_receive(WS,F1,[format(json)]),
              remote_protocol:ws_json_to_actor_event(F1.data,42@remote,E1),
              E1 = '$toplevel_reply'(12345,success(42@remote,[pair(A,B)],false)),
              assertion(var(A)),assertion(A==B),
              ws_receive(WS,F2,[format(json)]),
              remote_protocol:ws_json_to_actor_event(F2.data,42@remote,E2),
              assertion(E2 == '$toplevel_reply'(12345,failure(42@remote))),
              ws_receive(WS,F3,[format(json)]),
              remote_protocol:ws_json_to_actor_event(F3.data,42@remote,E3),
              assertion(E3 == '$toplevel_reply'(12345,error(42@remote,wire_error)))),
             ws_close(WS,1000,"done")))).

test(decoder_restores_reference_and_shared_payload) :-
    remote_protocol:ws_json_to_actor_event(
        json{type:"success",data:[],more:false,term:"[pair(X,X)]",
             toplevel_correlation:"12345"},42@remote,Event),
    Event = '$toplevel_reply'(Ref,success(Pid,[pair(A,B)],false)),
    assertion(Ref == 12345),assertion(Pid == 42@remote),
    assertion(var(A)),assertion(A == B).

test(decoder_preserves_failure_reference) :-
    remote_protocol:ws_json_to_actor_event(
        json{type:"failure",toplevel_correlation:"12345"},42@remote,Event),
    assertion(Event == '$toplevel_reply'(12345,failure(42@remote))).

test(browser_answer_terms_negotiation_and_legacy_fallback,
     [forall(member(Exact,[true,false]))]) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
        ( nb_getval(node_url_b,URL),atom_concat(URL,'/test_browser_answer_terms',Endpoint),
          setup_call_cleanup(http_open_websocket(Endpoint,WS,[]),
              ( (Exact == true -> Hello=json{version:1,answer_terms:true};Hello=json{version:1}),
                atom_json_dict(Text,Hello,[]),ws_send(WS,text(Text)),
                ws_receive(WS,Welcome,[format(json)]),assertion(Welcome.data.answer_terms == Exact),
                ws_receive(WS,Success,[format(json)]),ws_receive(WS,Error,[format(json)]),
                ( Exact == true
                -> term_string(Rows,Success.data.term,[double_quotes(string)]),
                   Rows=[pair(A,B),pair(C,D),'a b',"text",'$VAR'(1)],
                   assertion(var(A)),assertion(A==B),assertion(var(C)),assertion(var(D)),
                   assertion(C\==D),assertion(A\==C),
                   term_string(error(probe,context(remote,Detail)),Error.data.term),assertion(var(Detail))
                ; assertion(\+get_dict(term,Success.data,_)),assertion(\+get_dict(term,Error.data,_)) ) ),
              ws_close(WS,1000,done)) )).

:- end_tests(toplevel_correlation_transport).
