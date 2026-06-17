:- module(node_doctor, [
    node_doctor_report/2          % +Request, -Report
]).

/** <module> Node self-diagnostics

A green/amber/red review of the running node's security and operational
posture for the `/admin/doctor` endpoint. Each check yields ok / warn /
fail with a one-line message; the overall status is the worst check.
Read-only; must run inside a node port context (the handler wraps it in
with_node_request_context/2).
*/

:- use_module(library(lists)).
:- use_module(node_runtime_state, [current_node_value/2, current_node_maintenance/1]).
:- use_module(node_tokens, [token_count/1, current_tokens_file/1]).
:- use_module(node_interaction_log, [current_interaction_log_file/1]).

%!  node_doctor_report(+Request, -Report) is det.
node_doctor_report(Request, json{status:Overall, checks:Checks}) :-
    findall(Check, doctor_check(Request, Check), Checks),
    overall_status(Checks, Overall).

overall_status(Checks, Overall) :-
    findall(Status, ( member(C, Checks), get_dict(status, C, Status) ), Statuses),
    (   memberchk(fail, Statuses) -> Overall = fail
    ;   memberchk(warn, Statuses) -> Overall = warn
    ;   Overall = ok
    ).

node_value_or(Key, Default, Value) :-
    (   current_node_value(Key, V)
    ->  Value = V
    ;   Value = Default
    ).

positive_int(V) :- integer(V), V > 0.


                 /*******************************
                 *           CHECKS             *
                 *******************************/

%  Sandbox — the deciding control for running untrusted code.
doctor_check(_, json{id:sandbox, status:Status, message:Message}) :-
    node_value_or(sandbox, whitelist, Mode),
    (   Mode == whitelist
    ->  Status = ok,
        Message = "whitelist sandbox: only proven-safe goals run."
    ;   Mode == blacklist
    ->  Status = warn,
        Message = "blacklist sandbox is weaker than whitelist; prefer whitelist on a public node."
    ;   Status = fail,
        Message = "sandbox is OFF: untrusted code runs unrestricted."
    ).

%  Auth boundary.
doctor_check(_, json{id:auth, status:Status, message:Message}) :-
    node_value_or(auth, private, Auth),
    (   Auth == open
    ->  Status = warn,
        Message = "auth=open: unauthenticated execution is accepted — make sure the sandbox, rate limits and IP controls suit a public node."
    ;   Status = ok,
        format(string(Message), "auth=~w: execution requires an authenticated principal.", [Auth])
    ).

%  Resource ceilings — one runaway client must not exhaust the node.
doctor_check(_, json{id:resource_ceilings, status:Status, message:Message}) :-
    findall(Key,
            ( member(Key, [max_actors, max_call_inferences, max_actor_stack_bytes]),
              node_value_or(Key, 0, V),
              \+ positive_int(V)
            ),
            Unbounded),
    (   Unbounded == []
    ->  Status = ok,
        Message = "per-actor and global resource ceilings are set."
    ;   Status = warn,
        atomic_list_concat(Unbounded, ', ', UnboundedText),
        format(string(Message),
               "no resource ceiling for: ~w (a single client could exhaust the node).",
               [UnboundedText])
    ).

%  TLS — inferred from how this request arrived (via the proxy).
doctor_check(Request, json{id:tls, status:Status, message:Message}) :-
    (   request_forwarded_https(Request)
    ->  Status = ok,
        Message = "this request arrived with X-Forwarded-Proto=https (TLS terminated by a proxy)."
    ;   Status = warn,
        Message = "this request had no X-Forwarded-Proto=https — ensure a TLS-terminating reverse proxy fronts the node (or you are calling it directly)."
    ).

%  Bearer-token durability.
doctor_check(_, json{id:token_persistence, status:Status, message:Message}) :-
    token_count(Count),
    (   Count > 0,
        \+ current_tokens_file(_)
    ->  Status = warn,
        Message = "bearer tokens are issued but no tokens file is configured — they are lost on restart (set WP_TOKENS_FILE)."
    ;   Status = ok,
        Message = "token persistence is configured, or no tokens are issued."
    ).

%  Interaction / audit log retention.
doctor_check(_, json{id:log_retention, status:Status, message:Message}) :-
    (   \+ catch(current_interaction_log_file(_), _, fail)
    ->  Status = warn,
        Message = "no interaction/audit log file resolved."
    ;   node_value_or(max_interaction_log_bytes, 0, Bytes),
        \+ positive_int(Bytes)
    ->  Status = warn,
        Message = "interaction/audit log has no size cap (max_interaction_log_bytes=0); it can grow unbounded."
    ;   Status = ok,
        Message = "interaction/audit log is configured with size-based rotation."
    ).

%  Lifecycle.
doctor_check(_, json{id:maintenance, status:Status, message:Message}) :-
    (   current_node_maintenance(true)
    ->  Status = warn,
        Message = "node is in maintenance/drain mode (refusing new work)."
    ;   Status = ok,
        Message = "node is serving (not in maintenance)."
    ).


request_forwarded_https(Request) :-
    (   memberchk(x_forwarded_proto(Proto), Request)
    ->  true
    ;   memberchk('x-forwarded-proto'(Proto), Request)
    ),
    proto_text(Proto, "https").

proto_text(Proto, Text) :-
    (   atom(Proto) -> atom_string(Proto, Text)
    ;   string(Proto) -> Text = Proto
    ;   false
    ).
