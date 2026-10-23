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

### Candidate native receive handoff

The receive adapter now acquires a native message and records its thread-local
`deferred/1` fact in the same `sig_atomic/1` region. Guards and selected bodies
run after that region, preserving one-sided matching, message ordering and body
alternatives. Moving to deferred storage does not release mailbox quota; the
existing consumption hook still runs only on selection or explicit discard.

Default blocking/timed reads use at most 50 ms native wait slices. Between
slices, signal handling resumes; a message arrival still wakes the native wait
immediately. The original overall deadline is retained and the public timeout
callback runs only when that deadline expires. Zero-time polling protects
peek, read and recording without waiting. An explicitly supplied native host
`signals(false)` retains its requested suppression of signal checks while
waiting; it is an exception to the default interruptible-wait policy.

**Engine prerequisite:** this candidate requires SWI-Prolog commit
[`09b6299`](https://github.com/SWI-Prolog/swipl-devel/commit/09b6299f696574c9230f23e53b1ab041a942b6f3)
or a later build containing that protected-wait fix. The official macOS
10.1.18 package predates it and can spin in these protected timed waits with a
pending signal. The candidate was verified using the separate build containing
Jan's fix, without replacing the installed engine or restarting N3. Do not
deploy this adapter on that unpatched package. This is a runtime prerequisite,
not a new Web Prolog option or language-level predicate.

See [the verification record](../../docs/verification/swi-receive-handoff-2026-10-23/REPORT.md)
for regression commands, the before/after control, repeated worker cleanup and
exact engine/source hashes. Periodic wakeups are the cost of keeping the wait
bounded; no scalability or performance benchmark is claimed.

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
| [supervisor_startup.pl](supervisor_startup.pl) | Provisional-child journal and shutdown-policy rollback for startup, dynamic additions and replacement attempts. |
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

Native SWI accepts ordinary Unicode text atoms, including its internal
`ucs_text` representation, in messages and canonical success/error payloads.
Previously the filter admitted `text` but rejected `ucs_text`, suppressing the
canonical payload for answers containing atoms such as `€`, `漢字` or `😀`.
The existing serializer already handles these atoms; wire formats are unchanged.
Cycles, attributed variables, streams and other resource blobs remain rejected.
Native actor and cross-node answer regressions cover this boundary. The shared
`unicode_answer_tests.pl` interoperability fixture in the Trealla checkout tests
asynchronous and synchronous answers, paging, exceptions and variable sharing
against disposable native SWI/Trealla nodes. Browser filters are unchanged by
this native repair.

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

Native SWI's decoder now treats a present `term` field on a success/error event
as authoritative: non-text or unparsable values, and success payloads that are
not proper lists, yield `error(Pid,remote_answer_protocol_error(invalid_term))`.
A correlated success/error without that field yields
`remote_answer_protocol_error(missing_term)`, wrapped with the original request
reference. It never substitutes display data for these rejected payloads.
Failure events still require no payload. Uncorrelated answers without `term`
retain legacy decoding, including `remote_error(Text)`, because the native client
does not record an explicit canonical-capability acknowledgement. This repair
adds no handshake or connection capability state.

The `toplevel_correlation_transport` regressions cover malformed/non-text/scalar
and partial-list payloads, request references, legacy decoding, and recovery of
the actual reader after bad frames. Immediate and buffered routing both preserve
subsequent valid answers and unrelated messages. The focused group and live
Unicode/exception/sharing/paging checks against native SWI and Trealla passed;
installed engines, live nodes and browser runtimes were unchanged.

### Native implementation boundaries

Registry updates and named-startup reservations are serialised under the actor
registry mutex. Namespace admission is closed before names and promises are
swept during client teardown. Promise workers, timers and collector claims are
managed separately from actor lifetimes. These mechanics implement the public
ownership rules; trusted standalone use retains its existing sharing model.

Local actor ownership is retained through the registry/monitor pid-retirement
transaction. The pre-retirement stop hook takes the final CPU sample; a separate
post-retirement hook removes ownership, mailbox and CPU records and reclaims
unused lineage outside the actor locks. Worker cleanup can therefore stop a
worker during shutdown without observing a resolvable but unowned pid. Exit
authority checks remain unchanged, including rejection of live actors in another
owner tree. A controlled retirement-barrier regression covers this ordering.
An activated local spawn that subsequently fails also retains its ownership
until pid retirement, allowing its creator to reclaim the provisional actor.
A failed reservation that never activated is still reclaimed immediately.

Ordinary supervisor requests scope their private monitor with
`setup_call_cleanup/3`, covering send exceptions, reply mismatches, interruption,
supervisor death and the existing ten-second timeout after sending. Cleanup uses
`demonitor(Ref, [flush])`; it preserves application monitors, unrelated messages
and late replies. The native halt wait has its own all-exit cleanup and handles
normal termination arriving before acknowledgement within the original deadline.
Initial startup, dynamic additions and replacement attempts use the private journal in
`supervisor_startup.pl`. Local admission records provisional pids before
activation; acknowledged remote pids are recorded during the protected creation
handoff. Monitor references are tracked separately from copied rollback specs;
live specs and their variable sharing remain unchanged. Commit releases the
journal. Failure rolls it back in reverse order with the child's shutdown policy,
a private cleanup monitor and reference-specific flushing. Cleanup attempts all
entries while retaining the original startup outcome; committed actor exits keep
normal parent-link containment instead of waiting on a dying mailbox. Dynamic
startup exceptions become error replies without discarding existing state.
Explicit respawn failures retain the inactive specification and existing siblings
for retry. Automatic restart failures roll back provisional replacements, then
stop remaining recorded children in reverse order and exit with
`restart_failed(Id, Reason)`, naming the replacement that failed. Group restarts
retain their forward stopping order on the successful path. Fresh private
cleanup monitors handle both live and already retired original pids without
consuming application notifications. Intensity exhaustion uses the same reverse
policy cleanup before committing
`exit(shutdown)`. The exited child is marked inactive before checking the budget;
no excess replacement is started. Restart timestamps, strict window boundary
and permitted restart count are unchanged. Private cleanup monitors preserve
application notifications, and ordinary cleanup errors leave the shutdown
reason intact while allowing the remaining cleanup attempts. Unknown
remote creation outcomes and remote cancellation remain separate work.


Public WebSocket checks traced the apparent supervisor replacement-cleanup
timeouts to final monitor flushing in the caller. SWI 10.1.17 can loop in
`thread_get_message/3` with `timeout(0)` when a signal is pending inside
signal-masked cleanup. The native actor receive path now peeks at its own
mailbox and reads only when a message is available, protecting the pair from
signal-handler re-entry with `sig_atomic/1`. The actor thread is the
sole consumer of that mailbox. Deferred selection, one-sided matching,
control-exception preservation, body alternatives and mailbox accounting
continue through the existing scan path.

This shortcut covers integer/float zero with the documented receive options.
Normal finite/negative waits, malformed lists, mixed duplicate timeouts and
host-specific option extensions keep the original native option handling.
It is not a general workaround for every timed host wait in a protected
context. Pending-signal regressions run in watchdog-protected subprocesses;
a node-level regression checks that deferred messages keep their quota and
consumed/flushed messages release it exactly once. The public repeated-cleanup
and three replacement-failure diagnostics now pass, including thirty further
replacement checks (ten per strategy). The runtime-bound nested-specification
admission difference remains separate.

The standalone [upstream draft](../../docs/upstream/swi-zero-time-poll-pending-signal.md)
and [reproducer](../../docs/upstream/repro-zero-time-poll.pl) require no Web Prolog
code and have not been submitted. Shared conformance coverage and dated raw
results remain in `trinity-conformance` under `profiles/actor-supervisors-0.1.md`
and `reports/2026-10-20-zero-poll-repair.md`.


### Namespace admission, source setup and promise disposal

Sandbox validation loads streamed source under an identity scoped to its unique
temporary module, retaining the logical source label and option index within
that scope. SWI's loader tracks source identities independently of destination
modules: shared names such as `sandbox_source_1` previously collided when
validations overlapped during nested startup. The common loading helper scopes
both numbered option sources and the unnumbered goal/source validation path.
Prechecks, whitelist loading options, source order and same-module reloading are
unchanged. The temporary-module lifetime and stream cleanup remain the existing
`setup_call_cleanup/3` paths. Regression tests keep two modules live together in
both sandbox modes, and check isolation, reloading, ordered source options,
forbidden directives and module reclamation after success and exceptions.

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


## Engineering evidence behind the research agenda

The book's [research and engineering
agenda](https://github.com/torbjornlager/boken/blob/main/author/appendix-research-agenda.tex)
records requirements and open questions. The following native SWI implementation reports
have moved here from its former Section 11.1. They describe bounded engineering work and
its qualifications, not portable guarantees for every node. The shared language manual
remains the authority for observable API behaviour and runtime differences; the
implementation sections above describe the mechanisms.

### Option validation, naming and synchronous calls

Native SWI validates `rpc/3`, `promise/4`, and `yield/3` at entry and restricts their
HTTP transport options to a documented subset. Extending this treatment to other
option-bearing APIs remains future work. Native `spawn/3` now validates options before
local setup or remote dispatch, with isolation-owned options declared through a
validation hook. The remote bare-actor endpoint validates client options before source
preparation and separates them from server-supplied framework metadata. Source ordering,
ordinary option precedence, and existing authority checks are retained. Native toplevel,
server, supervisor, and statechart creation wrappers also validate their own settings
and forwarded spawn options before starting work; remote toplevel entry points validate
before source preparation. These checks preserve framework metadata and existing
defaults. Native supervisors also validate complete initial child lists, recognised
server and nested-supervisor start forms, and dynamic additions before startup or
contact with the supervisor. Defaults, option precedence, and start-goal variable
sharing are retained.

Local named creation now reserves names and publishes them through
the startup handshake. Remote named creation now reserves the caller's alias before
dispatch and coordinates publication with observed lifecycle events. Failed startup
releases the reservation and requests termination of a known acknowledged pid. Remote
execution may precede alias publication, and an unacknowledged remote outcome may remain
unknown; distributed activation and broader lifecycle guarantees remain separate work.
Native synchronous toplevel wrappers now separate query and receive options, explicitly
select the calling actor as the answer target, and reject conflicting targets before
sending. This covers both creation-time defaults and later overrides without tracking
remote target state. Private monitoring now reports termination during synchronous waits
as `toplevel_down(Reason)` and is removed and flushed on every exit path, without
consuming existing monitors. Wait timeouts still leave the query running. Native
requests now carry fresh references through local execution and remote transport, so
later synchronous waits discard obsolete tagged replies without extending their
deadlines. Unsupported peers are rejected before a synchronous query is sent;
asynchronous operation remains available. Concurrent-client coordination remains
separate work.

### Ordinary registry lifecycle

Native local named creation now reserves a name in the caller's namespace before launch,
publishes it before the application goal runs, and releases pending reservations on
failure or cancellation. Publication and retirement share the registry mutex, so a fast
child cannot be named after its cleanup. Ordinary native `register/2` now checks local
actor existence under the same mutex as insertion and retirement, rejecting stale local
pids without changing remote alias registration. Neither operation guarantees continued
liveness after returning. Native remote-alias cleanup now withdraws bindings across
local namespaces on observed termination of the exact pid, or for affected pids known to
a lost connection. It creates no implicit monitors and retains no retirement records: an
unobserved termination can leave an alias, and later registration in an open namespace
can recreate one. Connection loss withdraws local names without proving remote death.
Explicit unregistration remains necessary where no lifecycle event is observed. Managed
namespace teardown now closes registration, removes ordinary names, and cancels pending
name reservations atomically. Late registration and name publication are rejected.
WebSocket teardown closes its shared namespace; HTTP session cleanup or local
session-actor retirement closes that session's namespace. Delegated transport namespaces
also close on explicit lineage closure. Bookkeeping replacement and individual request
completion do not end a namespace. These changes preserve actor lifetimes, the service
registry, and the standalone global namespace. Regression tests include namespace
teardown, surviving actors and pending name publication.

### Promise ownership and local resource lifecycle

Native SWI node composition records owners and checks them before collection or explicit
cleanup: stateful clients use node-scoped namespaces, authenticated stateless HTTP uses
node-scoped principal identity, and anonymous stateless HTTP uses individual request
identity. Trusted local sharing between threads and actors is preserved. Foreign
collection appears as an unavailable reference; foreign cleanup is a no-op. Tests cover
client and node isolation, authenticated collection across requests, anonymous request
isolation, and trusted sharing. Native collection, expiry and explicit local disposal
are now coordinated: one active collector is allowed, timeout or interruption releases
its claim, and a timed-out wait remains retryable. Successful collection consumes the
answer and reclaims the wake queue; expiry or cleanup invalidates the reference and
wakes an already waiting collector. Local expiry tasks and unfinished HTTP workers are
stopped, with stream cleanup as workers unwind. Threads not yet activated observe
disposal before starting work, and late completion cannot deliver to a destroyed queue.
Initialisation failures also roll back allocated resources. Regression tests cover
contention, expiry races, interruption, timeout callbacks and retry, and local resource
disposal. Native managed namespace teardown now disposes of its node-scoped promises,
wakes waiting collectors with an unavailable-reference error, and rejects new promises
under the closed namespace. Surviving actors remain alive but lose those references.
Creation, collection and teardown are coordinated; ordinary request completion and
ending one toplevel in a shared open WebSocket namespace do not trigger disposal.
Stateless HTTP owners and trusted local sharing keep their existing lifetimes. Ownership
transfer remains separate, and local disposal does not establish cancellation of remote
execution.


### Statechart processing model

Timed transitions and explicit event deferral have implementations and stated
semantics. The research agenda retains the separate task of turning those and
the rest of the processing model into a portable, testable contract.

### Nested supervisor specifications at query admission

The external ACTOR Behaviours BH-009 probe passes when its nested child list
is explicit in the submitted specification. The formerly reported timeout was
an admission-time `instantiation_error`, hidden by the external harness waiting
only for success. A list variable bound by an earlier conjunction is still
unbound during static checking: `supervisor_child_specs_calls/3` exposes it as
an unknown executable meta-call, which admission rejects. Trealla accepts that
runtime-bound form. Supporting it here needs runtime validation of the resolved
child starts before execution; simply skipping the static check would be
insufficient. No supervisor lifecycle code changed for this investigation.


### External statechart examples during repository extraction

The convenience `statechart_actor:interpret_example/1` uses
`WP_ASSET_ROOT/examples/statecharts` when a nonempty root is configured. An
explicit root does not fall back to another checkout if its example is missing.
Unset or empty configuration preserves the original module-relative path.
This lower-layer helper reads the setting directly from the process environment;
it does not import the node-layer asset resolver. Source loading, sandboxing
and ordinary `src_uri/1` resolution are unchanged.
