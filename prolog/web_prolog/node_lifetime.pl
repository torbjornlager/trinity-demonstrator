:- module(node_lifetime, [
    with_owner_context/4, with_connection_spawn/1, wrap_actor_context/3,
    check_spawn/1, check_exit/1, check_monitor/1,
    remember_remote/1, remember_route/1, reclaim_lineage/1, check_term/1,
    admit_actor/2, sample_actor_cpu/1, forget_actor/1, deliver_message/3, message_consumed/0,
    command_context/2, with_wire_context/4, connection_owns/2,
    node_log_output/1, current_owner_context/1, rehome_options/2,
    with_websocket_lease/2
]).

/** <module> Principal subtrees and delegated lineage

Pid identity is never authorization. A node records the authority and resource
account of each actor independently of its identifier. Lineage is carried only
on authenticated node transports; browser-supplied lineage is rejected.
*/
:- use_module(library(settings)).
:- use_module(library(option)).
:- use_module(library(error)).
:- use_module(library(aggregate)).
:- use_module(library(crypto)).
:- use_module(library(http/websocket)).
:- use_module(actors, []).
:- use_module(pid_utils, []).
:- use_module(distribution, []).
:- use_module(node_auth, [principal_id/2, principal_has_capability/2]).
:- use_module(node_execution_context, [current_public_execution_profile/1,
                                      current_public_execution_namespace/1,
                                      with_public_execution_namespace/2]).
:- use_module(node_runtime_state, [current_node_port/1, current_node_value/2]).
:- use_module(node_log, [log_event/1]).

:- setting(ws_lease_seconds, number, 30, 'Maximum silent interval on an owning WebSocket').
:- setting(max_principal_actors, integer, 32, 'All live actors and reservations in a principal subtree').
:- setting(max_mailbox_messages, integer, 1024, 'Queued and deferred messages per actor').
:- setting(max_term_depth, integer, 128, 'Maximum actor message and input term depth').
:- setting(principal_cpu_seconds, number, 30, 'Aggregate subtree CPU seconds per window').
:- setting(principal_cpu_window, number, 60, 'CPU accounting window in seconds').

:- dynamic actor_owner/2, mailbox_count/2, principal_lineage/3,
           delegated_route/3, cpu_sample/2, cpu_account/4, cpu_watcher/3.
:- thread_local owner_context/1, connection_spawn/0.
:- dynamic lease_active/1.
:- meta_predicate with_owner_context(+, +, +, 0), with_connection_spawn(0),
                  with_wire_context(+, +, +, 0), with_websocket_lease(+, 0).

scope(Scope) :- (current_node_port(P) -> Scope = node_port(P); Scope = global).

current_owner_context(Context) :- owner_context(Context), !.
current_owner_context(Context) :-
    actors:self(Self), actor_key(Self, Key), actor_owner(Key, Context), !.
current_owner_context(ctx(Scope, public(NS), NS, false, none)) :-
    current_public_execution_profile(_), scope(Scope),
    (current_public_execution_namespace(NS) -> true; NS = anonymous).

with_owner_context(Principal, Carrier, Lineage0, Goal) :-
    principal_id(Principal, PrincipalId), lifetime_id(PrincipalId, Carrier, Id), scope(Scope),
    prune_accounts,
    with_mutex(node_subtree,
        (cpu_account(Scope, Id, _, _) -> true;
         get_time(Now), assertz(cpu_account(Scope, Id, Now, 0)))),
    (   Lineage0 == local
    ->  with_mutex(node_lineage, lineage_for(Scope, tree(Id, Carrier), Lineage))
    ;   Lineage = Lineage0
    ),
    (principal_has_capability(Principal, admin) -> Owner = true; Owner = false),
    Context = ctx(Scope, Id, Lineage, Owner, Carrier),
    setup_call_cleanup(true, with_context(Context, Goal),
                       reclaim_unused_lineage(Context)).

% Anonymous HTTP calls have no authenticated identity to share. Sessions and
% WebSockets use their server-issued carrier; authenticated principals retain
% one account across carriers. These ids are internal resource accounts.
lifetime_id(anonymous, http_call, anonymous(Token)) :- !,
    crypto_n_random_bytes(16, Bytes), phrase(hex_bytes(Bytes), Cs), atom_codes(Token, Cs).
