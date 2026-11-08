:- module(isotope_rpc).
:- use_module(actors).
:- use_module(toplevel_actors).
:- import exit/2 from actors.
:- ensure_loaded(stateless_rpc).
:- import goal_template_texts/4 from stateless_rpc.
:- lib(prolog_extras).
:- export rpc/2, rpc/3, promise/3, promise/4, yield/2.
:- export call_page/7, clear_promises/0, init_egress/0.
:- local store(egress).

init_egress :-
    shelf_create(sequence(0), Counter),
    store_set(egress, counter, Counter).

rpc(Node, Goal) :- rpc(Node, Goal, []).
rpc(Node0, Goal, Options) :-
    request_options(Node0, Options, false, Node, Source, Offset, Limit, Once),
    term_variables(Goal, Variables),
    Template =.. [v|Variables],
    rpc_rows(Node, Goal, Template, Source, Offset, Limit, Once).

rpc_rows(Node, Goal, Template, Source, Offset, Limit, Once) :-
    query_page(Node, Goal, Template, Source, Offset, Limit, Once, Answer),
    ( Answer = success(Rows, More) ->
        ( member(Template, Rows)
        ; More == true, Once == false, Rows = [_|_],
          length(Rows, Count),
          Next is Offset + Count,
          rpc_rows(Node, Goal, Template, Source, Next, Limit, Once)
        )
    ; Answer = error(Error) -> throw(Error)
    ; fail
    ).

promise(Node, Goal, Reference) :- promise(Node, Goal, Reference, []).
promise(Node0, Goal, Reference, Options) :-
    ( var(Reference) -> true ; throw(error(uninstantiation_error(Reference), promise/4)) ),
    request_options(Node0, Options, true, Node, Source, Offset, Limit, Once),
    option_value(template, Options, Goal, Template),
    promise_store(Store, Pending),
    length(Pending, Count),
    ( Count < 4 -> true ; throw(error(resource_error(promises), promise/4)) ),
    record_create(Result),
    spawn(promise_worker(Node, Goal, Template, Source, Offset, Limit, Once, Result),
          Worker),
    Worker = actor(Reference),
    store_set(Store, isotope_promises, [promise(Reference, Worker, Result)|Pending]).

promise_worker(Node, Goal, Template, Source, Offset, Limit, Once, Result) :-
    catch(query_page(Node, Goal, Template, Source, Offset, Limit, Once, Answer),
          Error, Answer = error(Error)),
    recordz(Result, Answer).

yield(Reference, Answer) :-
    promise_store(Store, Pending),
    ( integer(Reference), select(promise(Reference, _, Result), Pending, Rest) ->
        wait_result(Result, 50, Value),
        store_set(Store, isotope_promises, Rest),
        Answer = Value
    ; throw(error(existence_error(promise, Reference), yield/2))
    ).

wait_result(Result, Attempts, Answer) :-
    ( record_wait_remove(Result, Answer, 0.05) -> true
    ; Attempts > 1 ->
        Left is Attempts - 1,
        wait_result(Result, Left, Answer)
    ; throw(error(time_limit_exceeded, yield/2))
    ).

promise_store(Store, Pending) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    ( store_get(Store, isotope_promises, Pending) -> true ; Pending = [] ).

clear_promises :-
    promise_store(Store, Pending),
    ( Pending == [] -> true
    ; store_delete(Store, isotope_promises),
      ( foreach(promise(_, Worker, _), Pending) do exit(Worker, query_finished) )
    ).

request_options(Node0, Options, Promise, Node, Source, Offset, Limit, Once) :-
    ( atom(Node0) -> atom_string(Node0, Node)
    ; string(Node0) -> Node = Node0
    ; throw(error(type_error(atom_or_string, Node0), rpc/3))
    ),
    ( is_list(Options), valid_options(Options, Promise) -> true
    ; throw(error(domain_error(rpc_options, Options), rpc/3))
    ),
    option_value(offset, Options, 0, Offset),
    option_value(limit, Options, 100, Limit),
    option_value(once, Options, false, Once),
    option_value(src_text, Options, "", Text),
    ( memberchk(src_uri(Uri0), Options) ->
        ( atom(Uri0) -> atom_string(Uri0, Uri) ; Uri = Uri0 ),
        egress_request("source", Uri, [], Loaded),
        concat_string([Text, "\n", Loaded], Source)
    ; Source = Text
    ).

valid_options([], _).
valid_options([Option|Options], Promise) :-
    nonvar(Option),
    valid_option(Option, Promise),
    valid_options(Options, Promise).

valid_option(limit(N), _) :- integer(N), N >= 1, N =< 100.
valid_option(once(B), _) :- ( B == true ; B == false ).
valid_option(offset(N), true) :- integer(N), N >= 0.
valid_option(template(_), true).
valid_option(src_text(Text), _) :- ( atom(Text) ; string(Text) ).
valid_option(src_uri(Uri), _) :- ( atom(Uri) ; string(Uri) ).

option_value(Name, Options, Default, Value) :-
    Option =.. [Name, Found],
    ( memberchk(Option, Options) -> Value = Found ; Value = Default ).

query_page("localhost", Goal, Template, Source, Offset, Limit, Once, Answer) :- !,
    setup_call_cleanup(
        toplevel_spawn(Pid, [src_text(Source)]),
        call_page(Pid, Goal, Template, Offset, Limit, Once, Answer),
        exit(Pid, query_finished)
    ).
query_page(Node, Goal, Template, Source, Offset, Limit, Once, Answer) :-
    goal_template_texts(Goal, Template, GoalText, TemplateText),
    egress_request("call", Node,
        [goal:GoalText, template:TemplateText, src_text:Source,
         offset:Offset, limit:Limit, once:Once], Body),
    ( setup_call_cleanup(open(string(Body), read, Stream),
          ( read(Stream, Answer), read(Stream, end_of_file), at_eof(Stream) ),
          close(Stream)),
      valid_answer(Answer) -> true
    ; throw(error(invalid_rpc_response, rpc/3))
    ).

valid_answer(Answer) :-
    nonvar(Answer),
    ( Answer == failure
    ; Answer = error(_)
    ; Answer = success(Rows, More), is_list(Rows), ( More == true ; More == false )
    ), !.

call_page(Pid, Goal, Template, Offset, Limit, Once, Answer) :-
    toplevel_call(Pid, Goal, [template(Template), offset(Offset),
                             limit(Limit), once(Once)]),
    receive({
        success(Pid, Rows, More) -> Answer = success(Rows, More)
    ;
        failure(Pid) -> Answer = failure
    ;
        error(Pid, Error) -> Answer = error(Error)
    ;
        output(Pid, _) -> Answer = error(stateless_output)
    ;
        prompt(Pid, _) -> Answer = error(stateless_prompt)
    }, [timeout(3), on_timeout(Answer = error(time_limit_exceeded))]).

egress_request(Operation, Url, Params, Body) :-
    self(actor(Id)),
    store_get(egress, counter, Counter),
    shelf_inc_and_get(Counter, 1, Key),
    ( Params == [] -> JSON = {} ; JSON = {Params} ),
    send(main, http_egress(Key, Id, Operation, Url, JSON)),
    receive({
        http_egress_result(Key, "ok", Text) -> Body = Text
    ;
        http_egress_result(Key, "error", Reason) ->
            throw(error(rpc_error(Reason), rpc/3))
    }, [timeout(2.5), on_timeout(throw(error(rpc_error(http_timeout), rpc/3)))]).
