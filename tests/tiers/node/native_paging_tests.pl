:- module(test_native_paging, []).

:- use_module('../../../prolog/web_prolog/rpc.pl').
:- use_module('../../../prolog/web_prolog/node.pl', []).
:- use_module('../../../prolog/web_prolog/node_engine.pl', []).
:- use_module('../../../prolog/web_prolog/toplevel_actors.pl', [toplevel_halt/2]).
:- use_module(library(plunit)).
:- use_module(library(gensym)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_parameters)).

:- meta_predicate with_pages(-,-,0), with_query_queue(-,0), with_cached_goal(+,+,-,0).

% An independent endpoint returns multiple short pages. Using the same wrong
% increment on both native sides would otherwise conceal the client defect.
with_pages(URI, Requests, Goal) :-
    setup_call_cleanup(message_queue_create(Requests),
        setup_call_cleanup(
            http_server(page_reply(Requests),[port(Port),workers(1)]),
            (format(atom(URI),'http://localhost:~w',[Port]),call(Goal)),
            http_stop_server(Port,[])),
        message_queue_destroy(Requests)).

page_reply(Requests, Request) :-
    http_parameters(Request,[offset(Offset,[integer]),limit(Limit,[integer])]),
    thread_send_message(Requests,request(Offset,Limit)),
    page_answer(Offset,Answer),
    format('Content-type: application/x-prolog~n~n'),
    write_canonical(Answer),write('.'),nl.

page_answer(0,success([v(a)],true)) :- !.
page_answer(1,success([v(b),v(c)],true)) :- !.
page_answer(3,success([v(d)],false)) :- !.
page_answer(Offset,error(unexpected_page_offset(Offset))).

with_query_queue(Alias, Goal) :-
    gensym(native_paging_,Alias),
    setup_call_cleanup(message_queue_create(_,[alias(Alias)]),call(Goal),
                       message_queue_destroy(Alias)).

with_cached_goal(Goal, Template, Gid, Test) :-
    node_engine:goal_id(Goal-Template-''-false,GoalId),
    node_engine:cache_key(GoalId,Gid),
    setup_call_cleanup(true,call(Test),
        forall(node_engine:cache_retract(Gid,_,Pid),toplevel_halt(Pid,true))).

assert_executed_once(Queue) :-
    thread_get_message(Queue,entered,[timeout(0)]),
    assertion(\+ thread_get_message(Queue,_,[timeout(0)])).

:- begin_tests(native_paging).

test(rpc_short_pages_advance_by_returned_count) :-
    with_pages(URI,Requests,
        (findall(X,rpc(URI,value(X),[limit(5)]),Xs),
         assertion(Xs==[a,b,c,d]),
         thread_get_message(Requests,request(0,5),[timeout(0)]),
         thread_get_message(Requests,request(1,5),[timeout(0)]),
         thread_get_message(Requests,request(3,5),[timeout(0)]),
         assertion(\+ thread_get_message(Requests,_,[timeout(0)])))).

test(rpc_once_does_not_request_another_page) :-
    with_pages(URI,Requests,
        (findall(X,rpc(URI,value(X),[limit(5),once(true)]),Xs),
         assertion(Xs==[a]),
         thread_get_message(Requests,request(0,5),[timeout(0)]),
         assertion(\+ thread_get_message(Requests,_,[timeout(0)])))).

% Direct engine calls allow a trusted queue notification to prove that cache
% reuse delivers the pending error without starting the query again.
test(partial_error_page_cache_offset,
     [forall(member(Offset,[0,1])),timeout(3)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),
               (member(X,[a,b,c]);throw(paging_error))),
         with_cached_goal(Goal,X,Gid,
             (node_engine:compute_answer(Goal,X,Offset,5,First),
              (Offset==0 -> Expected=[a,b,c];Expected=[b,c]),
              assertion(First==success(Expected,true)),
              assertion(node_engine:cache(Gid,3,_)),
              node_engine:compute_answer(Goal,X,3,2,Last),
              assertion(Last==error(paging_error)),
              assertion(\+ node_engine:cache(Gid,_,_)),
              assert_executed_once(Queue))))).

test(full_pages_changing_limits_and_final_page, [timeout(3)]) :-
    with_query_queue(Queue,
        (Goal=(thread_send_message(Queue,entered),between(1,7,X)),
         with_cached_goal(Goal,X,Gid,
             (node_engine:compute_answer(Goal,X,0,2,A),
              assertion(A==success([1,2],true)),
              assertion(node_engine:cache(Gid,2,_)),
              node_engine:compute_answer(Goal,X,2,3,B),
              assertion(B==success([3,4,5],true)),
              assertion(node_engine:cache(Gid,5,_)),
              node_engine:compute_answer(Goal,X,5,4,C),
              assertion(C==success([6,7],false)),
              assertion(\+ node_engine:cache(Gid,_,_)),
              assert_executed_once(Queue))))).

:- end_tests(native_paging).
