:- module(node_client,
   [ rpc/2,
     rpc/3,
     promise/3,
     promise/4,
     promise_cleanup/1,
     yield/2,
     yield/3,
     text_to_string/2,
     normalize_requested_timeout/2,
     normalize_timeout/2,
     normalize_once/2
   ]).

:- dynamic promise_queue_store/2.

/** <module> Node RPC/Promise Client Helpers

Client-side predicates used by `node.pl`:

  - stateless RPC (`rpc/2-3`),
  - async Promise/Yield (`promise/3-4`, `yield/2-3`, `promise_cleanup/1`),
  - shared text/timeout/boolean normalization helpers.

Note on Promise cleanup: Each call to `promise/3-4` creates an internal
message queue stored in a dynamic predicate. Cleanup is guaranteed to happen
whenever `yield/2-3` is called, even if it fails or times out. The only case
where manual `promise_cleanup/1` is needed is if `yield` is never called at all.
*/

:- use_module(actor, [make_id/1]).
:- use_module(pid_utils, [localhost_node/1]).
:- use_module(source_loader, [load_options_text/3]).

:- use_module(library(apply)).
:- use_module(library(option)).
:- use_module(library(http/http_open)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(url)).
:- use_module(library(debug)).
:- use_module(source_utils, [uri_atom/2]).

:- debug.

:- meta_predicate
    rpc(+, :),
    rpc(+, :, +).

%!  rpc(+URI, :Goal) is nondet.
%!  rpc(+URI, :Goal, +Options) is nondet.
%
%   Nondeterministic remote procedure call over stateless HTTP.
rpc(URI, Goal) :-
    rpc(URI, Goal, []).

rpc(URI, Goal0, Options0) :-
    resolve_rpc_uri(URI, RPCURI),
    strip_module(Goal0, GoalModule, Goal),
    parse_url(RPCURI, Parts),
    term_variables(Goal, Vars),
    Template =.. [v|Vars],
    format(atom(GoalAtom), "(~p)", [Goal]),
    format(atom(TemplateAtom), "(~p)", [Template]),
    option(limit(Limit), Options0, 10 000 000 000),
    option(once(Once0), Options0, false),
    normalize_once(Once0, Once),
    option(timeout(RemoteTimeout0), Options0, none),
    normalize_requested_timeout(RemoteTimeout0, RemoteTimeout),
    load_options_text(GoalModule, Options0, LoadTextString),
    atom_string(LoadText, LoadTextString),
    rpc_http_options(Options0, HTTPOptions),
    rpc(Template, 0, Limit, GoalAtom, TemplateAtom, Parts,
        HTTPOptions, LoadText, RemoteTimeout, Once).

%!  resolve_rpc_uri(+URI0, -URI) is det.
resolve_rpc_uri(Host:Port, URI) :-
    !,
    format(atom(URI), 'http://~w:~w', [Host, Port]).
resolve_rpc_uri(URI0, URI) :-
    uri_atom(URI0, URIAtom),
    (   uri_has_scheme(URIAtom)
    ->  URI = URIAtom
    ;   localhost_node(URIAtom)
    ->  local_rpc_base_uri(URI)
    ;   URI = URIAtom
    ).

uri_has_scheme(URI) :-
    sub_atom(URI, _, 3, _, '://').

local_rpc_base_uri(URI) :-
    (   current_rpc_server_port(Port)
    ->  true
    ;   Port = none
    ),
    (   Port == none
    ->  URI = 'http://localhost'
    ;   format(atom(URI), 'http://localhost:~w', [Port])
    ).

current_rpc_server_port(Port) :-
    once(http_current_server(node:http_dispatch, PortSpec)),
    local_server_port(PortSpec, Port).
current_rpc_server_port(Port) :-
    once(http_current_server(http_dispatch, PortSpec)),
    local_server_port(PortSpec, Port).

local_server_port(_Host:Port, Port) :-
    !.
local_server_port(Port, Port).

