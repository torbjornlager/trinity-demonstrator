:- module(callback_stall_trace,[install/0]).
:- use_module(library(prolog_wrap)).
:- use_module(library(http/http_open),[]).
:- meta_predicate traced(+,0).
:- dynamic trace_stream/1.
stage(Event,Tag) :-
 get_time(T),thread_self(Thread),
 trace_stream(Stream),
 format(Stream,'~Ncallback_stage(~q,~q,~q,~q).~n',[T,Thread,Event,Tag]),flush_output(Stream).
traced(Tag,Goal) :-
 setup_call_catcher_cleanup(stage(enter,Tag),
    (call(Goal),stage(solution,Tag)),Catcher,stage(leave(Catcher),Tag)).
install :-
 getenv('CALLBACK_TRACE_FILE',File),open(File,write,Stream,[encoding(utf8),buffer(false)]),assertz(trace_stream(Stream)),
 wrap_predicate(test_node:start_node_server(O,P,U),callback_trace,W1,traced(start_server(O,P,U),W1)),
 wrap_predicate(test_node:stop_node_server(P),callback_trace,W2,traced(stop_server(P),W2)),
 wrap_predicate(test_node:read_json_answer(U,J),callback_trace,W3,traced(read_json(U,J),W3)),
 wrap_predicate(http_open:http_open(U,S,O),callback_trace,W4,traced(http_open(U,S,O),W4)),
 wrap_predicate(node:node_controller_isobase(R),callback_trace,W5,traced(http_handler(R),W5)),
 wrap_predicate(rpc:promise(U,G,Ref,O),callback_trace,W6,traced(promise(U,G,Ref,O),W6)),
 wrap_predicate(rpc:yield(Ref,A,O),callback_trace,W7,traced(yield(Ref,A,O),W7)),
 wrap_predicate(rpc:prepare_timeout_callback(M,G,S),callback_trace,W8,traced(prepare_callback(M,G,S),W8)),
 wrap_predicate(rpc:dispose_promises_for_owner(O),callback_trace,W9,traced(dispose_owner(O),W9)),
 wrap_predicate(thread_httpd:http_stop_server(P,O),callback_trace,W10,traced(http_stop_server(P,O),W10)),
 wrap_predicate(thread_httpd:connect(Address),callback_trace,W11,traced(shutdown_wakeup(Address),W11)),
 wrap_predicate(socket:tcp_accept(Socket,Client,Peer),callback_trace,W12,traced(tcp_accept(Socket,Client,Peer),W12)),
 stage(ready,installed).
