:- module(test_toplevel_correlation_transport, []).
:- op(200,xfx,@).

:- use_module('../../../prolog/web_prolog/actors.pl').
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl').
:- use_module('../../../prolog/web_prolog/distribution.pl', []).
:- use_module('../../../prolog/web_prolog/remote_protocol.pl', []).
:- use_module('multi_node_harness.pl').
:- use_module(library(plunit)).
:- use_module(library(process)).
:- use_module(library(prolog_wrap)).
:- use_module(library(http/http_client)).
:- use_module(library(http/thread_httpd), [http_current_server/2]).
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

:- http_handler('/test_validation_answers', validation_upgrade, []).
validation_upgrade(Request) :-
    http_upgrade_to_websocket(validation_peer, [], Request).
validation_peer(WS) :-
    ws_receive(WS,_,[]),
    forall(member(Dict,[
        json{type:"success",pid:42,term:"[",data:["wrong"],more:false},
        json{type:"error",pid:42,data:"wrong",toplevel_correlation:"701"},
        json{type:"success",pid:42,term:"scalar",data:["wrong"],toplevel_correlation:"702"},
        json{type:"success",pid:42,data:["legacy"],more:false},
        json{type:"success",pid:42,term:"[row('€',pair(X,X),'$VAR'(1))]",more:false},
        json{type:"error",pid:42,term:"error(probe,context(remote,_))",toplevel_correlation:"703"},
        json{type:"failure",pid:42,toplevel_correlation:"704"}]),ws_send(WS,json(Dict))),
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

% Dedicated mock peers exercise capability negotiation and actual reader routing.
:- dynamic spawn_endpoint/2, transport_diagnostic/1.
:- multifile distribution:hook_event/1.
distribution:hook_event(Event) :-
    get_dict(event_type,Event,"remote_transport_error"),
    get_dict(node,Event,'http://spawn-correlation.invalid'),
    assertz(test_toplevel_correlation_transport:transport_diagnostic(Event)).
distribution:hook_ws_endpoint_override(Node,URL) :-
    test_toplevel_correlation_transport:spawn_endpoint(Node,URL),
    test_toplevel_correlation_transport:spawn_diag(selected_endpoint(Node,URL)).
:- http_handler('/test_spawn_correlated', spawn_upgrade(correlated), []).
:- http_handler('/test_spawn_legacy', spawn_upgrade(legacy), []).
spawn_upgrade(Mode,Request) :-
    spawn_diag(upgrade(Mode,Request)),
    (Mode==correlated -> Protocols=['web-prolog-sync-spawn-v1','web-prolog-sync-v1']
    ; Protocols=['web-prolog-sync-v1']),
    http_upgrade_to_websocket(spawn_peer(Mode),[subprotocols(Protocols)],Request).
spawn_peer(Mode,WS) :-
    spawn_diag(peer_connected(Mode,WS)),
    (Mode==correlated -> ws_send(WS,json(json{type:error,data:"before spawn"}));true),
    spawn_peer_loop(Mode,WS).
spawn_peer_loop(Mode,WS) :-
    ws_receive(WS,Frame,[format(json)]),
    spawn_diag(peer_received(Mode,WS,Frame)),
    (Frame.opcode==close -> true
    ; Dict=Frame.data,
      (Dict.goal=="close" -> ws_close(WS,1000,"test loss")
      ; (Dict.goal=="fail" -> Reply=json{type:error,data:"startup rejected"}
        ; Reply=json{type:spawned,pid:42}),
        (Mode==correlated ->
            ws_send(WS,json(json{type:error,data:"during spawn"})),
            ws_send(WS,json(json{type:error,data:"old request",request_id:"old"})),
            put_dict(request_id,Reply,Dict.request_id,Tagged)
        ; Tagged=Reply),
        spawn_diag(peer_sending(Mode,WS,Tagged)),
        ws_send(WS,json(Tagged)),spawn_peer_loop(Mode,WS))).