lifetime_id(anonymous, Carrier, anonymous(Carrier)) :- !.
lifetime_id(Id, http_call, anonymous(Token)) :-
    string(Id), sub_string(Id, 0, 5, _, "anon:"), !,
    crypto_n_random_bytes(16, Bytes), phrase(hex_bytes(Bytes), Cs), atom_codes(Token, Cs).
lifetime_id(Id, Carrier, anonymous(Carrier)) :-
    string(Id), sub_string(Id, 0, 5, _, "anon:"), !.
lifetime_id(Id, _, Id).

prune_accounts :-
    get_time(Now),
    with_mutex(node_subtree,
      forall((cpu_account(S, Id, Start, _), scoped_limit(S, principal_cpu_window, W),
              Now - Start >= W, \+ actor_owner(_, ctx(S, Id, _, _, _))),
             (retractall(cpu_account(S, Id, _, _)),
              with_mutex(node_lineage, retractall(principal_lineage(S, account(Id), _)))))).

lineage_for(Scope, Id, Token) :- principal_lineage(Scope, Id, Token), !.
lineage_for(Scope, Id, Token) :-
    crypto_n_random_bytes(16, Bytes),
    phrase(hex_bytes(Bytes), Codes), atom_codes(Token, Codes),
    assertz(principal_lineage(Scope, Id, Token)).
hex_bytes([]) --> [].
hex_bytes([B|Bs]) --> { H is B >> 4, L is B /\ 15,
                       code_type(HC, xdigit(H)), code_type(LC, xdigit(L)) },
                     [HC, LC], hex_bytes(Bs).

with_context(Context, Goal) :-
    setup_call_cleanup(asserta(owner_context(Context), Ref), Goal, erase(Ref)).

with_connection_spawn(Goal) :-
    setup_call_cleanup(asserta(connection_spawn, Ref), Goal, erase(Ref)).

wrap_actor_context(Pid, Start0, Start) :-
    actor_key(Pid, Key), actor_owner(Key, Context),
    Start = node_lifetime:run_owned_actor(Key, Context, Start0).
run_owned_actor(Key, Context, Goal) :-
    thread_self(T), thread_statistics(T, cputime, CPU),
    with_mutex(node_subtree, assertz(cpu_sample(Key, CPU))),
    with_context(Context, call(Goal)).

check_spawn(Options) :-
    (   option(link(false), Options), current_public_execution_profile(_),
        \+ connection_spawn,
        \+ current_owner_context(ctx(_, _, _, true, _))
    ->  throw(error(permission_error(spawn, detached_actor, link(false)),
                    context(actors:spawn/3, 'only the node owner may detach work')))
    ;   true
    ).

actor_key(Pid, Key) :- actors:canonical_pid(Pid, Key).

check_exit(Pid) :-
    (   current_owner_context(ctx(Scope, Id, Lineage, false, Carrier))
    ->  actor_key(Pid, Key),
        (   actor_owner(Key, ctx(Scope, Id, Lineage, false, Carrier))
        ->  true
        ;   local_to_scope(Scope, Key),
            \+ actors:resolve_actor_thread(Key, _), \+ actor_owner(Key, _)
        ->  true
        ;   actors:self(Self), actor_key(Self, Key)
        ->  true
        ;   throw(error(permission_error(exit, actor, Pid),
                        context(actors:exit/2, 'target is outside the caller ownership tree')))
        )
    ;   true
    ).

% Language sends are open; monitors expose only liveness. Raw host aliases
% must never become actor identities through either operation.
check_monitor(Pid) :-
    (   Pid == main; atom(Pid), catch(thread_property(Pid, id(_)), _, fail)
    ), !,
    throw(error(permission_error(monitor, thread, Pid), _)).
check_monitor(_).

admit_actor(LocalPid, Options) :-
    current_owner_context(Context0), !,
    detached_context(Options, Context0, Context),
    actor_key(LocalPid, Key),
    with_mutex(node_subtree,
        (   check_actor_capacity(Context),
            assertz(actor_owner(Key, Context)),
            assertz(mailbox_count(Key, 0))
        )),
    ensure_cpu_watcher(Context).
admit_actor(LocalPid, Options) :-
    option(link(false), Options), !,
    scope(Scope), actor_key(LocalPid, Key),
    assertz(actor_owner(Key, ctx(Scope, node, node, true, none))).
admit_actor(_, _).

detached_context(Options, ctx(S, _, _, true, _), ctx(S, node, node, true, none)) :-
    option(link(false), Options), \+ connection_spawn, !.
