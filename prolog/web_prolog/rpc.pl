:- module(rpc,
   [ rpc/2,
     rpc/3,
     promise/3,
     promise/4,
     promise_cleanup/1,
     yield/2,
     yield/3,
     runtime_property/1,
     text_to_string/2,
     normalize_requested_timeout/2,
     normalize_timeout/2,
     normalize_once/2
   ]).

:- dynamic promise_queue_store/2.
:- multifile prepare_timeout_callback/3.

/** <module> Web Prolog RPC Client (layer 3, HTTP-only)

Client-side stateless RPC and async promise/yield over a node's
`/call` endpoint.  Needs only the HTTP client — no actors, no
WebSocket; loadable on its own next to bare actors.pl.

  - stateless RPC (`rpc/2-3`),
  - async Promise/Yield (`promise/3-4`, `yield/2-3`, `promise_cleanup/1`),
  - shared text/timeout/boolean normalization helpers.

Note on Promise cleanup: Each call to `promise/3-4` creates an internal
message queue stored in a dynamic predicate. Collection removes its lookup
entry; a timed-out yield retains it for retry. Coordinated reclamation of
queues/workers and concurrent collection/expiry remain lifecycle work.
`promise_cleanup/1` removes the lookup entry when a caller abandons a promise.
*/

:- use_module(pid_utils, [localhost_node/1]).
:- use_module(isolation, [load_options_text/3, prepared_goal/3]).

:- use_module(library(apply)).
:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(library(random)).
:- use_module(library(crypto)).
:- use_module(library(http/http_open)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(url)).
:- use_module(library(debug)).
:- use_module(source_utils, [uri_atom/2]).
:- use_module(wire_text, [terms_to_wire_texts/2, wire_read_options/1]).

solution_limit(Options, Limit) :-
    ( option(limit(Limit), Options) -> must_be(positive_integer, Limit)
    ; Limit = none
    ).

%!  runtime_property(?Property) is nondet.
%
%   Describe host properties outside the portable Web Prolog profile
%   contract. Portable code should not need these; applications may inspect
%   them before relying on persistence, inbound addressability, DOM access,
%   or a particular actor-isolation mechanism.
runtime_property(implementation(swi_native)).
runtime_property(persistent(true)).
runtime_property(inbound_addressable(true)).
runtime_property(dom(false)).
runtime_property(actor_isolation(native_thread)).
runtime_property(hard_termination(true)).

:- meta_predicate
    rpc(+, :),
    rpc(+, :, +),
    promise(+, :, -),
    promise(+, :, -, +),
    yield(+, -, :).

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
    goal_template_texts(Goal, Template, GoalAtom, TemplateAtom),
    solution_limit(Options0, Limit),
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
    once(( http_current_server(user:Dispatcher, PortSpec),
           Dispatcher == http_dispatch
         )),
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
    http_read_answer(ExpandedURI, Options, Answer),
    rpc(Answer, Template, Offset, Limit, GoalAtom, TemplateAtom, Parts,
        Options, LoadText, RemoteTimeout, Once).

%!  goal_template_texts(+Goal, +Template, -GoalAtom, -TemplateAtom) is det.
%
%   Write Goal and Template as canonical term text (see wire_text.pl),
%   each in parentheses, with shared variable names so that the node,
%   which reads them together, restores their shared variables.
goal_template_texts(Goal, Template, GoalAtom, TemplateAtom) :-
    terms_to_wire_texts([Goal, Template], [GoalText, TemplateText]),
    format(atom(GoalAtom), "(~w)", [GoalText]),
    format(atom(TemplateAtom), "(~w)", [TemplateText]).

%!  http_read_answer(+URI, +Options, -Answer) is det.
%
%   Open URI and read one answer term.  The request is made in the body of
%   call_cleanup/2, not in a setup goal: SWI-Prolog protects setup goals
%   from signals, so a slow or silent remote node would otherwise delay
%   abort, halt and exit signals until it replied.  The stream is closed in
%   cleanup only if it was actually opened.

http_read_answer(URI, Options, Answer) :-
    Holder = stream(none),
    call_cleanup(
        (   http_open(URI, Stream, Options),
            nb_setarg(1, Holder, Stream),
            wire_read_options(ReadOptions),
            read_term(Stream, Answer, ReadOptions)
        ),
        close_held_stream(Holder)).

close_held_stream(stream(Stream)) :-
    (   Stream == none
    ->  true
    ;   close(Stream, [force(true)])
    ).

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
               offset=Offset, format=prolog],
    append_optional_param(Search0, limit, Limit, SearchLimit),
    append_optional_param(SearchLimit, src_text, LoadText, Search1),
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
rpc_internal_option(template(_)).
rpc_internal_option(offset(_)).
rpc_internal_option(timeout(_)).
rpc_internal_option(http_timeout(_)).
rpc_internal_option(src_text(_)).
rpc_internal_option(src_list(_)).
rpc_internal_option(src_uri(_)).
rpc_internal_option(src_predicates(_)).
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
%   Remove an unconsumed promise lookup after the retention interval.
%   This does not reclaim its queue/worker or cancel the remote request.
promise_auto_cleanup_thread(QueueKey, TimeoutSeconds) :-
    sleep(TimeoutSeconds),
    retractall(promise_queue_store(QueueKey, _)).

%!  promise_cleanup(+Reference) is det.
%   Remove the lookup entry for an abandoned promise. Queue/worker
%   reclamation remains separate lifecycle work.
promise_cleanup(Reference) :-
    must_be(integer, Reference),
    promise_queue_key(Reference, QueueKey),
    retractall(promise_queue_store(QueueKey, _)).


