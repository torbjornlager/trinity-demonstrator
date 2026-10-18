:- module(rpc,
   [ rpc/2,
     rpc/3,
     promise/3,
     promise/4,
     promise_cleanup/1,
     dispose_promises_for_owner/1,
     yield/2,
     yield/3,
     runtime_property/1,
     text_to_string/2,
     normalize_requested_timeout/2,
     normalize_timeout/2,
     normalize_once/2
   ]).

:- dynamic promise_state/7. % Key, WakeQueue, Worker, ExpiryThread, Collector, Result, Owner
:- multifile prepare_timeout_callback/3, hook_promise_owner/1,
             hook_check_promise_owner/1.

/** <module> Web Prolog RPC Client (layer 3, HTTP-only)

Client-side stateless RPC and async promise/yield over a node's
`/call` endpoint.  Needs only the HTTP client — no actors, no
WebSocket; loadable on its own next to bare actors.pl.

  - stateless RPC (`rpc/2-3`),
  - async Promise/Yield (`promise/3-4`, `yield/2-3`, `promise_cleanup/1`),
  - shared text/timeout/boolean normalization helpers.

Promise collection, expiry and explicit cleanup share promise_lifecycle.
Answers stay in the record until consumed; the private queue only wakes a
collector. Timed-out or interrupted waits release their collection claim.
Disposal destroys the queue and stops local worker/expiry threads. This does
not cancel execution on the remote node. Node composition scopes ownership to
client namespaces or stateless HTTP identities; standalone use remains shared.
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
    validate_client_options(rpc, Options0),
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
        % A page may be short while retaining a continuation (e.g. an error).
        length(Slice, Count),
        NewOffset is Offset + Count,
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

% Validate the whole list before URI resolution, source fetching, worker
% creation, or waiting. Inspect option names without instantiating user terms;
% in particular template/1 and on_timeout/1 must retain variable sharing.
validate_client_options(Kind, Options) :-
    client_option_context(Kind, PI),
    catch((must_be(list, Options),
           maplist(validate_client_option(Kind), Options)),
          error(Formal, _),
          throw(error(Formal, context(PI, 'invalid client option')))).

client_option_context(rpc, rpc:rpc/3).
client_option_context(promise, rpc:promise/4).
client_option_context(yield, rpc:yield/3).

validate_client_option(Kind, Option) :-
    must_be(nonvar, Option),
    (   compound(Option), compound_name_arity(Option, Name, 1),
        client_option_type(Kind, Name, Type)
    ->  arg(1, Option, Value),
        validate_client_value(Type, Value)
    ;   atom_concat(Kind, '_option', Domain),
        domain_error(Domain, Option)
    ).

client_option_type(rpc, Name, Type) :- query_option_type(Name, Type).
client_option_type(promise, template, template).
client_option_type(promise, offset, nonneg).
client_option_type(promise, Name, Type) :- query_option_type(Name, Type).
client_option_type(yield, timeout, number).
client_option_type(yield, on_timeout, callable).

query_option_type(limit, positive_integer).
query_option_type(once, boolean).
query_option_type(timeout, remote_timeout).
query_option_type(http_timeout, number).
query_option_type(src_text, source_text).
query_option_type(src_list, list).
query_option_type(src_uri, atom_or_string).
query_option_type(src_predicates, predicate_indicators).
query_option_type(request_header, request_header).
query_option_type(authorization, authorization).
query_option_type(user_agent, atom_or_string).

validate_client_value(template, _) :- !.
validate_client_value(remote_timeout, Value) :- !,
    % Preserve the existing unspecified-timeout and negative-timeout rules.
    normalize_requested_timeout(Value, _).
validate_client_value(boolean, Value) :- !,
    must_be(nonvar, Value), normalize_once(Value, _).
validate_client_value(source_text, Value) :- !,
    % Keep the demonstrator's existing atom/string/codes/chars convention.
    system:text_to_string(Value, _).
validate_client_value(atom_or_string, Value) :- !,
    must_be(nonvar, Value),
    (atom(Value) -> true ; string(Value) -> true ; type_error(atom_or_string, Value)).
validate_client_value(predicate_indicators, Value) :- !,
    must_be(list, Value), maplist(validate_client_pi, Value).
validate_client_value(request_header, Value) :- !,
    must_be(nonvar, Value),
    (   compound(Value), compound_name_arity(Value, '=', 2)
    ->  arg(1, Value, Name), arg(2, Value, Text),
        must_be(atom, Name), validate_client_value(atom_or_string, Text)
    ;   type_error(http_request_header, Value)
    ).
validate_client_value(authorization, Value) :- !,
    must_be(nonvar, Value),
    (   compound(Value), compound_name_arity(Value, basic, 2)
    ->  arg(1, Value, User), arg(2, Value, Password),
        validate_client_value(atom_or_string, User),
        validate_client_value(atom_or_string, Password)
    ;   compound(Value), compound_name_arity(Value, bearer, 1)
    ->  arg(1, Value, Token), validate_client_value(atom_or_string, Token)
    ;   domain_error(http_authorization, Value)
    ).
validate_client_value(Type, Value) :- must_be(Type, Value).

validate_client_pi(PI) :-
    must_be(nonvar, PI),
    (   compound(PI), compound_name_arity(PI, '/', 2)
    ->  arg(1, PI, Name), arg(2, PI, Arity),
        must_be(atom, Name), must_be(nonneg, Arity)
    ;   type_error(predicate_indicator, PI)
    ).

%!  rpc_http_options(+Options0, -HTTPOptions) is det.
rpc_http_options(Options0, HTTPOptions) :-
    (   select_option(http_timeout(HTTPTimeout0), Options0, Options1)
    ->  normalize_timeout(HTTPTimeout0, HTTPTimeout),
        HTTPPrefix = [timeout(HTTPTimeout)]
    ;   Options1 = Options0,
        HTTPPrefix = []
    ),
    include(rpc_transport_option, Options1, HTTPFiltered),
    append(HTTPPrefix, HTTPFiltered, HTTPOptions).

rpc_transport_option(request_header(_)).
rpc_transport_option(authorization(_)).
rpc_transport_option(user_agent(_)).

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


% Resource creation is protected from asynchronous interruption. Threads
% enter through the same mutex, after their handles have been recorded.
start_promise(Reference, WorkerGoal) :-
    promise_queue_key(Reference, Key),
    setup_call_catcher_cleanup(
        with_mutex(promise_lifecycle,
            (   new_promise_state(Key, _),
                catch(start_promise_threads(Key, WorkerGoal), Error,
                      (dispose_promise_locked(Key), throw(Error)))
            )),
        true,
        Catcher,
        (Catcher == exit -> true; promise_cleanup(Reference))).

new_promise_state(Key, Queue) :-
    promise_owner_context(Owner),
    (Owner == unavailable
    -> throw(error(permission_error(create,promise,client_context),
                   context(rpc:promise/4, 'public execution has no client identity')))
    ; true),
    % Called under promise_lifecycle. The node checks namespace admission
    % without acquiring actors_registry: teardown closes admission first,
    % then takes promise_lifecycle to sweep, in registry -> promise order.
    forall(hook_check_promise_owner(Owner), true),
    message_queue_create(Queue),
    catch(assertz(promise_state(Key,Queue,none,none,none,pending,Owner)), Error,
          (message_queue_destroy(Queue), throw(Error))).

start_promise_threads(Key, WorkerGoal) :-
    must_be(callable, WorkerGoal),
    thread_create(promise_thread(Key,worker,WorkerGoal), Worker, [detached(true)]),
    retract(promise_state(Key,Q,none,none,C,R,Owner)),
    assertz(promise_state(Key,Q,starting(Worker),none,C,R,Owner)),
    thread_create(promise_thread(Key,timer,rpc:promise_auto_cleanup_thread(Key,300)), Timer, [detached(true)]),
    retract(promise_state(Key,Q,starting(Worker),none,C,R,Owner)),
    assertz(promise_state(Key,Q,starting(Worker),starting(Timer),C,R,Owner)).

promise_thread(Key, Role, Goal) :-
    catch(
        (promise_transaction(activate_promise_thread(Key,Role,Active)),
         (Active == true -> call(Goal); true)),
        '$rpc_promise_disposed', true).

activate_promise_thread(Key, Role, Active) :-
    (   retract(promise_state(Key,Q,W0,T0,C,R,Owner))
    ->  (Role == worker -> W0 = starting(Thread), W = running(Thread), T = T0
        ; T0 = starting(Thread), T = running(Thread), W = W0),
        assertz(promise_state(Key,Q,W,T,C,R,Owner)), Active = true
    ;   Active = false
    ).

:- meta_predicate promise_transaction(0).
% Commit only short local operations here; never protect an HTTP read or wait
% from signals. An interrupted collector cannot leave half-disposed state.
promise_transaction(Goal) :-
    setup_call_cleanup(with_mutex(promise_lifecycle, Goal), true, true).

promise_auto_cleanup_thread(Key, Seconds) :-
    (   with_mutex(promise_lifecycle, promise_state(Key,_,_,_,_,_,_))
    ->  sleep(Seconds),
        promise_transaction(dispose_promise_locked(Key))
    ;   true
    ).

%!  promise_cleanup(+Reference) is det.
%   Idempotent local disposal; does not establish remote cancellation.
promise_cleanup(Reference) :-
    must_be(integer, Reference),
    promise_queue_key(Reference, Key),
    promise_transaction(
        (promise_accessible(Key) -> dispose_promise_locked(Key); true)).

% The node supplies client identity; without that composition, local threads
% and actors keep their historical sharing. Owner keys must be ground and
% compared by identity, never unified with another client's key.
promise_owner_context(Owner) :-
    (hook_promise_owner(Key) -> must_be(ground,Key), Owner = Key
    ; Owner = trusted_local).

promise_accessible(Key) :-
    promise_owner_context(Current), Current \== unavailable,
    promise_state(Key,_,_,_,_,_,Stored), Stored == Current.

%!  dispose_promises_for_owner(+OwnerPattern) is det.
%
%   Runtime-only teardown, independent of the calling client's identity.
%   Patterns support sweeping all delegated namespaces of one connection.
dispose_promises_for_owner(OwnerPattern) :-
    promise_transaction(
        (findall(Key,
             (promise_state(Key,_,_,_,_,_,Owner),
              subsumes_term(OwnerPattern,Owner)), Keys),
         maplist(dispose_promise_locked,Keys))).

dispose_promise_locked(Key) :-
    (   retract(promise_state(Key,Queue,Worker,Timer,_,_,_))
    ->  message_queue_destroy(Queue),
        stop_promise_thread(Timer), stop_promise_thread(Worker)
    ;   true
    ).

stop_promise_thread(none) :- !.
% A starting thread checks for the record after installing its handler.
stop_promise_thread(starting(_)) :- !.
stop_promise_thread(running(Thread)) :-
    thread_self(Self),
    (   Thread == Self -> true
    ;   catch(thread_signal(Thread, throw('$rpc_promise_disposed')),
              error(existence_error(thread,_),_), true)
    ).

% Completion and disposal serialize: a retired worker cannot deliver to a
% destroyed queue. The answer survives a collector interrupted after wakeup.
deliver_promise_answer(Key, Answer) :-
    promise_transaction(
        (   retract(promise_state(Key,Q,W,T,C,pending,Owner))
        ->  assertz(promise_state(Key,Q,W,T,C,ready(Answer),Owner)),
            thread_send_message(Q, ready)
        ;   true
        )).


%!  promise(+URI, :Goal, -Reference) is det.
%!  promise(+URI, :Goal, -Reference, +Options) is det.
promise(URI, Goal, Reference) :-
    promise(URI, Goal, Reference, []).

promise(URI, Goal0, Reference, Options) :-
    validate_client_options(promise, Options),
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
    promise_queue_key(Reference, Key),
    start_promise(Reference,
        rpc:promise_worker(Key,RPCURI,Goal,Template,Offset,Limit,
                           HTTPOptions,LoadText,RemoteTimeout,Once)).

promise_worker(Key, URI, Goal, Template, Offset, Limit,
               HTTPOptions, LoadText, RemoteTimeout, Once) :-
    (   with_mutex(promise_lifecycle, promise_state(Key,_,_,_,_,_,_))
    ->  catch(
            (   once(promise_answer(URI, Goal, Template, Offset, Limit,
                                   HTTPOptions, LoadText, RemoteTimeout, Once, Answer))
            ->  Message = Answer
            ;   Message = error(error(promise_worker_failed,
                                      context(rpc:promise/4, 'request produced no answer')))
            ),
            Error, Message = error(Error)),
        deliver_promise_answer(Key, Message)
    ;   true
    ).

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
    validate_client_options(yield, Options),
    promise_queue_key(Reference, Key),
    exclude(yield_timeout_callback, Options, WaitOptions),
    setup_call_cleanup(
        with_mutex(promise_lifecycle, claim_promise(Reference,Key,Queue,Claim,Ready)),
        wait_for_promise(Reference,Key,Queue,Claim,Ready,WaitOptions,Outcome),
        with_mutex(promise_lifecycle, release_promise_claim(Key,Claim))),
    (   Outcome = answer(Answer) -> Message = Answer
    ;   yield_timeout(Reference, Message, Caller, Options)
    ).

claim_promise(Reference, Key, Queue, Claim, Ready) :-
    (   promise_accessible(Key),
        promise_state(Key,Queue,W,T,Collector,Result,Owner)
    ->  (   Collector == none
        ->  flag(promise_collector_counter, N, N+1), Claim = collector(N),
            retract(promise_state(Key,Queue,W,T,none,Result,Owner)),
            assertz(promise_state(Key,Queue,W,T,Claim,Result,Owner)),
            (Result = ready(_) -> Ready = true; Ready = false)
        ;   throw(error(permission_error(collect,promise,Reference),
                        context(rpc:yield/3, 'collection already in progress')))
        )
    ;   missing_promise(Reference)
    ).

wait_for_promise(Reference, Key, Queue, Claim, Ready, Options, Outcome) :-
    (   Ready == true -> true
    ;   catch(ignore(thread_get_message(Queue,ready,Options)), Error,
              promise_wait_error(Reference,Key,Error))
    ),
    promise_transaction(
        (   promise_state(Key,_,_,_,Claim,Result,_)
        ->  (   Result = ready(Answer)
            ->  dispose_promise_locked(Key), Outcome = answer(Answer)
            ;   Outcome = timeout
            )
        ;   missing_promise(Reference)
        )).

promise_wait_error(Reference, Key, Error) :-
    with_mutex(promise_lifecycle,
        (promise_state(Key,_,_,_,_,_,_) -> throw(Error); missing_promise(Reference))).

release_promise_claim(Key, Claim) :-
    (   retract(promise_state(Key,Q,W,T,Claim,Result,Owner))
    ->  assertz(promise_state(Key,Q,W,T,none,Result,Owner))
    ;   true
    ).

missing_promise(Reference) :-
    throw(error(existence_error(promise, Reference),
                context(rpc:yield/3, 'unknown, consumed, or expired promise'))).

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
%   rpc-local (they key promise_state/7), so no shared pid
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
