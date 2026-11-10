:- module(isotope_rpc).
:- use_module(actors).
:- use_module(toplevel_actors).
:- import exit/2 from actors.
:- ensure_loaded(stateless_rpc).
:- import goal_template_texts/4 from stateless_rpc.
:- lib(prolog_extras).
:- export rpc/2, rpc/3, promise/3, promise/4, yield/2, yield/3.
:- tool(rpc/2, rpc_/3).
:- tool(rpc/3, rpc_/4).
:- tool(promise/3, promise_/4).
:- tool(promise/4, promise_/5).
:- tool(yield/3, yield_/4).
:- export call_page/7, clear_promises/0, init_egress/0, egress_request/4, egress_request/5, query_page/8.
:- export await_call_page/2, stateless_spawn_options/3.
:- local store(egress).

init_egress :-
    shelf_create(sequence(0), Counter),
    store_set(egress, counter, Counter).

rpc_(Node, Goal, Module) :- rpc_(Node, Goal, [], Module).
rpc_(Node0, Goal, Options, Module) :-
    request_options(Node0, Options, Module, rpc, Node, Source, Offset, Limit, Once, Transport),
    term_variables(Goal, Variables),
    Template =.. [v|Variables],
    rpc_rows(Node, Goal, Template, Source, Offset, Limit, Once, Transport).

rpc_rows(Node, Goal, Template, Source, Offset, Limit, Once, Transport) :-
    query_page(Node, Goal, Template, Source, Offset, Limit, Once, Transport, Answer),
    ( Answer = success(Rows, More) ->
        ( member(Template, Rows)
        ; More == true, Once == false, Rows = [_|_],
          length(Rows, Count),
          Next is Offset + Count,
          rpc_rows(Node, Goal, Template, Source, Next, Limit, Once, Transport)
        )
    ; Answer = error(Error) -> throw(Error)
    ; fail
    ).

promise_(Node, Goal, Reference, Module) :- promise_(Node, Goal, Reference, [], Module).
promise_(Node0, Goal, Reference, Options, Module) :-
    ( var(Reference) -> true ; throw(error(uninstantiation_error(Reference), promise/4)) ),
    request_options(Node0, Options, Module, promise, Node, Source, Offset, Limit, Once, Transport),
    option_value(template, Options, Goal, Template),
    promise_store(Store, Pending),
    length(Pending, Count),
    ( Count < 4 -> true ; throw(error(resource_error(promises), promise/4)) ),
    record_create(Result),
    spawn(promise_worker(Node, Goal, Template, Source, Offset, Limit, Once, Transport, Result),
          Reference),
    store_set(Store, isotope_promises, [promise(Reference, Result)|Pending]).

promise_worker(Node, Goal, Template, Source, Offset, Limit, Once, Transport, Result) :-
    catch(query_page(Node, Goal, Template, Source, Offset, Limit, Once, Transport, Answer),
          Error, Answer = error(Error)),
    recordz(Result, Answer).

yield(Reference, Answer) :-
    yield_(Reference, Answer, [], isotope_rpc).

yield_(Reference, Answer, Options, Module) :-
    validate_options(Options, yield, yield/3),
    promise_store(Store, Pending),
    ( integer(Reference), select(promise(Reference, Result), Pending, Rest) -> true
    ; throw(error(existence_error(promise, Reference), yield/3)) ),
    option_value(timeout, Options, 2.5, Seconds),
    elapsed(Now),
    Deadline is Now + max(0, Seconds),
    ( wait_result(Result, Deadline, Value) ->
        store_set(Store, isotope_promises, Rest),
        Answer = Value
    ; memberchk(timeout(_), Options) ->
        option_value(on_timeout, Options, true, Goal),
        ( once(call(Goal)@Module) -> ( var(Answer) -> Answer = timeout ; true )
        ; throw(error(timeout_callback_failed(Reference), yield/3)) )
    ; throw(error(time_limit_exceeded, yield/2)) ).

wait_result(Result, Deadline, Answer) :-
    elapsed(Now),
    Remaining is max(0, min(0.05, Deadline - Now)),
    ( record_wait_remove(Result, Answer, Remaining) -> true
    ; Now < Deadline, wait_result(Result, Deadline, Answer) ).