:- meta_predicate with_spawn_peer(+,-,0).
with_spawn_peer(Mode,Node,Goal) :-
    spawn_snapshot(fixture_enter(Mode)),
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
        (nb_getval(node_url_b,URL),
         (Mode==correlated -> Path='/test_spawn_correlated';Path='/test_spawn_legacy'),
         atom_concat(URL,Path,Endpoint),Node='http://spawn-correlation.invalid',
         spawn_snapshot(server_started(Mode,URL,Endpoint)),
         setup_call_cleanup(
             (assertz(spawn_endpoint(Node,Endpoint)),spawn_snapshot(endpoint_published(Mode,Endpoint))),
             (spawn_diag(goal_enter(Mode,Endpoint)),
              catch(Goal,Error,(spawn_snapshot(goal_exception(Mode,Error)),throw(Error))),
              spawn_snapshot(goal_returned(Mode,Endpoint))),
             call_cleanup(
                 (spawn_snapshot(before_connection_drop(Mode,Endpoint)),
                  spawn_drop_diagnostic(Node),
                  spawn_snapshot(after_connection_drop(Mode,Endpoint))),
                 (retractall(spawn_endpoint(Node,_)),retractall(transport_diagnostic(_)),
                  spawn_snapshot(endpoint_withdrawn(Mode,Endpoint))))))),
    spawn_snapshot(with_nodes_returned(Mode)).

% Preserve success, failure and exceptions while identifying a failed cleanup.
spawn_drop_diagnostic(Node) :-
    (spawn_diag_enabled ->
        catch((distribution:remote_drop_connection(Node) -> spawn_diag(drop_succeeded(Node))
              ; spawn_diag(drop_failed(Node)),fail),
              Error,(spawn_diag(drop_exception(Node,Error)),throw(Error)))
    ;distribution:remote_drop_connection(Node)).

% Opt-in test diagnostics. No waits, assertions or transport options are changed.
spawn_diag_enabled :- getenv('WP_SPAWN_TEST_DIAGNOSTICS', '1').
spawn_diag(Event) :-
    (spawn_diag_enabled -> catch(spawn_diag_write(Event),_,true);true).
spawn_diag_write(Event) :-
    flag(spawn_test_diag_sequence, Seq, Seq+1), get_time(Time), thread_self(Thread),
    format(string(Line),'~q.~n',[spawn_stage(Seq,Time,Thread,Event)]),
    (getenv('WP_SPAWN_TEST_LOG', File) ->
        with_mutex(spawn_test_diag_output,
            setup_call_cleanup(open(File,append,Stream,[encoding(utf8)]),
                               format(Stream,'~s',[Line]),close(Stream)))
    ;format(user_error,'~s',[Line]),flush_output(user_error)).
spawn_snapshot(Stage) :-
    (spawn_diag_enabled -> catch(spawn_snapshot_1(Stage),Error,
        spawn_diag(snapshot_error(Stage,Error)));true).
spawn_snapshot_1(Stage) :-
    findall(N-E,spawn_endpoint(N,E),Endpoints),
    findall(connection(N,S,R,Q,Status),
            (distribution:ws_connection(N,S,R,Q),
             (catch(thread_property(R,status(Status0)),_,fail)->Status=Status0;Status=retired)),
            Connections),
    findall(Port,http_current_server(node:_,Port),Servers),
    findall(Port,node_runtime_state:current_node_port(Port),Context),
    findall(Overrides,node_runtime_state:current_node_value(ws_endpoint_overrides,Overrides),OverridesList),
    spawn_diag_write(snapshot(Stage,Endpoints,Connections,Servers,Context,OverridesList)).

% Fault injection is local to this test thread; other readers use the original.
:- thread_local cleanup_fault/2.
:- meta_predicate with_cleanup_fault(+,+,0).
with_cleanup_fault(Point,Outcome,Goal) :-
    setup_call_cleanup(
        (asserta(cleanup_fault(Point,Outcome)),
         wrap_predicate(websocket:ws_close(S,_C,_D),spawn_cleanup_close,W1,
             (test_toplevel_correlation_transport:cleanup_fault(close,Action),
              S==spawn_cleanup_test_socket
              -> test_toplevel_correlation_transport:cleanup_fault_outcome(Action)
              ; W1)),
         wrap_predicate(distribution:remote_drop_connection(N),spawn_cleanup_drop,W2,
             (test_toplevel_correlation_transport:cleanup_fault(drop,Action),
              N=='http://spawn-correlation.invalid'
              -> test_toplevel_correlation_transport:cleanup_fault_outcome(Action)
              ; W2))),
        Goal,
        (unwrap_predicate(websocket:ws_close/3,spawn_cleanup_close),
         unwrap_predicate(distribution:remote_drop_connection/1,spawn_cleanup_drop),
         retractall(cleanup_fault(_,_)))).
cleanup_fault_outcome(fail) :- fail.
cleanup_fault_outcome(throw) :- throw(test_cleanup_error).

:- begin_tests(toplevel_correlation_transport).