%!  promise(+URI, :Goal, -Reference) is det.
%!  promise(+URI, :Goal, -Reference, +Options) is det.
promise(URI, Goal, Reference) :-
    promise(URI, Goal, Reference, []).

promise(URI, Goal0, Reference, Options) :-
    resolve_rpc_uri(URI, RPCURI),
    strip_module(Goal0, GoalModule, Goal),
    option(template(Template), Options, Goal),
    option(offset(Offset), Options, 0),
    solution_limit(Options, Limit),
    option(once(Once0), Options, false),
    normalize_once(Once0, Once),
    option(timeout(RemoteTimeout0), Options, none),
    normalize_requested_timeout(RemoteTimeout0, RemoteTimeout),
    load_options_text(GoalModule, Options, LoadTextString),
    atom_string(LoadText, LoadTextString),
    rpc_http_options(Options, HTTPOptions),
    make_reference(Reference),
    message_queue_create(Queue),
    promise_queue_key(Reference, QueueKey),
    assertz(promise_queue_store(QueueKey, Queue)),
    % Schedule automatic cleanup after 5 minutes (300 seconds) if not consumed
    thread_create(promise_auto_cleanup_thread(QueueKey, 300), _, [detached(true)]),
    thread_create(promise(RPCURI, Goal, Template, Offset, Limit,
                          HTTPOptions, LoadText, RemoteTimeout, Once, Queue),
                  _,
                  [detached(true)]).

promise(URI, Goal, Template, Offset, Limit,
        HTTPOptions, LoadText, RemoteTimeout, Once, Queue) :-
    catch(
        (   once(promise_answer(URI, Goal, Template, Offset, Limit,
                               HTTPOptions, LoadText, RemoteTimeout, Once, Answer))
        ->  Message = Answer
        ;   Message = error(error(promise_worker_failed,
                                  context(rpc:promise/4, 'request produced no answer')))
        ),
        Error, Message = error(Error)),
    % Delivery to a queue already disposed by lifecycle management cannot
    % be recovered here; that is separate from request/response failures.
    catch(thread_send_message(Queue, Message), SendError,
          print_message(warning, SendError)).

promise_answer(URI, Goal, Template, Offset, Limit,
               HTTPOptions, LoadText, RemoteTimeout, Once, Answer) :-
    goal_template_texts(Goal, Template, GoalAtom, TemplateAtom),
    parse_url(URI, Parts),
    rpc_search_params(GoalAtom, TemplateAtom, Offset, Limit,
                      LoadText, RemoteTimeout, Once, Search),
    parse_url(ExpandedURI, [
        path('/call'),
        search(Search)
      | Parts
    ]),
    http_read_answer(ExpandedURI, HTTPOptions, Answer),
    (   valid_promise_answer(Answer)
    ->  true
    ;   throw(error(domain_error(promise_answer, Answer),
                    context(rpc:promise/4, 'expected success(Data,More), failure, or error(Error)')))
    ).

valid_promise_answer(Answer) :-
    nonvar(Answer),
    (   Answer == failure
    ;   Answer = success(Data, More), is_list(Data),
        (More == true ; More == false)
    ;   Answer = error(Error), nonvar(Error)
    ).


%!  yield(+Reference, -Message) is det.
%!  yield(+Reference, -Message, :Options) is det.
yield(Reference, Message) :-
    yield(Reference, Message, []).

yield(Reference, Message, Options0) :-
    must_be(integer, Reference),
    strip_module(Options0, Caller, Options),
    must_be(list, Options),
    promise_queue_key(Reference, QueueKey),
    (   promise_queue_store(QueueKey, Queue)
    ->  exclude(yield_timeout_callback, Options, WaitOptions),
        (   thread_get_message(Queue, Msg, WaitOptions)
        ->  retractall(promise_queue_store(QueueKey, Queue)),
            Message = Msg
        ;   % A timeout leaves the promise available for another attempt.
            yield_timeout(Reference, Message, Caller, Options)
        )
    ;   throw(error(existence_error(promise, Reference),
                    context(rpc:yield/3, 'unknown, consumed, or expired promise')))
    ).

yield_timeout_callback(on_timeout(_)).

yield_timeout(Reference, Message, Caller, Options) :-
    option(on_timeout(Goal), Options, true),
    (   prepare_timeout_callback(Caller, Goal, SafeGoal)
    ->  true
    ;   prepared_goal(Caller, Goal, SafeGoal)
    ),
    (   once(call(Caller:SafeGoal))
    ->  (var(Message) -> Message = timeout ; true)
    ;   throw(error(timeout_callback_failed(Reference),
                    context(rpc:yield/3, 'on_timeout goal failed')))
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


%!  make_reference(-Reference) is det.
%
%   Mint a fresh integer promise reference.  References are
%   rpc-local (they key promise_queue_store/2), so no shared pid
%   machinery is needed; the integer shape is observable through
%   yield/2-3's must_be(integer) check and stays as in the
%   demonstrator.
make_reference(Reference) :-
    with_mutex(rpc_references,
        (   repeat,
            crypto_n_random_bytes(5, Bytes),
            foldl(reference_byte, Bytes, 0, Raw),
            Raw < 1098000000000,
            Reference is 1000000000 + Raw mod 9000000000,
            \+ issued_reference(Reference),
            !,
            assertz(issued_reference(Reference))
        )).

:- dynamic issued_reference/1.
reference_byte(Byte, Acc, Next) :- Next is Acc * 256 + Byte.