promise_store(Store, Pending) :-
    engine_self(Engine),
    get_engine_property(Engine, store, Store),
    ( store_get(Store, isotope_promises, Pending) -> true ; Pending = [] ).

clear_promises :-
    promise_store(Store, Pending),
    ( Pending == [] -> true
    ; store_delete(Store, isotope_promises),
      ( foreach(promise(Worker, _), Pending) do exit(Worker, query_finished) )
    ).

request_options(Uri, Options, Module, Kind, Node, Source, Offset, Limit, Once, Transport) :-
    ( Kind == rpc -> Context = rpc/3 ; Context = promise/4 ),
    validate_options(Options, Kind, Context),
    require_creation_atom(Uri, Context),
    normalize_node_uri(Uri, Canonical),
    ( local_node_uri(Canonical) -> Node = "localhost" ; atom_string(Canonical, Node) ),
    option_value(offset, Options, 0, Offset),
    option_value(limit, Options, 100, Limit),
    option_value(once, Options, false, Once),
    option_timeout(timeout, Options, Execution),
    option_timeout(http_timeout, Options, HTTP),
    findall(Field, (member(Option, Options), http_field(Option, Field)), Fields),
    Transport = transport(Execution, HTTP, Fields),
    source_options_text(Options, Module, Text),
    ( memberchk(src_uri(SourceUri), Options) ->
        atom_string(SourceUri, Url),
        egress_request("source", Url, [], Loaded),
        concat_string([Text, "\n", Loaded], Source)
    ; Source = Text
    ).

option_timeout(Name, Options, Timeout) :-
    option_value(Name, Options, none, Value),
    ( Value == none -> Timeout = none ; Timeout is max(0, Value) ).

validate_options(Options, Kind, Context) :-
    catch(
        ( required_value(Options),
          ( is_list(Options) -> validate_option_list(Options, Kind)
          ; throw(type_error(list, Options)) ) ),
        Formal, throw(error(Formal, Context))).

validate_option_list([], _).
validate_option_list([Option|Options], Kind) :-
    required_value(Option),
    ( validate_option(Option, Kind) -> true
    ; concat_atom([Kind, '_option'], Domain), throw(domain_error(Domain, Option)) ),
    validate_option_list(Options, Kind).

validate_option(timeout(Value), _) :- numeric_timeout(Value).
validate_option(on_timeout(Goal), yield) :-
    required_value(Goal),
    ( callable(Goal) -> true ; throw(type_error(callable, Goal)) ).
validate_option(Option, Kind) :-
    Kind \== yield,
    query_option(Option, Kind).

query_option(http_timeout(Value), _) :- numeric_timeout(Value).
query_option(limit(N), _) :- integer(N), N >= 1, N =< 100.
query_option(once(B), _) :-
    required_atom(B),
    ( ( B == true ; B == false ) -> true ; throw(domain_error(boolean, B)) ).
query_option(offset(N), promise) :- integer(N), N >= 0.
query_option(template(_), promise).
query_option(Option, _) :- source_option(Option).
query_option(src_uri(Uri), _) :- required_atom(Uri).
query_option(request_header(Header), _) :-
    required_value(Header),
    ( Header = (Name=Value) -> header_name(Name), header_value(Value, _)
    ; throw(type_error(http_request_header, Header)) ).
query_option(authorization(Auth), _) :-
    required_value(Auth),
    ( Auth = basic(User, Password) -> header_value(User, _), header_value(Password, _)
    ; Auth = bearer(Token) -> header_value(Token, _)
    ; throw(domain_error(http_authorization, Auth)) ).
query_option(user_agent(Value), _) :- header_value(Value, _).

required_value(Value) :-
    ( var(Value) -> throw(instantiation_error) ; true ).

required_atom(Value) :-
    required_value(Value),
    ( atom(Value), Value \== [] -> true ; throw(type_error(atom, Value)) ).

numeric_timeout(Value) :-
    required_value(Value),
    ( number(Value), Value < 1.0Inf, Value > -1.0Inf -> true
    ; throw(type_error(number, Value)) ).

