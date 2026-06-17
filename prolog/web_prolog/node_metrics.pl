:- module(node_metrics,
   [ node_metrics_text/1          % -Text
   ]).

/** <module> Prometheus-format node metrics

Renders the node's live aggregate state as Prometheus text-exposition
metrics for the `/metrics` endpoint.  This is a pure *renderer* over
state the node already maintains (the activity summary, the configured
limits, process statistics) — it adds no counter subsystem and does not
instrument any hot path.

Privacy: only aggregate counts are emitted.  Per-principal activity and
event contents (which the admin runtime dashboard shows behind admin
auth) are deliberately excluded, so `/metrics` is safe to scrape
unauthenticated like `/healthz`.

Must be called inside a node port context (the `/metrics` handler wraps
it in with_request_node_context/2).
*/

:- use_module(library(apply)).
:- use_module(node_runtime_state, [current_node_value/2]).
:- use_module(node_log, [current_node_log_runtime/1]).
:- use_module(node_version, [node_version_info/1]).
:- use_module(node_metrics_counters, [metric_counter_value/2]).

%!  node_metrics_text(-Text) is det.
node_metrics_text(Text) :-
    findall(Line, metric_line(Line), Lines),
    atomics_to_string(Lines, "\n", Body),
    string_concat(Body, "\n", Text).

%  Each metric is emitted as its HELP/TYPE header plus one or more
%  sample lines.  metric_line/1 yields the lines in order.
metric_line(Line) :-
    metric_block(Block),
    member(Line, Block).

metric_block(Block) :-
    build_info_block(Block).
metric_block(Block) :-
    uptime_block(Block).
metric_block(Block) :-
    process_block(Block).
metric_block(Block) :-
    activity_block(Block).
metric_block(Block) :-
    limits_block(Block).
metric_block(Block) :-
    counters_block(Block).

%  --- build info -------------------------------------------------

build_info_block([
        "# HELP web_prolog_build_info Build identity; constant 1.",
        "# TYPE web_prolog_build_info gauge",
        Sample
    ]) :-
    node_version_info(Info),
    get_dict(web_prolog, Info, WP),
    get_dict(swipl, Info, SWI),
    format(string(Sample),
           'web_prolog_build_info{web_prolog="~w",swipl="~w"} 1',
           [WP, SWI]).

%  --- uptime -----------------------------------------------------

uptime_block(Block) :-
    (   current_node_value(started_at, Started),
        number(Started)
    ->  get_time(Now),
        Uptime is Now - Started,
        gauge("web_prolog_uptime_seconds",
              "Seconds since this node started.",
              Uptime, Block)
    ;   Block = []
    ).

%  --- process ----------------------------------------------------

process_block(Block) :-
    statistics(threads, Threads),
    statistics(global, GlobalBytes),
    statistics(local, LocalBytes),
    statistics(trail, TrailBytes),
    Stacks is GlobalBytes + LocalBytes + TrailBytes,
    gauge("web_prolog_threads",
          "Live Prolog threads in this process (all nodes share one).",
          Threads, B1),
    gauge("web_prolog_stack_bytes",
          "Prolog stack memory in use across this thread's stacks.",
          Stacks, B2),
    append(B1, B2, Block).

%  --- activity (aggregate gauges) --------------------------------

activity_block(Block) :-
    (   catch(current_node_log_runtime(Runtime), _, fail),
        get_dict(activity_summary, Runtime, S)
    ->  findall(B,
                ( activity_gauge(Field, Metric, Help),
                  get_dict(Field, S, V),
                  number(V),
                  gauge(Metric, Help, V, B)
                ),
                Blocks),
        append(Blocks, Block)
    ;   Block = []
    ).

activity_gauge(active_sessions, "web_prolog_active_sessions",
               "Active ISOTOPE sessions.").
activity_gauge(active_ws_connections, "web_prolog_active_ws_connections",
               "Active ACTOR WebSocket connections.").