detached_context(_, Context, Context).

check_actor_capacity(ctx(Scope, Id, _, false, _)) :- !,
    get_time(Now), scoped_limit(Scope, principal_cpu_window, Window),
    (   cpu_account(Scope, Id, Start, _), Now - Start < Window,
        cpu_exhausted(Scope, Id, true)
    ->  throw(error(resource_error(cpu), _))
    ;   true
    ),
    policy_limit(max_principal_actors, Limit),
    aggregate_all(count,
                  (actor_owner(Key, ctx(Scope, Id, _, false, _)),
                   pid_utils:pid_local(Key, _)), Count),
    (Count < Limit -> true; throw(error(resource_error(actors), _))).
check_actor_capacity(_).

policy_limit(Name, Limit) :-
    (current_node_value(Name, Value) -> Limit = Value; setting(node_lifetime:Name, Limit)).

% Sample while the pid still resolves, but retain authority through retirement.
% Removing ownership first would expose a live-looking, unowned local pid to
% concurrent worker cleanup. Lineage reclamation remains outside actor locks.
sample_actor_cpu(Pid) :-
    actor_key(Pid, Key),
    with_mutex(node_subtree, charge_actor(Key)).

forget_actor(Pid) :-
    actor_key(Pid, Key),
    with_mutex(node_subtree,
        (   findall(Context, actor_owner(Key, Context), Contexts),
            charge_actor(Key),
            retractall(actor_owner(Key, _)),
            with_mutex(node_mailboxes, retractall(mailbox_count(Key, _))),
            retractall(cpu_sample(Key, _))
        )),
    maplist(reclaim_unused_lineage, Contexts).

% The receiver account controls mailbox capacity, even for an owner sender.
% Reservation and enqueue share a mutex; failed delivery rolls it back.
deliver_message(Pid, Thread, Message) :-
    actor_key(Pid, Key), actor_owner(Key, ctx(Scope, _, _, _, _)), !,
    (actors:system_delivery -> true; scoped_limit(Scope, max_term_depth, Depth), check_depth(Message, Depth)),
    with_mutex(node_mailboxes,
        (   scoped_limit(Scope, max_mailbox_messages, Limit),
            (mailbox_count(Key, N) -> true; N = 0),
            (actors:system_delivery -> true; N < Limit -> true; throw(error(resource_error(mailbox), _))),
            catch(thread_send_message(Thread, Message), E, throw(E)),
            retractall(mailbox_count(Key, _)), N1 is N + 1,
            assertz(mailbox_count(Key, N1))
        )).

check_depth(Term, Limit) :-
    (acyclic_term(Term), within_depth(Term, Limit) -> true;
     throw(error(resource_error(term_depth), _))).
within_depth(Term, _) :- var(Term), !.
within_depth(Term, _) :- atomic(Term), !.
within_depth([Head|Tail], Limit) :- !,
    Limit > 0, Next is Limit - 1,
    within_depth(Head, Next), within_list_tail(Tail, Limit).
within_depth(Term, Limit) :-
    Limit > 0, Next is Limit - 1,
    compound_name_arguments(Term, _, Args), maplist(within_depth_(Next), Args).
within_depth_(Depth, Term) :- within_depth(Term, Depth).
within_list_tail(Tail, Depth) :-
    (var(Tail) -> true; Tail == [] -> true;
     Tail = [H|T] -> Next is Depth - 1, within_depth(H, Next), within_list_tail(T, Depth);
     within_depth(Tail, Depth)).

message_consumed :-
    actors:self(Self), actor_key(Self, Key),
    with_mutex(node_mailboxes,
        (   retract(mailbox_count(Key, N))
        ->  N1 is max(0, N - 1), assertz(mailbox_count(Key, N1))
        ;   true
        )).

command_context(Command0, Command) :-
    current_owner_context(ctx(Scope, Id, Lineage, _, _)),
    atom(Lineage), Lineage \== node,
    (   Id = delegated(_, Account)
    ->  true
    ;   with_mutex(node_lineage, lineage_for(Scope, account(Id), Account))
    ),
    put_dict(_{lineage:Lineage, account:Account}, Command0, Command).

