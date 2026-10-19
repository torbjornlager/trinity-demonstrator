# `library(web_prolog)` — the layered source

This directory holds the implementation, organised as a stack of layers.
The rule is simple and **machine-enforced**: a module may only import
modules in its own layer or a lower one. Cross-cutting connections that
would otherwise point *upward* run through `multifile` hooks instead
(wired by the composition spine — see [composition.pl](composition.pl)).

The layer assignment for every module lives in
[`tools/generate_dependency_graph.py`](../../tools/generate_dependency_graph.py)
and is checked on every CI run by the **LINT** tier
(`tools/generate_dependency_graph.py --check`): an import that points to a
higher layer, or a new file with no layer assigned, fails the build.

Each tier of the test suite (`tests/tiers/`, see
[tests/tiers/README.md](../../tests/tiers/README.md)) loads exactly the
layers up to its number and asserts the layers above it are **not**
loaded, so the layering is verified at runtime as well as by the lint.

Load the whole stack with `?- use_module(library(web_prolog)).`, or pull
in any individual layer — every module below is a usable entry point on
its own.

---

## Layer 0 — stand-alone actor core

The actor library, usable with no other part of this project; full
SWI-Prolog is available to actor goals.

| module | summary |
|---|---|
| [actors.pl](actors.pl) | Minimal Erlang-style actors: `spawn`/`send`/`receive`, links, monitors with `down`, name registration. Opaque pids; all higher-layer behaviour attaches through its hooks. |

## Layer 1 — isolation

Per-actor private modules and controlled source loading.

| module | summary |
|---|---|
| [isolation.pl](isolation.pl) | Per-actor temporary module isolation; `src_text/1`, `src_list/1`, `src_uri/1`, `src_predicates/1`. |
| [source_utils.pl](source_utils.pl) | Source-text and URI helpers shared by the isolation paths. |
| [actor_io_support.pl](actor_io_support.pl) | Actor I/O prelude support. |
| [actor_io_template.pl](actor_io_template.pl) | Precompiled immutable actor I/O implementation imported by trusted native actors. |
| [worker_cleanup.pl](worker_cleanup.pl) | Race-free monitored-worker teardown and mailbox cleanup. |

## Layer 2 — toplevels and behaviours

Query actors (the pengine-style toplevel) plus the reusable actor
behaviours.

| module | summary |
|---|---|
| [toplevel_actors.pl](toplevel_actors.pl) | Query actors: the `'$call'`/`'$next'`/`'$stop'` toplevel protocol. |
| [dollar_expansion.pl](dollar_expansion.pl) | `$Var` dollar-variable expansion for the toplevel. |
| [term_display.pl](term_display.pl) | User-facing term rendering. |
| [server_actor.pl](server_actor.pl) | Generic server (`gen_server`-style) behaviour: synchronous request/reply, hot code swap, fail-fast monitoring. |
| [supervisor_actor.pl](supervisor_actor.pl) | OTP-style supervisor: start/monitor/restart child actors by spec and strategy. |
| [parallel.pl](parallel.pl) | Parallel conjunction: run goals concurrently, fail fast. |
| [first_solution.pl](first_solution.pl) | Race alternative goals and return the first successful solution. |
| [statechart_model.pl](statechart_model.pl) | Statechart model parsing. |
| [sxml-0.2.dtd](sxml-0.2.dtd) | Versioned XML grammar supplied to the SXML parser. |
| [statechart_runtime.pl](statechart_runtime.pl) | Statechart runtime helpers. |
| [statechart_exec.pl](statechart_exec.pl) | Statechart execution core. |
| [statechart_actor.pl](statechart_actor.pl) | Statechart actor interpreter. |
| [wasm/](wasm/) | A self-contained SWI-WASM port of the statechart behaviour (`statechart_wasm{,_model,_runtime,_exec}.pl`) and its embedded SXML schema for in-browser actors; imports only `library/` and its own siblings. |

## Layer 3 — distribution

`Id@Node` pids and the cross-node client.

| module | summary |
|---|---|
| [distribution.pl](distribution.pl) | `Id@Node` pids; remote `spawn`/`send`/`monitor`/`link`. |
| [remote_protocol.pl](remote_protocol.pl) | Remote wire-protocol helpers (incl. `protocol_version/1`). |
| [node_controller.pl](node_controller.pl) | Proxy-less cross-node routing skeleton. |
| [rpc.pl](rpc.pl) | HTTP-only RPC client: `rpc/2-3`, `promise/3-4`, `yield/2-3`. |
| [pid_utils.pl](pid_utils.pl) | Pid and node-URL helpers. |

