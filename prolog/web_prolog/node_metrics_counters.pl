:- module(node_metrics_counters, [
    note_request_admitted/0,
    note_request_error/1,            % +Error
    note_ip_rejection/0,
    metric_counter_value/2,          % +Name, -Count   (0 if absent)
    clear_metric_counters_scope/1    % +Scope
]).

/** <module> Cumulative metrics counters

Monotonic per-node counters for the `/metrics` endpoint: how many
execution requests were handled, how many errored, and a breakdown of
refusals by reason (auth / profile / sandbox / rate_limit / ip). Counters
are incremented at the policy choke points (execute_and_respond_logged
and the IP gate) and rendered by node_metrics. Per-node scope, keyed by
the bind port; reset on a node (re)start, like the rate-limit buckets —
which is the normal counter-reset Prometheus already handles.

Aggregate only (no per-principal detail), so `/metrics` stays safe to
scrape unauthenticated.
*/

:- use_module(library(lists)).
:- use_module(node_runtime_state, [current_node_port/1]).

:- dynamic node_counter/3.            % Scope, Name, Count


%!  note_request_admitted is det.
%
%   One execution request was admitted (passed the IP gate) and
%   processed.
note_request_admitted :-
    incr_counter(requests_total).


%!  note_request_error(+Error) is det.
%
%   An admitted request returned an error; also bump the by-reason
%   rejection counter when the error maps to a known reason.
note_request_error(Error) :-
    incr_counter(errors_total),
    (   rejection_reason(Error, Reason)
    ->  incr_counter(rejection(Reason))
    ;   true
    ).


%!  note_ip_rejection is det.
%
%   A request was refused at the IP gate (blocklist / allowlist / ban).
%   Counted as a refusal but not as an admitted request.
note_ip_rejection :-
    incr_counter(rejection(ip)).


%!  metric_counter_value(+Name, -Count) is det.
metric_counter_value(Name, Count) :-
    counter_scope(Scope),
    (   node_counter(Scope, Name, Count)
    ->  true
    ;   Count = 0
    ).


%!  clear_metric_counters_scope(+Scope) is det.
clear_metric_counters_scope(Scope) :-
    with_mutex(node_metrics_counters,
               retractall(node_counter(Scope, _, _))).


                 /*******************************
                 *           INTERNAL           *
                 *******************************/

incr_counter(Name) :-
    counter_scope(Scope),
    with_mutex(node_metrics_counters, incr_counter_(Scope, Name)).

incr_counter_(Scope, Name) :-
    (   retract(node_counter(Scope, Name, Count0))
    ->  Count is Count0 + 1
    ;   Count = 1
    ),
    assertz(node_counter(Scope, Name, Count)).

counter_scope(Scope) :-
    (   current_node_port(Port)
    ->  Scope = node_port(Port)
    ;   Scope = global
    ).

%!  rejection_reason(+Error, -Reason) is semidet.
rejection_reason(error(authorization_error(_, _), _), auth).
rejection_reason(error(profile_violation(_, _), _), profile).
rejection_reason(error(rate_limit_exceeded(_, _, _, _), _), rate_limit).
rejection_reason(error(permission_error(_, sandboxed, _), _), sandbox).
rejection_reason(error(permission_error(_, sandboxed_directive, _), _), sandbox).
