:- module(actor_api,
   [ node_setting/2,          % ?Key, ?Value
     resolve_thread/2,        % +Pid, -ThreadId
     op(200, xfx, @)
   ]).

/** <module> Legacy actor.pl API facade (node layer)

The demonstrator's actor.pl exported one flat surface that mixed the
local core, isolation, distribution, and node concerns.  The layered
fork splits those into actors/isolation/distribution; this facade
reconstitutes the original surface for the node-layer modules (and for
actor modules' import chains), so their selective import lists keep
working unchanged.

node_setting/2 lives here: it is the one predicate of that surface
that belongs to the node layer itself.  resolve_thread/2 was exported
by the legacy actor.pl; the layered core keeps it internal, so this
facade re-publishes it for legacy-surface consumers.
*/

:- reexport(actors).
:- reexport(isolation, [
    actor_module/2,
    consult_load_list/1,
    consult_load_list/2,
    listing_private/0,
    listing_private/1
]).
:- reexport(distribution, [
    make_id/1,
    remote_request_spawn/3,
    remote_request_halt/3,
    remote_send_command/2,
    register_remote_pid/2,
    flush_pending_for_pid/2
]).
:- reexport(pid_utils, [
    localhost_node/1,
    register_node_self/1,
    self_node_url/1
]).

:- use_module(node_runtime_state, [
    current_node_value/2
]).
:- use_module(node_builtin_policy, [builtin_family_enabled/2]).


%!  resolve_thread(+Pid, -ThreadId) is semidet.
%
%   Legacy-surface re-publication of actors' internal resolver.
resolve_thread(Pid, ThreadId) :-
    actors:resolve_thread(Pid, ThreadId).

%!  node_setting(?Key, ?Value) is nondet.
%
%   Query a publicly visible setting of the node servicing this request.
%   With Key unbound, enumerates all keys that the node is willing to
%   share. Sensitive runtime state (shared DB source, principal policies,
%   developer credentials) is deliberately not exposed.

node_setting(Key, Value) :-
    public_node_setting(Key, Family),
    setting_family_visible(Family),
    current_node_value(Key, Value).

setting_family_visible(always) :- !.
setting_family_visible(Family) :-
    current_node_value(profile, Profile),
    builtin_family_enabled(Profile, Family).

public_node_setting(url, always).
public_node_setting(profile, always).
public_node_setting(sandbox, always).
public_node_setting(auth, always).
public_node_setting(timeout, always).
public_node_setting(rate_window_seconds, always).
public_node_setting(max_inflight_calls, stateless_api).
public_node_setting(max_term_text_bytes, stateless_api).
public_node_setting(max_call_requests_per_window, stateless_api).
public_node_setting(max_load_text_bytes, private_db).
public_node_setting(load_uri_allowed_origins, private_db).
public_node_setting(max_sessions_per_principal, semistateful_api).
public_node_setting(max_session_spawns_per_window, semistateful_api).
public_node_setting(max_ws_actors_per_principal, stateful_api).
public_node_setting(max_ws_frame_bytes, stateful_api).
public_node_setting(max_ws_commands_per_window, stateful_api).