bad_canonical_payload(_,Payload) :- member(Payload,[42,true,json{},"["]).
bad_canonical_payload("success",Payload) :- member(Payload,["scalar","[a|Tail]","_"]).

test(connection_drop_finishes_after_unsuccessful_close,
     [forall(member(Outcome,[fail,throw]))]) :-
    Node='http://spawn-cleanup.invalid',Other='http://spawn-cleanup-other.invalid',
    setup_call_cleanup(
        (message_queue_create(Q),message_queue_create(KeepQ)),
        setup_call_cleanup(
            (thread_self(Reader),
             assertz(distribution:ws_connection(Node,spawn_cleanup_test_socket,Reader,Q)),
             assertz(distribution:ws_sync_connection(spawn_cleanup_test_socket)),
             assertz(distribution:spawn_correlated_queue(Q)),
             assertz(distribution:ws_pending_event(Node,42,json{type:probe})),
             assertz(distribution:ws_pending_event(Other,43,json{type:kept})),
             assertz(distribution:ws_connection(Other,spawn_cleanup_other_socket,Reader,KeepQ)),
             assertz(distribution:ws_sync_connection(spawn_cleanup_other_socket)),
             thread_send_message(KeepQ,kept)),
            with_cleanup_fault(close,Outcome,
                (distribution:remote_drop_connection(Node),
                 assertion(\+ distribution:ws_connection(Node,_,_,_)),
                 assertion(\+ distribution:ws_sync_connection(spawn_cleanup_test_socket)),
                 assertion(\+ distribution:spawn_correlated_queue(Q)),
                 assertion(\+ distribution:closed_spawn_queue(Q)),
                 catch(message_queue_property(Q,size(_)),QueueError,true),
                 assertion(nonvar(QueueError)),
                 assertion(QueueError=error(existence_error(message_queue,Q),_)),
                 assertion(\+ distribution:ws_pending_event(Node,_,_)),
                 assertion(distribution:ws_connection(Other,spawn_cleanup_other_socket,Reader,KeepQ)),
                 assertion(distribution:ws_sync_connection(spawn_cleanup_other_socket)),
                 assertion(distribution:ws_pending_event(Other,43,json{type:kept})),
                 thread_get_message(KeepQ,kept,[timeout(0)]))),
            (retractall(distribution:ws_connection(Node,_,_,_)),
             retractall(distribution:ws_connection(Other,spawn_cleanup_other_socket,_,_)),
             retractall(distribution:ws_sync_connection(spawn_cleanup_test_socket)),
             retractall(distribution:ws_sync_connection(spawn_cleanup_other_socket)),
             retractall(distribution:ws_pending_event(Node,_,_)),
             retractall(distribution:ws_pending_event(Other,43,_)),
             retractall(distribution:spawn_correlated_queue(Q)),
             retractall(distribution:closed_spawn_queue(Q)))),
        (catch(message_queue_destroy(Q),_,true),message_queue_destroy(KeepQ))).

test(fixture_withdraws_endpoint_when_drop_fails_or_throws,
     [forall(member(Outcome,[fail,throw]))]) :-
    with_cleanup_fault(drop,Outcome,
        catch(with_spawn_peer(correlated,_,
                  assertz(test_toplevel_correlation_transport:transport_diagnostic(probe))),
              Error,true)),
    (Outcome==throw -> assertion(Error==test_cleanup_error);assertion(var(Error))),
    assertion(\+ test_toplevel_correlation_transport:spawn_endpoint('http://spawn-correlation.invalid',_)),
    assertion(\+ test_toplevel_correlation_transport:transport_diagnostic(_)).

test(outgoing_query_preserves_nested_qualifications_options_and_sharing) :-
    Options = [template(pair(X,X)),target(caller),'$request_ref'(12345),limit(2)],
    distribution:outgoing_toplevel_message(
        '$call'(private_actor:(member(X,[a,b]),helper:check(X)),Options), Wire),
    Wire = '$call'(Goal, SentOptions),
    assertion(Goal == (member(X,[a,b]),helper:check(X))),
    assertion(SentOptions == Options),
    remote_protocol:term_to_wire_atom(Wire, Text),
    read_term_from_atom(Text, Decoded, []),
    Decoded = '$call'((member(A,[a,b]),helper:check(B)),
                     [template(pair(C,D)),target(caller),'$request_ref'(12345),limit(2)]),
    assertion(var(A)),assertion(A==B),assertion(A==C),assertion(A==D),
    assertion(var(X)).