with_wire_context(Dict, Queue, Principal, Goal) :-
    (   get_dict(lineage, Dict, Token0)
    ->  (principal_has_capability(Principal, internal_transport) -> true;
         throw(error(permission_error(use, transport_lineage, Token0), _))),
        wire_token(Token0, Token),
        (get_dict(account, Dict, Account0) -> wire_token(Account0, Account); Account = Token),
        principal_id(Principal, Peer),
        scope(Scope),
        with_public_execution_namespace(ws_lineage(Queue, Token),
            with_context(ctx(Scope, delegated(Peer, Account), Token, false, Queue), Goal))
    ;   with_owner_context(Principal, Queue, local, Goal)
    ).
wire_token(Token0, Token) :-
    (   (atom(Token0); string(Token0)), atom_string(Token, Token0),
        atom_length(Token, 32), atom_codes(Token, Cs), maplist(hex_code, Cs)
    ->  true
    ;   throw(error(domain_error(transport_lineage, Token0), _))
    ).
hex_code(C) :- code_type(C, xdigit(_)).

connection_owns(Queue, Pid) :-
    actor_key(Pid, Key), actor_owner(Key, ctx(_, _, _, _, Queue)),
    (   current_owner_context(ctx(_, _, Lineage, _, Queue))
    ->  actor_owner(Key, ctx(_, _, Lineage, _, Queue))
    ;   true
    ).

node_log_output(Term) :-
    term_string(Term, Text),
    log_event(_{event_type:"actor_output", transport:"local", summary:Text}).

% CPU is charged across all descendants, including ordinary ACTOR children.
% Sampling bounds accounting latency, not time spent in uninterruptible host
% code. The watcher is one per active principal and stops when its tree ends.
ensure_cpu_watcher(ctx(Scope, Id, _, false, _)) :- !,
    with_mutex(node_cpu_watchers,
        (   cpu_watcher(Scope, Id, _)
        ->  true
        ;   thread_create(cpu_watch_lifetime(Scope, Id), T, [detached(true)]),
            assertz(cpu_watcher(Scope, Id, T))
        )).
ensure_cpu_watcher(_).
cpu_watch_lifetime(Scope, Id) :-
    thread_self(Self),
    setup_call_cleanup(true, cpu_watch(Scope, Id),
        with_mutex(node_cpu_watchers, retractall(cpu_watcher(Scope, Id, Self)))).
cpu_watch(Scope, Id) :-
    sleep(0.05),
    with_mutex(node_subtree,
        (   findall(Key, (actor_owner(Key, ctx(Scope, Id, _, false, _)),
                          local_to_scope(Scope, Key)), Keys),
            maplist(charge_actor, Keys),
            cpu_exhausted(Scope, Id, Exhausted)
        )),
    (   Exhausted == true
    ->  forall(member(Key, Keys), catch(actors:exit(Key, resource_error(cpu)), _, true))
    ;   true
    ),
    with_mutex(node_cpu_watchers,
        with_mutex(node_subtree,
            (   \+ (actor_owner(Key, ctx(Scope, Id, _, false, _)), local_to_scope(Scope, Key))
            ->  retractall(cpu_watcher(Scope, Id, _)), Finished = true
            ;   Finished = false
            ))),
    (Finished == true -> prune_accounts; cpu_watch(Scope, Id)).
charge_actor(Key) :-
    actor_owner(Key, ctx(Scope, Id, _, false, _)),
    actors:resolve_actor_thread(Key, T),
    catch(thread_statistics(T, cputime, CPU), _, fail),
    retract(cpu_sample(Key, Previous)), !,
    assertz(cpu_sample(Key, CPU)), Delta is max(0, CPU - Previous),
    get_time(Now), scoped_limit(Scope, principal_cpu_window, Window),
    (   retract(cpu_account(Scope, Id, Start, Used)), Now - Start < Window
    ->  Total is Used + Delta, Epoch = Start
    ;   Total = Delta, Epoch = Now
    ),
    assertz(cpu_account(Scope, Id, Epoch, Total)).
charge_actor(_).
cpu_exhausted(Scope, Id, true) :-
    cpu_account(Scope, Id, _, Used), scoped_limit(Scope, principal_cpu_seconds, Limit),
    Used >= Limit, !.
cpu_exhausted(_, _, false).
scoped_limit(node_port(P), Name, Value) :- !,
    node_runtime_state:with_node_port_context(P, node_lifetime:policy_limit(Name, Value)).
scoped_limit(_, Name, Value) :- policy_limit(Name, Value).