activity_gauge(active_ws_actors, "web_prolog_active_ws_actors",
               "Active ACTOR-mode actors.").
activity_gauge(active_principals, "web_prolog_active_principals",
               "Distinct principals with active activity.").
activity_gauge(active_clients, "web_prolog_active_clients",
               "Distinct clients with active activity.").
activity_gauge(retained_events, "web_prolog_log_retained_events",
               "Interaction-log events currently retained.").
activity_gauge(recent_errors, "web_prolog_recent_errors",
               "Errors within the retention window.").

%  --- configured limits (gauges) ---------------------------------

limits_block(Block) :-
    findall(B,
            ( limit_gauge(Key, Metric, Help),
              current_node_value(Key, V),
              limit_value(V, N),
              gauge(Metric, Help, N, B)
            ),
            Blocks),
    append(Blocks, Block).

%  `unlimited`/absent limits are emitted as 0 (Prometheus convention
%  for "no limit"); positive integers pass through.
limit_value(V, V) :- integer(V), !.
limit_value(_, 0).

limit_gauge(timeout, "web_prolog_limit_timeout_seconds",
            "Per-call wall-clock timeout ceiling (seconds).").
limit_gauge(max_inflight_calls, "web_prolog_limit_max_inflight_calls",
            "Max concurrent /call computations.").
limit_gauge(max_actors, "web_prolog_limit_max_actors",
            "Global live-actor cap (0 = unlimited).").
limit_gauge(max_call_inferences, "web_prolog_limit_max_call_inferences",
            "Per-call inference ceiling (0 = unlimited).").
limit_gauge(max_actor_stack_bytes, "web_prolog_limit_max_actor_stack_bytes",
            "Per-actor stack ceiling in bytes (0 = unlimited).").

%  --- cumulative counters ----------------------------------------

counters_block(Block) :-
    metric_counter_value(requests_total, Requests),
    metric_counter_value(errors_total, Errors),
    counter("web_prolog_requests_total",
            "Execution requests admitted and processed since this node started.",
            Requests, RequestsBlock),
    counter("web_prolog_errors_total",
            "Admitted execution requests that returned an error.",
            Errors, ErrorsBlock),
    rejections_block(RejectionsBlock),
    append([RequestsBlock, ErrorsBlock, RejectionsBlock], Block).

%  Labelled counter: one HELP/TYPE header plus a sample per reason.
rejections_block([HelpLine, TypeLine | Samples]) :-
    HelpLine = "# HELP web_prolog_rejections_total Requests refused, by reason.",
    TypeLine = "# TYPE web_prolog_rejections_total counter",
    findall(Sample,
            ( rejection_reason_label(Reason),
              metric_counter_value(rejection(Reason), Value),
              metric_number(Value, ValueText),
              format(string(Sample),
                     'web_prolog_rejections_total{reason="~w"} ~w',
                     [Reason, ValueText])
            ),
            Samples).

rejection_reason_label(auth).
rejection_reason_label(profile).
rejection_reason_label(sandbox).
rejection_reason_label(rate_limit).
rejection_reason_label(ip).

%  --- helpers ----------------------------------------------------

%!  gauge(+Metric, +Help, +Value, -Block) is det.
gauge(Metric, Help, Value, Block) :-
    block(Metric, Help, gauge, Value, Block).

counter(Metric, Help, Value, Block) :-
    block(Metric, Help, counter, Value, Block).

block(Metric, Help, Type, Value, Block) :-
    metric_number(Value, ValueText),
    format(string(HelpLine), "# HELP ~w ~w", [Metric, Help]),
    format(string(TypeLine), "# TYPE ~w ~w", [Metric, Type]),
    format(string(Sample), "~w ~w", [Metric, ValueText]),
    Block = [HelpLine, TypeLine, Sample].

metric_number(Value, Text) :-
    ( integer(Value) -> Text = Value
    ; float(Value)   -> format(string(Text), "~6f", [Value])
    ; Text = Value
    ).