%!  rpc(+Template, +Offset, +Limit, +GoalAtom, +TemplateAtom,
%!      +URLParts, +HTTPOptions, +LoadText, +RemoteTimeout, +Once) is nondet.
rpc(Template, Offset, Limit, GoalAtom, TemplateAtom, Parts,
    Options, LoadText, RemoteTimeout, Once) :-
    rpc_search_params(GoalAtom, TemplateAtom, Offset, Limit,
                      LoadText, RemoteTimeout, Once, Search),
    parse_url(ExpandedURI, [
        path('/call'),
        search(Search)
      | Parts
    ]),
    setup_call_cleanup(
        http_open(ExpandedURI, Stream, Options),
        read(Stream, Answer),
        close(Stream)),
    rpc(Answer, Template, Offset, Limit, GoalAtom, TemplateAtom, Parts,
        Options, LoadText, RemoteTimeout, Once).

rpc(success(Slice, true), Template, Offset, Limit, GoalAtom, TemplateAtom,
    Parts, Options, LoadText, RemoteTimeout, Once) :-
    !,
    (   member(Template, Slice)
    ;   Once == false,
        NewOffset is Offset + Limit,
        debug(node(rpc), 'New HTTP request from offset ~w', [NewOffset]),
        rpc(Template, NewOffset, Limit, GoalAtom, TemplateAtom, Parts,
            Options, LoadText, RemoteTimeout, Once)
    ).
rpc(success(Slice, false), Template, _, _, _, _, _, _, _, _, _) :-
    member(Template, Slice).
rpc(failure, _, _, _, _, _, _, _, _, _, _) :- fail.
rpc(error(Error), _, _, _, _, _, _, _, _, _, _) :- throw(Error).

%!  rpc_search_params(+GoalAtom, +TemplateAtom, +Offset, +Limit,
%!                    +LoadText, +RemoteTimeout, +Once, -Search) is det.
rpc_search_params(GoalAtom, TemplateAtom, Offset, Limit,
                  LoadText, RemoteTimeout, Once, Search) :-
    Search0 = [goal=GoalAtom, template=TemplateAtom,
               offset=Offset, limit=Limit, format=prolog],
    append_optional_param(Search0, load_text, LoadText, Search1),
    append_optional_param(Search1, timeout, RemoteTimeout, Search2),
    append_optional_param(Search2, once, Once, Search).

%!  rpc_http_options(+Options0, -HTTPOptions) is det.
rpc_http_options(Options0, HTTPOptions) :-
    (   select_option(http_timeout(HTTPTimeout0), Options0, Options1)
    ->  normalize_timeout(HTTPTimeout0, HTTPTimeout),
        HTTPPrefix = [timeout(HTTPTimeout)]
    ;   Options1 = Options0,
        HTTPPrefix = []
    ),
    exclude(rpc_internal_option, Options1, HTTPFiltered),
    append(HTTPPrefix, HTTPFiltered, HTTPOptions).

rpc_internal_option(limit(_)).
rpc_internal_option(timeout(_)).
rpc_internal_option(http_timeout(_)).
rpc_internal_option(load_text(_)).
rpc_internal_option(load_list(_)).
rpc_internal_option(load_uri(_)).
rpc_internal_option(load_predicates(_)).
rpc_internal_option(once(_)).

%!  append_optional_param(+Search0, +Key, +Value, -Search) is det.
append_optional_param(Search, _, '', Search) :- !.
append_optional_param(Search, _, none, Search) :- !.
append_optional_param(Search, _, false, Search) :- !.
append_optional_param(Search0, Key, Value, Search) :-
    append(Search0, [Key=Value], Search).

%!  text_to_string(+TextLike, -Text:string) is det.
text_to_string(Text, Text) :-
    string(Text),
    !.
text_to_string(TextAtom, Text) :-
    atom(TextAtom),
    atom_string(TextAtom, Text).


%!  promise_queue_key(+Reference, -QueueKey) is det.
promise_queue_key(Reference, QueueKey) :-
    atomic_list_concat([promise_queue_, Reference], QueueKey).


%!  promise_auto_cleanup_thread(+QueueKey, +TimeoutSeconds) is det.
%   Background thread that auto-cleans a promise queue after the timeout.
%   If yield consumed it, the fact won't exist. If not, we clean it up.
promise_auto_cleanup_thread(QueueKey, TimeoutSeconds) :-
    sleep(TimeoutSeconds),
    retractall(promise_queue_store(QueueKey, _)).