test(outgoing_other_messages_unchanged,
     [forall(member(Message, ['$next'([limit(2)]),data(private_actor:goal(X),X),
                             '$call'(member(X,[a,b]),[template(X)])]))]) :-
    distribution:outgoing_toplevel_message(Message, Wire),
    assertion(Wire == Message).

test(outgoing_variable_message_unchanged) :-
    distribution:outgoing_toplevel_message(Message, Wire),
    assertion(var(Message)),assertion(Wire == Message).

test(outgoing_async_query_normalized_on_actual_transport,
     [cleanup(retractall(test_toplevel_correlation_transport:legacy_command(_)))]) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
        (nb_getval(node_url_b,URL),atom_concat(URL,'/test_correlation_legacy',Endpoint),
         setup_call_cleanup(assertz(test_toplevel_correlation_transport:legacy_endpoint(Endpoint)),
             (Pid=4242424242@'http://correlation-legacy.invalid',
              toplevel_call(Pid,private_actor:(X=ok,helper:check(X)),[template(X)]),
              wait_until((legacy_command(D),D.command=="send"),2),
              legacy_command(Sent),Sent.command=="send",
              term_string(Message,Sent.message),
              Message='$call'((A=ok,helper:check(B)),[template(C)]),
              assertion(var(A)),assertion(A==B),assertion(A==C),assertion(var(X))),
             call_cleanup(distribution:remote_drop_connection('http://correlation-legacy.invalid'),
                          retractall(test_toplevel_correlation_transport:legacy_endpoint(_)))))).

test(spawn_errors_isolated_on_negotiated_connection) :-
    with_spawn_peer(correlated,Node,
        (distribution:remote_request_spawn(Node,json{command:spawn,goal:"ok"},P1),
         assertion(P1==42),
         distribution:remote_request_spawn(Node,json{command:spawn,goal:"ok"},P2),
         assertion(P2==42),
         findall(E,transport_diagnostic(E),Diagnostics),assertion(length(Diagnostics,3)),
         distribution:ws_connection(Node,_,_,Q),
         assertion(distribution:spawn_correlated_queue(Q)))).

test(matching_startup_failure_and_legacy_fallback,
     [forall(member(Mode,[correlated,legacy]))]) :-
    with_spawn_peer(Mode,Node,
        (catch(distribution:remote_request_spawn(Node,json{command:spawn,goal:"fail"},_),Error,true),
         assertion(Error=error(remote_spawn_failed("startup rejected"),_)))).

test(spawn_transport_loss_preserved,
     [forall(member(Mode,[correlated,legacy]))]) :-
    with_spawn_peer(Mode,Node,
        (catch(distribution:remote_request_spawn(Node,json{command:spawn,goal:"close"},_),Error,true),
         assertion(Error=error(remote_spawn_failed(connection_closed),_)))).