header_name(Name) :-
    required_value(Name),
    ( atom(Name), Name \== [] -> true ; throw(type_error(atom, Name)) ),
    atom_string(Name, Text),
    string_list(Text, Codes),
    ( Codes = [_|_], checklist(header_name_code, Codes) -> true
    ; throw(domain_error(http_header_name, Name)) ),
    string_lower(Text, Lower),
    string_list(Lower, LowerCodes),
    ( foreach(Code, LowerCodes), foreach(CanonicalCode, CanonicalCodes) do
        ( Code =:= 95 -> CanonicalCode = 45 ; CanonicalCode = Code ) ),
    string_list(Canonical, CanonicalCodes),
    ( reserved_header(Canonical) -> throw(permission_error(set, proxy_header, Name))
    ; true ).

header_name_code(C) :-
    ( C >= 65, C =< 90 ; C >= 97, C =< 122 ; C >= 48, C =< 57
    ; memberchk(C, [33,35,36,37,38,39,42,43,45,46,94,95,96,124,126]) ).

reserved_header(Name) :-
    memberchk(Name, ["x-forwarded-for", "x-real-ip", "x-web-prolog-user",
        "x-web-prolog-principal", "x-authenticated-user", "x-web-prolog-capabilities",
        "x-web-prolog-caps", "x-web-prolog-internal-proxy", "x-web-prolog-query-budget",
        "x-web-prolog-proxy-token", "x-web-prolog-client-ip", "x-auth-request-user",
        "x-auth-request-email", "host", "connection", "content-length", "transfer-encoding",
        "upgrade", "proxy-authorization", "proxy-connection", "te", "trailer", "keep-alive"]).

header_value(Value, Text) :-
    required_value(Value),
    ( acyclic_term(Value) -> true ; throw(representation_error(cyclic_term)) ),
    ( Value == [] -> Text = ""
    ; atom(Value) -> atom_string(Value, Text)
    ; string(Value) -> Text = Value
    ; header_char_list(Value, Value), text_string(Value, Text) -> true
    ; throw(type_error(atom_or_string, Value)) ),
    ( string_list(Text, Codes, utf8), checklist(header_value_code, Codes) -> true
    ; throw(domain_error(http_header_value, Value)) ).

header_char_list(List, Original) :-
    required_value(List),
    ( List == [] -> true
    ; List = [Char|Rest] ->
        required_value(Char),
        ( atom(Char), Char \== [], text_string([Char], _) -> header_char_list(Rest, Original)
        ; throw(type_error(atom_or_string, Original)) )
    ; throw(type_error(atom_or_string, Original)) ).

header_value_code(C) :-
    ( C =:= 9 ; C >= 32, C =\= 127 ).

http_field(request_header(Name=Value), [Key, Text]) :-
    atom_string(Name, Original), string_lower(Original, Key),
    header_value(Value, Text).
http_field(user_agent(Value), ["user-agent", Text]) :- header_value(Value, Text).
http_field(authorization(bearer(Token)), ["authorization", Value]) :-
    header_value(Token, Text), concat_string(["Bearer ", Text], Value).
http_field(authorization(basic(User, Password)), ["authorization", "basic", U, P]) :-
    header_value(User, U), header_value(Password, P).

option_value(Name, Options, Default, Value) :-
    Option =.. [Name, Found],
    ( memberchk(Option, Options) -> Value = Found ; Value = Default ).

query_page(Node, Goal, Template, Source, Offset, Limit, Once, Answer) :-
    query_page(Node, Goal, Template, Source, Offset, Limit, Once,
               transport(none, none, []), Answer).

query_page("localhost", Goal, Template, Source, Offset, Limit, Once,
           transport(Execution, HTTP, _), Answer) :- !,
    request_wait(HTTP, 3, Wait),
    elapsed(Start),
    stateless_spawn_options(Source, Execution, Options),
    setup_call_cleanup(
        toplevel_spawn(Pid, Options),
        local_call_page(Pid, Goal, Template, Offset, Limit, Once, HTTP, Start, Wait, Answer),
        exit(Pid, query_finished)
    ).
