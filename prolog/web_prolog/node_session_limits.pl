:- module(node_session_limits, [
    apply_node_ptcp_limits/2,
    current_node_time_limit/1,
    current_node_idle_limit/1
]).

/** <module> Node PTCP Session Limits

Apply node-owner PTCP lifecycle ceilings to public toplevel spawns. Clients may
request a tighter limit, but cannot weaken the node's configured ceiling.
*/

:- use_module(library(option)).
:- use_module(library(apply)).
:- use_module(library(settings)).

:- use_module(toplevel_actors, [normalize_ptcp_limit/3]).
:- use_module(node_runtime_state, [current_node_value/2]).


%!  apply_node_ptcp_limits(+Options0, -Options) is det.
%
%   Replace all client-supplied lifecycle options with their effective values.
%   The node setting is an owner ceiling; a finite client value may only make
%   it smaller.

apply_node_ptcp_limits(Options0, [
    time_limit(TimeLimit),
    idle_limit(IdleLimit)
    | Options
]) :-
    current_node_time_limit(OwnerTimeLimit),
    current_node_idle_limit(OwnerIdleLimit),
    requested_limit(time_limit, Options0, OwnerTimeLimit, TimeLimit),
    requested_limit(idle_limit, Options0, OwnerIdleLimit, IdleLimit),
    exclude(is_ptcp_limit_option, Options0, Options).

requested_limit(Kind, Options, OwnerLimit, EffectiveLimit) :-
    limit_option(Kind, RequestedTerm),
    (   option(RequestedTerm, Options)
    ->  arg(1, RequestedTerm, Requested0),
        normalize_ptcp_limit(Kind, Requested0, Requested),
        tighter_limit(OwnerLimit, Requested, EffectiveLimit)
    ;   EffectiveLimit = OwnerLimit
    ).

limit_option(time_limit, time_limit(_)).
limit_option(idle_limit, idle_limit(_)).

is_ptcp_limit_option(time_limit(_)).
is_ptcp_limit_option(idle_limit(_)).

tighter_limit(infinite, Requested, Requested) :-
    !.
tighter_limit(Owner, infinite, Owner) :-
    !.
tighter_limit(Owner, Requested, Effective) :-
    Effective is min(Owner, Requested).


%!  current_node_time_limit(-Limit) is det.
%!  current_node_idle_limit(-Limit) is det.

current_node_time_limit(Limit) :-
    current_node_lifecycle_limit(time_limit, Limit).

current_node_idle_limit(Limit) :-
    current_node_lifecycle_limit(idle_limit, Limit).

current_node_lifecycle_limit(Key, Limit) :-
    current_node_value(Key, Limit0),
    !,
    normalize_ptcp_limit(Key, Limit0, Limit).
current_node_lifecycle_limit(time_limit, Limit) :-
    (   setting(node:time_limit, Limit0)
    ->  normalize_ptcp_limit(time_limit, Limit0, Limit)
    ;   Limit = infinite
    ).
current_node_lifecycle_limit(idle_limit, Limit) :-
    (   setting(node:idle_limit, Limit0)
    ->  normalize_ptcp_limit(idle_limit, Limit0, Limit)
    ;   Limit = infinite
    ).