test(legacy_untagged_success_preserved) :-
    with_spawn_peer(legacy,Node,
        (distribution:remote_request_spawn(Node,json{command:spawn,goal:"ok"},Pid),
         assertion(Pid==42))).

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
             call_cleanup(distribution:remote_drop_connection('http://correlation-legacy.invalid'),
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

test(decoder_rejects_present_invalid_canonical_payload,
     [forall((member(Type,["success","error"]),
              bad_canonical_payload(Type,Payload),member(Tagged,[false,true])))]) :-
    Plain=json{type:Type,term:Payload,data:["must_not_be_used"],more:false},
    Error=error(42@remote,remote_answer_protocol_error(invalid_term)),
    (Tagged==true
    -> put_dict(toplevel_correlation,Plain,"ref(17)",Dict),
       Expected='$toplevel_reply'(ref(17),Error)
    ; Dict=Plain,Expected=Error),
    remote_protocol:ws_json_to_actor_event(Dict,42@remote,Event),
    assertion(Event==Expected).

test(decoder_rejects_missing_correlated_payload,
     [forall(member(Type,["success","error"]))]) :-
    remote_protocol:ws_json_to_actor_event(
        json{type:Type,data:["must_not_be_used"],more:false,
             toplevel_correlation:"ref(17)"},42@remote,Event),
    assertion(Event=='$toplevel_reply'(ref(17),
                  error(42@remote,remote_answer_protocol_error(missing_term)))).

test(decoder_retains_uncorrelated_legacy_success) :-
    remote_protocol:ws_json_to_actor_event(
        json{type:"success",data:["pair(X,X)"],more:true},42@remote,Event),
    Event=success(42@remote,[pair(A,B)],true),assertion(var(A)),assertion(A==B).

test(decoder_retains_uncorrelated_legacy_error) :-
    remote_protocol:ws_json_to_actor_event(
        json{type:"error",data:"legacy diagnostic"},42@remote,Event),
    assertion(Event==error(42@remote,remote_error("legacy diagnostic"))).

test(decoder_preserves_failure_reference) :-
    remote_protocol:ws_json_to_actor_event(
        json{type:"failure",toplevel_correlation:"12345"},42@remote,Event),
    assertion(Event == '$toplevel_reply'(12345,failure(42@remote))).

test(reader_recovers_after_malformed_answers,
     [forall(member(Delivery,[immediate,buffered])),timeout(10)]) :-
    with_test_nodes([node_spec(b,[profile(actor),auth(open)])],
      (nb_getval(node_url_b,URL),atom_concat(URL,'/test_validation_answers',Endpoint),
       Node='http://answer-validation.invalid',self(Self),Pid=42@Node,
       setup_call_cleanup(assertz(test_toplevel_correlation_transport:spawn_endpoint(Node,Endpoint)),
         (distribution:remote_connection(Node,_,_),
          (Delivery==immediate -> distribution:register_remote_pid(Pid,Self);true),
          send(Self,validation_kept),
          distribution:remote_send_command(Node,json{command:probe}),
          (Delivery==buffered
          -> wait_until((findall(D,distribution:ws_pending_event(Node,42,D),Ds),length(Ds,7)),3),
             distribution:register_remote_pid(Pid,Self),distribution:flush_pending_for_pid(Node,42)
          ; true),
          receive({error(Pid,remote_answer_protocol_error(invalid_term)) -> true},[timeout(3),on_timeout(fail)]),
          receive({'$toplevel_reply'(701,error(Pid,remote_answer_protocol_error(missing_term))) -> true},[timeout(3),on_timeout(fail)]),
          receive({'$toplevel_reply'(702,error(Pid,remote_answer_protocol_error(invalid_term))) -> true},[timeout(3),on_timeout(fail)]),
          receive({success(Pid,[legacy],false) -> true},[timeout(3),on_timeout(fail)]),
          receive({success(Pid,[row('€',pair(A,B),'$VAR'(1))],false) -> true},[timeout(3),on_timeout(fail)]),
          assertion(var(A)),assertion(A==B),
          receive({'$toplevel_reply'(703,error(Pid,error(probe,context(remote,Detail)))) -> true},[timeout(3),on_timeout(fail)]),
          assertion(var(Detail)),
          receive({'$toplevel_reply'(704,failure(Pid)) -> true},[timeout(3),on_timeout(fail)]),
          receive({validation_kept -> true},[timeout(0),on_timeout(fail)])),
         call_cleanup(distribution:remote_drop_connection(Node),
                      retractall(test_toplevel_correlation_transport:spawn_endpoint(Node,_)))))).

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

% Optional real-peer check, also run against the separate Trealla test node.
live_spawn_correlation(Node) :-
    spawn(receive({stop -> true}),Other,[link(false),monitor(true)]),
    setup_call_cleanup(true,
      (forall(member(_,[first,second]),live_spawn(Node)),
       catch(toplevel_spawn(_,[node(Node),session(true),src_text('broken(')]),Error,true),
       assertion(Error=error(remote_spawn_failed(_),_)),live_spawn(Node),
       send(Other,stop),
       receive({down(Other,Other,true) -> true},[timeout(3),on_timeout(fail)])),
      (exit(Other,kill),demonitor(Other,[flush]),distribution:remote_drop_connection(Node))),
    writeln('Live spawn correlation: unrelated errors, genuine startup failure and monitors: ok').
live_spawn(Node) :-
    distribution:remote_send_command(Node,json{command:toplevel_call,pid:99999999999,goal:"true",options:"[]"}),
    distribution:ws_connection(Node,_,_,Queue),
    assertion(distribution:spawn_correlated_queue(Queue)),
    toplevel_spawn(P,[node(Node),session(true),link(false),monitor(true)]),
    setup_call_cleanup(true,
      (toplevel_call_synch(P,X=ok,A,[template(X-X),timeout(3)]),
       assertion(A==success(P,[ok-ok],false)),assertion(var(X)),
       exit(P,kill),
       receive({down(P,P,_) -> true},[timeout(3),on_timeout(fail)])),
      (exit(P,kill),demonitor(P,[flush]))).
