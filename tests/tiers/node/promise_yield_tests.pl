:- module(test_promise_yield, []).

:- use_module('../../../prolog/web_prolog/rpc.pl').
:- use_module(library(http/thread_httpd)).
:- use_module(library(socket)).
:- use_module(library(plunit)).

:- meta_predicate with_response(+,1), with_pending(-,-,0).

with_response(Response, Goal) :-
    setup_call_cleanup(
        http_server(serve(Response), [port(Port),workers(1)]),
        (format(atom(URI),'http://localhost:~w',[Port]), call(Goal, URI)),
        http_stop_server(Port, [])).

serve(delay(Seconds), _) :- !,
    sleep(Seconds), format('Content-type: application/x-prolog~n~nsuccess([ok],false).~n').
serve(status_error, _) :- !,
    format('Status: 503 Service Unavailable~nContent-type: text/plain~n~nunavailable~n').
serve(Text, _) :-
    format('Content-type: application/x-prolog~n~n~s',[Text]).

with_pending(Ref, Queue, Goal) :-
    setup_call_cleanup(
        (rpc:make_reference(Ref),
         rpc:promise_queue_key(Ref, Key),
         with_mutex(promise_lifecycle,rpc:new_promise_state(Key,Queue))),
        Goal,
        rpc:promise_cleanup(Ref)).

collect(Response, Expected) :- with_response(Response, collect_from(Expected)).
collect_from(Expected, URI) :-
    promise(URI,true,Ref),
    yield(Ref,Answer,[timeout(2)]),
    assertion(Answer =@= Expected).

bad_response(Text, URI) :-
    promise(URI,true,Ref), yield(Ref,Answer,[timeout(2)]),
    assertion(Answer = error(error(domain_error(promise_answer,_),_))),
    assertion(nonvar(Text)).

transport_failure(URI) :-
    promise(URI,true,Ref,[http_timeout(0.02)]),
    yield(Ref,Answer,[timeout(2)]),
    assertion(Answer = error(_)).

put_answer(Ref,Answer) :-
    rpc:promise_queue_key(Ref,Key),rpc:deliver_promise_answer(Key,Answer).

local_timeout(Answer) :- Answer = local_timeout.

:- begin_tests(promise_yield).

test(success) :- collect("success([a,b],false).",success([a,b],false)).
test(logical_failure) :- collect("failure.",failure).
test(remote_exception) :- collect("error(remote_problem).",error(remote_problem)).
test(answer_variables) :-
    with_response("success([f(X,X),f(Y,Y)],false).",collect_variables).
test(malformed_shape,
     [forall(member(Text,["", "unexpected.", "_.", "success(a,false).",
                         "success([],maybe).", "success([],More).", "error(_)." ]))]) :-
    with_response(Text,bad_response(Text)).
test(syntax_error) :- with_response("success([",collect_syntax_error).
test(http_failure) :- with_response(status_error,transport_failure).
test(http_timeout) :- with_response(delay(0.1),transport_failure).
test(connection_failure) :-
    tcp_socket(Socket), tcp_bind(Socket,Port), tcp_close_socket(Socket),
    format(atom(URI),'http://localhost:~w',[Port]), transport_failure(URI).
test(request_preparation_error) :-
    with_pending(Ref,_,
        (rpc:promise_queue_key(Ref,Key),
         rpc:promise_worker(Key,17,true,true,0,none,[], '',none,false),
         yield(Ref,Answer,[timeout(1)]), assertion(Answer = error(_)))).
test(default_timeout_and_retry) :-
    with_pending(Ref,_,
        (yield(Ref,First,[timeout(0)]), assertion(First==timeout),
         put_answer(Ref,success([ready],false)),
         yield(Ref,Second), assertion(Second==success([ready],false)))).
test(callback_binding) :-
    with_pending(Ref,_,
        (yield(Ref,Answer,[timeout(0),on_timeout(Answer=timeout)]), assertion(Answer==timeout))).
test(callback_caller_context) :-
    with_pending(Ref,_,
        (yield(Ref,Answer,[timeout(0),on_timeout(local_timeout(Answer))]), assertion(Answer==local_timeout))).
test(callback_unbound_fallback) :-
    with_pending(Ref,_,
        (yield(Ref,Answer,[timeout(0),on_timeout(true)]), assertion(Answer==timeout))).
test(callback_single_solution, true(Answers==[first])) :-
    with_pending(Ref,_, findall(Answer,
        yield(Ref,Answer,[timeout(0),on_timeout(member(Answer,[first,second]))]),Answers)).
test(callback_failure,
     [throws(error(timeout_callback_failed(_),_))]) :-
    with_pending(Ref,_,yield(Ref,_,[timeout(0),on_timeout(fail)])).
test(callback_exception, [throws(callback_problem)]) :-
    with_pending(Ref,_,yield(Ref,_,[timeout(0),on_timeout(throw(callback_problem))])).
test(callback_failure_keeps_reference) :-
    with_pending(Ref,_,
        (catch(yield(Ref,_,[timeout(0),on_timeout(fail)]),error(timeout_callback_failed(Ref),_),true),
         put_answer(Ref,failure),yield(Ref,Answer),assertion(Answer==failure))).
test(unknown_reference_two, [throws(error(existence_error(promise,Ref),_))]) :-
    rpc:make_reference(Ref),yield(Ref,_).
test(unknown_reference_three, [throws(error(existence_error(promise,Ref),_))]) :-
    rpc:make_reference(Ref),yield(Ref,_,[timeout(0),on_timeout(throw(should_not_run))]).
test(repeated_collection, [forall(member(Arity,[2,3]))]) :-
    with_pending(Ref,_,
        (put_answer(Ref,failure),yield(Ref,failure),
         catch((Arity==2 -> yield(Ref,_);yield(Ref,_,[timeout(0)])),Error,true),
         assertion(Error = error(existence_error(promise,Ref),_)))).
test(removed_reference, [throws(error(existence_error(promise,Ref),_))]) :-
    with_pending(Ref,_,(rpc:promise_cleanup(Ref),yield(Ref,_))).
test(reference_type, [throws(error(type_error(integer,bad),_))]) :- yield(bad,_).
test(ready_answer_skips_callback) :-
    with_pending(Ref,_,
        (put_answer(Ref,failure),
         yield(Ref,Answer,[timeout(0),on_timeout(throw(should_not_run))]),assertion(Answer==failure))).

:- end_tests(promise_yield).

collect_variables(URI) :-
    promise(URI,true,Ref),yield(Ref,success([f(X,X2),f(Y,Y2)],false),[timeout(2)]),
    assertion(var(X)),assertion(X==X2),assertion(var(Y)),assertion(Y==Y2),assertion(X\==Y).
collect_syntax_error(URI) :-
    promise(URI,true,Ref),yield(Ref,Answer,[timeout(2)]),
    assertion(Answer = error(error(syntax_error(_),_))).