## Layer 4 — the node server

The HTTP/WebSocket node: profiles (RELATION / ISOBASE / ISOTOPE /
ACTOR), auth, sandbox, limits — all attached to the lower layers through
hooks. The composition spine and node-layer glue also live here.

**Entry & composition**

| module | summary |
|---|---|
| [node.pl](node.pl) | Node controller: HTTP server, route dispatch, the `node/1-2` entry point. |
| [composition.pl](composition.pl) | The composition spine: wires the layer-0→4 hook chain (loaded by `node_glue` and the umbrella alike). |
| [node_glue.pl](node_glue.pl) | Node-layer hook implementations. |
| [node_engine.pl](node_engine.pl) | Stateless query engine behind ISOBASE `/call`. |
| [node_response.pl](node_response.pl) | Node response serialization. |
| [node_call_context.pl](node_call_context.pl) | Request parsing for `/call`. |
| [node_execution_context.pl](node_execution_context.pl) | Public execution context. |

**Auth, capabilities & principals**

| module | summary |
|---|---|
| [node_auth.pl](node_auth.pl) | Authentication and authorization policy. |
| [node_capabilities.pl](node_capabilities.pl) | Shared capability helpers. |
| [node_tokens.pl](node_tokens.pl) | Bearer API tokens. |
| [node_principal_policy.pl](node_principal_policy.pl) | Node-owned principal policy. |
| [node_owner_tag.pl](node_owner_tag.pl) | Owner tagging + secret-log-viewer helpers. |

**Profiles, policy, sandbox & guards**

| module | summary |
|---|---|
| [node_profile_policy.pl](node_profile_policy.pl) | Node profile policy (route/goal/source matrix). |
| [node_relation_policy.pl](node_relation_policy.pl) | RELATION query policy. |
| [node_builtin_policy.pl](node_builtin_policy.pl) | Web Prolog family/builtin policy. |
| [node_sandbox.pl](node_sandbox.pl) | Node sandbox policy (off / whitelist / blacklist). |
| [public_goal_guard.pl](public_goal_guard.pl) | Public blacklist goal rewriting. |
| [goal_walker.pl](goal_walker.pl) | Goal-structure walker used by the guards. |

**Sessions, ISOTOPE & WebSocket**

| module | summary |
|---|---|
| [node_session.pl](node_session.pl) | ISOTOPE session helpers. |
| [node_isotope_controller.pl](node_isotope_controller.pl) | ISOTOPE controller helpers. |
| [node_isotope_options.pl](node_isotope_options.pl) | ISOTOPE spawn-option parsing. |
| [node_ws.pl](node_ws.pl) | WebSocket ACTOR profile. |

**Limits & rate control**

| module | summary |
|---|---|
| [node_limits.pl](node_limits.pl) | Node resource limits (actors, capacity). |
| [node_limit_helpers.pl](node_limit_helpers.pl) | Shared limit helpers. |
| [node_input_limits.pl](node_input_limits.pl) | Input size limits (term/source text). |
| [node_rate_limits.pl](node_rate_limits.pl) | Request rate limits. |
| [node_ip_policy.pl](node_ip_policy.pl) | IP / CIDR access control. |

**Logging, metrics & diagnostics**

| module | summary |
|---|---|
| [node_log.pl](node_log.pl) | Per-node logging and activity summaries. |
| [node_interaction_log.pl](node_interaction_log.pl) | Durable interaction log (with rotation). |
| [node_log_viewer.pl](node_log_viewer.pl) | Secret interaction-log viewer. |
| [node_metrics.pl](node_metrics.pl) | Prometheus-format `/metrics`. |
| [node_metrics_counters.pl](node_metrics_counters.pl) | Cumulative metrics counters. |
| [node_doctor.pl](node_doctor.pl) | Node self-diagnostics. |

**Admin, startup & runtime state**

| module | summary |
|---|---|
| [node_admin.pl](node_admin.pl) | Admin HTTP API. |
| [node_startup_options.pl](node_startup_options.pl) | Node startup-option parsing. |
| [node_runtime_state.pl](node_runtime_state.pl) | Per-node runtime state. |
| [node_version.pl](node_version.pl) | Node build/version information. |