% Detaching an owner actor rehomes its terminal as well as its lifetime.
rehome_options(Options0, Options) :-
    option(link(false), Options0), \+ connection_spawn,
    (current_owner_context(ctx(_, _, _, true, _));
     \+ current_public_execution_profile(_)), !,
    exclude(terminal_option, Options0, Rest),
    Options = [io_target('$node_log')|Rest].
rehome_options(Options, Options).
terminal_option(target(_)).
terminal_option(io_target(_)).

% The host WebSocket reader answers incoming ping frames automatically.
% Finite stream timeouts plus outgoing pings detect a silent peer; they are
% evidence of contact loss, never evidence that remote work has stopped.
%
% The pinger is detached and is never joined: joining it from this cleanup
% races with thread teardown when the process halts with connections open.
% Instead each ping is sent under a per-connection mutex, and only while the
% lease is active.  The cleanup deactivates the lease under the same mutex
% before the connection closes the socket, so no ping can reach a closed
% stream.
with_websocket_lease(Socket, Goal) :-
    policy_limit(ws_lease_seconds, Seconds),
    (   Seconds == infinite
    ->  call(Goal)
    ;   stream_pair(Socket, In, Out),
        set_stream(In, timeout(Seconds)), set_stream(Out, timeout(Seconds)),
        Interval is Seconds / 3,
        mutex_create(Mutex),
        setup_call_cleanup(
            ( assertz(lease_active(Mutex)),
              thread_create(lease_pings(Socket, Interval, Mutex), Pinger,
                            [detached(true)]) ),
            Goal,
            ( with_mutex(Mutex, retractall(lease_active(Mutex))),
              catch(thread_send_message(Pinger, stop), _, true) )
        )
    ).

lease_pings(Socket, Interval, Mutex) :-
    thread_self(Me),
    (   thread_get_message(Me, stop, [timeout(Interval)])
    ->  true
    ;   with_mutex(Mutex,
                   ( lease_active(Mutex),
                     catch(ws_send(Socket, ping("web-prolog-lease")), _, fail) ))
    ->  lease_pings(Socket, Interval, Mutex)
    ;   true
    ).

remember_remote(Pid) :-
    current_owner_context(Context), !,
    actor_key(Pid, Key),
    with_mutex(node_subtree, assertz(actor_owner(Key, Context))).
remember_remote(_).

check_term(Term) :- policy_limit(max_term_depth, Depth), check_depth(Term, Depth).

% Record the route before waiting for a spawn acknowledgement. If its parent
% disappears during that wait, lineage reclamation reaches the receiver even
% though the source never learned the newly created pid.
remember_route(Node) :-
    current_owner_context(ctx(Scope, _, Lineage, false, _)), !,
    with_mutex(node_lineage_routes,
        (delegated_route(Scope, Lineage, Node) -> true;
         assertz(delegated_route(Scope, Lineage, Node)))).
remember_route(_).

reclaim_unused_lineage(Context) :-
    Context = ctx(Scope, _, Lineage, false, _),
    with_mutex(node_subtree,
        \+ (actor_owner(Key, ctx(Scope, _, Lineage, false, _)),
             local_to_scope(Scope, Key))), !,
    with_mutex(node_lineage_routes,
        findall(Node, retract(delegated_route(Scope, Lineage, Node)), Nodes)),
    with_mutex(node_subtree,
        retractall(actor_owner(_, ctx(Scope, _, Lineage, false, _)))),
    with_mutex(node_lineage,
        retractall(principal_lineage(Scope, tree(_, _), Lineage))),
    forall(member(Node, Nodes),
        catch(with_context(Context,
                  in_scope(Scope, distribution:remote_send_command(
                      Node, _{command:lineage_close}))), _, true)).
reclaim_unused_lineage(_).

local_to_scope(Scope, Pid) :- in_scope(Scope, pid_utils:pid_local(Pid, _)).
:- meta_predicate in_scope(+, 0).
in_scope(node_port(P), Goal) :- !,
    node_runtime_state:with_node_port_context(P, Goal).
in_scope(_, Goal) :- call(Goal).

reclaim_lineage(Queue) :-
    current_owner_context(ctx(_, _, Lineage, false, Queue)),
    (   current_public_execution_namespace(ws_lineage(Queue, Token))
    ->  node_execution_context:close_client_namespace(ws_lineage(Queue, Token))
    ;   true
    ),
    findall(Pid, actor_owner(Pid, ctx(_, _, Lineage, false, Queue)), Pids),
    forall(member(Pid, Pids), actors:exit(Pid, kill)).