query_page(Node, Goal, Template, Source, Offset, Limit, Once, Transport, Answer) :-
    Transport = transport(Execution, HTTP, Fields),
    request_wait(HTTP, 2.5, Wait),
    goal_template_texts(Goal, Template, GoalText, TemplateText),
    Params = [goal:GoalText, template:TemplateText, src_text:Source,
              offset:Offset, limit:Limit, once:Once, headers:Fields],
    optional_param(timeout, Execution, Params, WithExecution),
    optional_param(http_timeout, HTTP, WithExecution, Request),
    egress_request("call", Node, Request, Wait, Body),
    ( setup_call_cleanup(open(string(Body), read, Stream),
          ( read(Stream, Answer), read(Stream, end_of_file), at_eof(Stream) ),
          close(Stream)),
      valid_answer(Answer) -> true
    ; throw(error(invalid_rpc_response, rpc/3))
    ).

% Bound the caller even if the host is still resolving or connecting.
request_wait(none, Default, Default) :- !.
request_wait(HTTP, Default, Wait) :-
    ( HTTP =:= 0 -> throw(error(rpc_error(http_timeout), rpc/3)) ; true ),
    Wait is min(HTTP, Default).

optional_param(_, none, Params, Params) :- !.
optional_param(Name, Value, Params, [Name:Value|Params]).

stateless_spawn_options(Source, none, [src_text(Source)]) :- !.
stateless_spawn_options(Source, Requested, [src_text(Source), time_limit(Limit)]) :-
    ( Requested =:= 0 -> throw(error(resource_error(time), rpc/3)) ; true ),
    Limit is min(Requested, 2.5).

valid_answer(Answer) :-
    nonvar(Answer),
    ( Answer == failure
    ; Answer = error(_)
    ; Answer = success(Rows, More), is_list(Rows), ( More == true ; More == false )
    ), !.

call_page(Pid, Goal, Template, Offset, Limit, Once, Answer) :-
    submit_call_page(Pid, Goal, Template, Offset, Limit, Once),
    await_call_page(Pid, Answer).

local_call_page(Pid, Goal, Template, Offset, Limit, Once, none, _, _, Answer) :- !,
    call_page(Pid, Goal, Template, Offset, Limit, Once, Answer).
local_call_page(Pid, Goal, Template, Offset, Limit, Once, _, Start, Wait, Answer) :-
    elapsed(Now),
    Remaining is Start + Wait - Now,
    ( Remaining > 0 ->
        submit_call_page(Pid, Goal, Template, Offset, Limit, Once),
        await_call_page(Pid, Remaining, error(rpc_error(http_timeout), rpc/3), Answer)
    ; throw(error(rpc_error(http_timeout), rpc/3)) ).

submit_call_page(Pid, Goal, Template, Offset, Limit, Once) :-
    toplevel_call(Pid, Goal, [template(Template), offset(Offset),
                             limit(Limit), once(Once)]).

await_call_page(Pid, Answer) :-
    await_call_page(Pid, 3, time_limit_exceeded, Answer).

await_call_page(Pid, Wait, OnTimeout, Answer) :-
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
    }, [timeout(Wait), on_timeout(Answer = error(OnTimeout))]).

egress_request(Operation, Url, Params, Body) :-
    egress_request(Operation, Url, Params, 2.5, Body).

egress_request(Operation, Url, Params, Timeout, Body) :-
    self(Id),
    store_get(egress, counter, Counter),
    shelf_inc_and_get(Counter, 1, Key),
    ( Params == [] -> JSON = {} ; JSON = {Params} ),
    send(main, http_egress(Key, Id, Operation, Url, JSON)),
    receive({
        http_egress_result(Key, "ok", Text) -> Body = Text
    ;
        http_egress_result(Key, "error", Reason) ->
            ( Reason == "http_timeout" -> Error = http_timeout ; Error = Reason ),
            throw(error(rpc_error(Error), rpc/3))
    }, [timeout(Timeout), on_timeout(throw(error(rpc_error(http_timeout), rpc/3)))]).