**Data & compatibility**

| module | summary |
|---|---|
| [shared_db.pl](shared_db.pl) | Default public shared knowledge base (demonstration content; replaceable). |
| [actor_api.pl](actor_api.pl) | Legacy `actor.pl` API facade, including the unqualified RPC/promise/yield client surface. |
| [debug.pl](debug.pl) | Debug helpers. |

## Layer 5 — the umbrella

| module | summary |
|---|---|
| [../web_prolog.pl](../web_prolog.pl) | `library(web_prolog)`: reexports every layer, fully composed. |

---

> Web Prolog syntax and semantics are **frozen** to the
> trinity-demonstrator — see [../../DEVIATIONS.md](../../DEVIATIONS.md),
> which is expected to stay empty. Conformance is pinned by the
> demonstrator's test suite, relocated into the `T0`–`T5` tiers under
> [`../../tests/tiers/`](../../tests/tiers/); do not change these modules'
> observable behaviour without a corresponding DEVIATIONS.md entry.

## Node transport implementation

The [shared language manual](../../web/manual.html) defines the public API.
The following notes describe the HTTP/WebSocket representation and compatibility
machinery; they are maintained here rather than in predicate entries.
Browser-specific coordination is documented in the [SWI-WASM guide](../../web/README.md).

### Results and source loading

Remote execution-time exhaustion is reported as `error(resource_error(time), _)`; memory exhaustion as `error(resource_error(space), _)`. RPC clients propagate these exceptions without a wrapper. The context is elided in normal display. A client transport timeout is distinct and does not establish that the remote computation has stopped.

In JSON success events, `data` is a list of binding objects whose values are Prolog-text strings: for example, `{"X":"42"}`. Default JSON query formatting replaces an explicit template with the visible named query variables. HTTP `format=prolog` returns a Prolog answer term and honors the template. WebSocket `format(prolog)` honors the template but retains a JSON envelope with Prolog-term strings in its `data` array. A `down` event's `reason` is Prolog term text. Integer monitor references within JavaScript's exact-integer range are JSON numbers; larger integers are decimal strings. Compound references are quoted Prolog term text with their complete structure and node qualifiers preserved, independently of the event's actor-pid formatting.

Supply source through spawn options. HTTP `/toplevel_call` still accepts changed, nonempty `src_text` for compatibility; empty or unchanged source does not reload. WebSocket `toplevel_call` rejects a `src_text` field even when empty. Its canonical `options` string accepts only `template/1`, `offset/1`, `limit/1`, `once/1`, and `format/1`. Defaults are the goal, `0`, no solution-count limit, `false`, and `json`, respectively. Goal and options are parsed together. A WebSocket `toplevel_next` frame may include a JSON integer `limit`; omission inherits the current limit.

HTTP sessions force `session(true)`; WebSocket toplevel spawn defaults to `session(false)`. HTTP polling retrieves one queued event without advancing the solution sequence. Its timeout does not abort the goal. An HTTP abort replies only after the toplevel has acknowledged it, with an event of type `abort`. Every session request's response carries a `Web-Prolog-Seq` header numbering the event it returned. A client that did not receive a response may repeat the request with a `Web-Prolog-Ack` header holding the last number it did receive; if the lost response is the session's latest event, the node sends it again instead of running the command a second time. A session's former owner that addresses it after it has ended or been reclaimed receives an error whose `code` field is `session_lost`. The transport's `statechart_trace` setting defaults to `false` and is stored and acknowledged, but the current delivery code does not consult it to suppress traces. Use the statechart's `trace/1` option to control generation.

### Browser transport extensions

```
{"command":"transport_hello","version":1,
 "browser_pids":true,"io_ack":true}
```

The node answers with `type:"transport_welcome"`, `protocol:"web_prolog_browser_actor"`, `version:1`, and both capability flags set to `true`. Flags in the welcome advertise support; each extension is enabled only when requested in the hello.

With `browser_pids` enabled, qualified browser-local pids embedded in goals, templates, and messages receive connection-scoped return routes. Bare numbers, atoms, and source strings remain data. Replies arrive as:

```
{"type":"actor_message","target":"2159438818@localhost",
 "message":"reply(ok)"}
```

With `io_ack` enabled, terminal output arrives inside an acknowledgement request:

```
{"type":"io_request","request_id":"opaque-reference",
 "event":{"type":"output","pid":123,"data":"hello"}}
```