%!  promise_cleanup(+Reference) is det.
%   Clean up the message queue and internal state for a promise.
%   Only needed if yield/2-3 was never called (normally auto-cleanup handles this).
promise_cleanup(Reference) :-
    must_be(integer, Reference),
    promise_queue_key(Reference, QueueKey),
    retractall(promise_queue_store(QueueKey, _)).


%!  promise(+URI, :Goal, -Reference) is det.
%!  promise(+URI, :Goal, -Reference, +Options) is det.
promise(URI, Goal, Reference) :-
    promise(URI, Goal, Reference, []).

promise(URI, Goal, Reference, Options) :-
    make_id(Reference),
    message_queue_create(Queue),
    promise_queue_key(Reference, QueueKey),
    assertz(promise_queue_store(QueueKey, Queue)),
    % Schedule automatic cleanup after 5 minutes (300 seconds) if not consumed
    thread_create(promise_auto_cleanup_thread(QueueKey, 300), _, [detached(true)]),
    option(template(Template), Options, Goal),
    option(offset(Offset), Options, 0),
    option(limit(Limit), Options, 10000000000),
    thread_create(promise(URI, Goal, Template, Offset, Limit, Reference, Queue),
                  _,
                  [detached(true)]).

promise(URI, Goal, Template, Offset, Limit, _Reference, Queue) :-
    format(atom(GoalTemplateAtom), "(~p)$@$(~p)", [Goal, Template]),
    atomic_list_concat([GoalAtom, TemplateAtom], $@$, GoalTemplateAtom),
    parse_url(URI, Parts),
    parse_url(ExpandedURI, [
        path('/call'),
        search([ goal=GoalAtom,
                 template=TemplateAtom,
                 offset=Offset,
                 limit=Limit,
                 format=prolog
               ])
      | Parts
    ]),
    catch((
        setup_call_cleanup(
            http_open(ExpandedURI, Stream, []),
            read(Stream, Message),
            close(Stream)),
        catch(thread_send_message(Queue, Message), SendError,
              format(user_error, 'promise: thread_send_message error: ~w~n', [SendError]))
    ), HTTPError,
        format(user_error, 'promise: HTTP or read error: ~w~n', [HTTPError])).


%!  yield(+Reference, ?Message) is det.
%!  yield(+Reference, ?Message, +Options) is det.
yield(Reference, Message) :-
    must_be(integer, Reference),
    promise_queue_key(Reference, QueueKey),
    setup_call_cleanup(
        promise_queue_store(QueueKey, Queue),
        thread_get_message(Queue, Message),
        retract(promise_queue_store(QueueKey, Queue))
    ).

yield(Reference, Message, Options) :-
    must_be(integer, Reference),
    promise_queue_key(Reference, QueueKey),
    (   promise_queue_store(QueueKey, Queue)
    ->  setup_call_cleanup(
            true,
            (   thread_get_message(Queue, Msg, Options)
            ->  Message = Msg
            ;   option(on_timeout(Goal), Options, fail),
                call(Goal)
            ),
            retract(promise_queue_store(QueueKey, Queue))
        )
    ;   % Promise doesn't exist; treat as immediate timeout
        option(on_timeout(Goal), Options, fail),
        call(Goal)
    ).


%!  normalize_requested_timeout(+RequestedTimeout0, -RequestedTimeout) is det.
normalize_requested_timeout(RequestedTimeout0, none) :-
    var(RequestedTimeout0),
    !.
normalize_requested_timeout(none, none) :-
    !.
normalize_requested_timeout(RequestedTimeout0, RequestedTimeout) :-
    normalize_timeout(RequestedTimeout0, RequestedTimeout).

%!  normalize_timeout(+Timeout0, -Timeout) is det.
normalize_timeout(Timeout0, Timeout) :-
    must_be(number, Timeout0),
    Timeout is max(0, Timeout0).

%!  normalize_once(+Value, -Once:boolean) is det.
normalize_once(true, true) :- !.
normalize_once(false, false) :- !.
normalize_once(Value, _) :-
    throw(error(domain_error(boolean, Value),
                context(node:normalize_once/2,
                        'once must be true or false'))).
