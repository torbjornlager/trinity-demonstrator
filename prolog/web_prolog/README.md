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
| [isolation.pl](isolation.pl) | Per-actor temporary module isolation; `load_text/1`, `load_list/1`, `load_uri/1`, `load_predicates/1`. |
| [source_utils.pl](source_utils.pl) | Source-text and URI helpers shared by the isolation paths. |
| [actor_io_support.pl](actor_io_support.pl) | Actor I/O prelude support. |

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
| [statechart_model.pl](statechart_model.pl) | Statechart model parsing. |
| [statechart_runtime.pl](statechart_runtime.pl) | Statechart runtime helpers. |
| [statechart_exec.pl](statechart_exec.pl) | Statechart execution core. |
| [statechart_actor.pl](statechart_actor.pl) | Statechart actor interpreter. |
| [wasm/](wasm/) | A self-contained SWI-WASM port of the statechart behaviour (`statechart_wasm{,_model,_runtime,_exec}.pl`) for in-browser actors; imports only `library/` and its own siblings. |

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
| [actor_api.pl](actor_api.pl) | Legacy `actor.pl` API facade. |
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