After accepting the output, reply on the same connection:

```
{"command":"browser_io_reply","request_id":"opaque-reference",
 "status":"ok"}
```

The alternative status is `error`. The actor waits for acceptance; an error, connection closure, or a 30-second acknowledgement timeout raises an I/O error. Late replies are discarded. This acknowledges acceptance, not browser painting. Prompts and query answers retain their ordinary event forms. Without this extension, output arrives directly as an `output` event.

WebSocket-created actors have a connection lifecycle monitor in addition to any explicit client monitor. Its `down` event carries a node-generated reference. Closing the connection terminates its actors and revokes browser return routes.

### Correlation and answer terms

Portable application terms are serialised as canonical quoted Prolog text,
without operator syntax, portray hooks or numbervars and with explicit variable
names. The portable subset excludes attributed variables, streams and non-text
blobs; the language manual defines application-visible constraints and string
semantics. Monitor references are serialised independently of pid abbreviation.

Synchronous toplevel calls negotiate `web-prolog-sync-v1`; the request reference
is carried through commands and replies independently of ordinary asynchronous
answers. A private wait monitor is installed before sending, and stale tagged
answers for the same pid are discarded against the existing deadline. See the
language manual for timeout outcomes and unsupported-peer errors.

Browser clients additionally request `answer_terms:true` in `transport_hello`.
Acknowledging nodes send canonical `term` payloads for asynchronous success and
query-error events. The receiver parses the entire solution list or exception
once, retaining sharing across solutions, distinct variables, strings and
literal `'$VAR'/1` terms. Negotiated main-engine queries request `format(prolog)`;
Worker actor-term calls already preserve their templates. Peers without the
acknowledgement retain display-field reconstruction and `remote_error(Text)`.
Malformed negotiated payloads produce explicit answer-protocol errors rather
than falling back. Trealla implements the same negotiated extension; its
receiver and outbound-client details belong to its own README.

### Native implementation boundaries

Registry updates and named-startup reservations are serialised under the actor
registry mutex. Namespace admission is closed before names and promises are
swept during client teardown. Promise workers, timers and collector claims are
managed separately from actor lifetimes. These mechanics implement the public
ownership rules; trusted standalone use retains its existing sharing model.

Supervisor request waits are not all at the same cleanup level: the native halt
wait has all-exit private-monitor cleanup and handles normal termination arriving
before acknowledgement within the original deadline. Ordinary native SWI
supervisor request waits and detached-child rollback retain the gaps called out
in the shared manual. The Trealla/browser scoped journals should not be assumed
to exist in this runtime.


### Namespace admission, source setup and promise disposal

Public WebSocket endpoints validate client creation options before preparing
source or reserving actor slots, then attach their own monitor and I/O metadata.
Locally rewritten effective options are checked again before pid allocation.
Private options such as `source_module/1`, `inherit_goal_module/1`,
`isolation_io/1`, `monitor_target/1` and `monitor_ref/1` remain framework metadata;
raw client attempts to supply them are rejected. Wrappers consume their own
settings before forwarding actor options.

Native local name preparation reserves a namespace/name pair under the registry
mutex. Publication follows preparation and pid resolvability, before releasing
the application goal. Retirement shares the same mutex, preventing an immediate
exit from leaving a name published later. Remote startup separately owns routing,
links, creator monitors and buffered lifecycle observations through publication;
namespace closure or an observed down prevents commitment. The language manual
retains observable timing and best-effort remote cleanup qualifications.

Public SWI namespace lifetime follows the connection, interactive session or
delegated transport lineage. Toplevel replacement and ordinary request completion
do not close a shared namespace. Closing a lineage or namespace prevents late
admission before registrations and promises are swept. Remote link cleanup uses
explicit parent-termination information and the owning trusted connection/lineage;
a finite ping/pong lease bounds serviced-connection contact-loss detection,
without guaranteeing completed remote reclamation.

Promise state holds the answer separately from its wake queue. Collector claim,
collection commitment, expiry and disposal are coordinated under the lifecycle
mutex; one of collection or disposal wins. Disposal retires the reference,
destroys its wake queue, stops the expiry task and interrupts an unfinished local
HTTP worker so stream cleanup runs. Not-yet-active workers observe retirement
before starting their request. Partial setup rolls back allocated local resources,
and late completion cannot deliver to a destroyed queue. These are local resource
mechanisms; they do not cancel remote execution or transfer promise ownership.
