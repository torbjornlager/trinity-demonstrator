# High-Level Architecture

This repository implements a production Web Prolog node for SWI-Prolog as a
stack of **independently loadable layers connected by multifile hooks**. The
syntax and semantics are frozen to the trinity-demonstrator; the layering is
the engineering difference (see
[`LAYERED_REAL_NODE_PLAN.md`](LAYERED_REAL_NODE_PLAN.md) for the full design
and rationale).

The runtime code lives under [`prolog/web_prolog/`](../prolog/web_prolog) and
is loaded as `library(web_prolog)` — the umbrella module
[`prolog/web_prolog.pl`](../prolog/web_prolog.pl) reexports the public layers.
`?- [load].` then `?- node(3060).` starts a node.

> **Note on `src/`.** The repository also contains [`src/`](../src), the
> original demonstrator code. It is **not** loaded by the node; it is kept
> frozen as the *conformance reference* exercised by the LEGACY test tier, so
> the layered node can be checked for behavioural parity against it. When
> reading the architecture, ignore `src/` — the important code is under
> `prolog/web_prolog/`.

## The Main Idea

The central abstraction is an actor:

- one actor is one SWI-Prolog thread
- each actor has a stable, **opaque** pid
- actors communicate by mailbox messages
- actors can be linked and monitored
- each actor runs in its own temporary Prolog module

That last point is important. A spawned actor does not just get a new thread;
it also gets a private module where `load_text/1`, `load_list/1`,
`load_uri/1`, and `load_predicates/1` are loaded. This gives actors isolated
code environments while still allowing a node-wide shared database to be
imported.

## How the layers compose

The decisive pattern is that **a lower layer never imports a higher one**. The
actor core does not know about isolation, distribution, or the node; each upper
layer attaches itself by providing clauses for `multifile` hook predicates that
the lower layer calls. A LINT test tier enforces that imports only point
downward.

- [`actors.pl`](../prolog/web_prolog/actors.pl) declares hooks such as
  `hook_goal/3`, `hook_spawn/3`, `hook_send/2`, `hook_self/1`,
  `hook_admit_spawn/2`, and `hook_spawn_commit/2` — each with a single call
  site in the core.
- A layer like [`distribution.pl`](../prolog/web_prolog/distribution.pl)
  supplies `actors:hook_self/1`, `hook_spawn/3`, and `hook_send/2` to add
  `Id@Node` pids without the core knowing anything about networking.
- The actors↔isolation coupling lives **only** in the composition spine
  [`composition.pl`](../prolog/web_prolog/composition.pl), which wires
  isolation's `with_source/2` into every local spawn through `actors:hook_goal`.

Because the wiring is external, each layer is also usable on its own:
`library(web_prolog/actors)` is a stand-alone actor core with full SWI-Prolog
available and no further dependencies; `library(web_prolog/isolation)`,
`library(web_prolog/toplevel_actors)`, the behaviours,
`library(web_prolog/distribution)`, and `library(web_prolog/rpc)` are each
usable without the layers above them.

## Layered Structure

### 1. Actor runtime (layer 0)

[`actors.pl`](../prolog/web_prolog/actors.pl) is the foundation. It has **zero
project imports** — only `library` dependencies and its own hooks.

It provides:

- spawning local actors
- opaque pids, links, monitors, name registration, and delayed sends
- selective receive
- actor I/O via `output/1` and `input/2`
- spawn-admission and spawn lifecycle hooks (so an upper layer can impose a
  global actor ceiling, cap per-actor stack, or take over spawning)

The public façade is [`actor_api.pl`](../prolog/web_prolog/actor_api.pl).

The local spawn path is straightforward:

1. `spawn/3` allocates a fresh opaque pid and reserves an admission slot.
2. A new thread is created.
3. The actor gets a private module (via the isolation hook).
4. Shared-db predicates are imported.
5. Any user-supplied source is loaded.
6. The start goal is executed in that module.

### 2. Isolation

[`isolation.pl`](../prolog/web_prolog/isolation.pl) is freestanding (it depends
on module machinery, not on actors). It owns per-actor module preparation and
source loading, exposing `with_source/2` plus its own hooks
(`prepare_module`, `prepare_goal`, `approve_source`) that the node layer fills
in with sandbox policy. The actor core invokes it only through
[`composition.pl`](../prolog/web_prolog/composition.pl).

### 3. Reusable actor behaviours

These build on the actor core as ordinary libraries:

- [`toplevel_actors.pl`](../prolog/web_prolog/toplevel_actors.pl) implements a
  query-engine actor (the pengine protocol). It accepts `'$call'`, `'$next'`,
  and `'$stop'` messages and returns `success`, `failure`, or `error`. This is
  the execution engine behind both `/call` continuations and ISOTOPE sessions.
  [`dollar_expansion.pl`](../prolog/web_prolog/dollar_expansion.pl) supports
  `$Var` expansion across queries.
- [`server_actor.pl`](../prolog/web_prolog/server_actor.pl) provides a tiny
  `gen_server`-style request/reply loop with explicit state.
- [`supervisor_actor.pl`](../prolog/web_prolog/supervisor_actor.pl) implements
  supervisor strategies (`one_for_one`, `one_for_all`, `rest_for_one`).
- [`statechart_actor.pl`](../prolog/web_prolog/statechart_actor.pl) interprets
  the Web Prolog statechart profile.
- [`parallel.pl`](../prolog/web_prolog/parallel.pl) implements `parallel/1`.

### 4. Distribution

[`distribution.pl`](../prolog/web_prolog/distribution.pl) adds `Id@Node` pids
and remote spawn/send/monitor/link by supplying actor hooks;
[`remote_protocol.pl`](../prolog/web_prolog/remote_protocol.pl) is the wire
protocol, and [`rpc.pl`](../prolog/web_prolog/rpc.pl) exposes the client
helpers `rpc/2-3`, `promise/3-4`, and `yield/2-3`. The full protocol and
lifecycle invariants are in
[`CROSS_NODE_ARCHITECTURE.md`](CROSS_NODE_ARCHITECTURE.md).

### 5. Node layer

[`node.pl`](../prolog/web_prolog/node.pl) turns the runtime into a networked
node. It exposes three interaction styles:

- **ISOBASE**: stateless HTTP query execution through `/call`
- **ISOTOPE**: semi-stateful shell/session endpoints built on toplevel actors
- **ACTOR**: full actor access over WebSocket through `/ws`

The node attaches all of its policy to the lower layers **through their hooks**,
concentrated in [`node_glue.pl`](../prolog/web_prolog/node_glue.pl): the global
`max_actors` ceiling via `hook_admit_spawn/2`, the per-actor stack cap via
`hook_thread_options/1`, sandbox checks via the isolation hooks, the
registry/visibility namespace, and the WS-owned-actor lifecycle. Profiles,
auth, capabilities, rate/concurrency/input limits, IP policy, logging, metrics,
and the admin surface are separate `node_*.pl` modules.

## Request Flows

### Stateless `/call`

"Stateless at the HTTP boundary, stateful internally" — it avoids recomputation
across pagination:

1. [`node_call_context.pl`](../prolog/web_prolog/node_call_context.pl) parses
   query parameters into a `Goal` and `Template`.
2. [`node_engine.pl`](../prolog/web_prolog/node_engine.pl) reuses a cached
   toplevel actor or spawns a new one.
3. The toplevel actor evaluates a slice of solutions.
4. If more remain, the toplevel pid is cached by goal hash and offset.
5. [`node_response.pl`](../prolog/web_prolog/node_response.pl) serializes the
   answer as Prolog text or JSON.

### ISOTOPE session endpoints

A session is a long-lived toplevel actor plus a dedicated message queue:

1. `/toplevel_spawn` creates a toplevel actor and registers a session queue.
2. `/toplevel_call` optionally refreshes the session's private loaded code and
   sends a query.
3. Output, prompts, success, failure, and errors are collected from the queue.
4. `/toplevel_next`, `/toplevel_poll`, `/toplevel_respond`, and
   `/toplevel_abort` keep interacting with the same session.

[`node_session.pl`](../prolog/web_prolog/node_session.pl) holds the
session-specific logic (queue bookkeeping, readiness handshake, load-text
persistence across calls, and rewriting `write/1`, `writeln/1`, `read/1` into
actor I/O). [`node_isotope_controller.pl`](../prolog/web_prolog/node_isotope_controller.pl)
is the thin controller that glues request parsing, session helpers, and
toplevel-actor commands together.

### ACTOR WebSocket mode

[`node_ws.pl`](../prolog/web_prolog/node_ws.pl) implements the ACTOR profile.
Each WebSocket connection gets a reader loop (JSON commands in), a relay thread
(JSON events out), and a per-connection queue that actors target for
output/events. The browser can spawn toplevel actors, call/next/stop/abort/
respond to them, spawn bare actors, send messages, and exit actors. This is the
most direct exposure of the actor runtime; the demonstrator frontend is
[`demonstrator.html`](../web/demonstrator.html), and the owner console is
[`admin.html`](../web/admin.html).

## Shared Database and Actor Code

Node startup options are parsed by
[`node_startup_options.pl`](../prolog/web_prolog/node_startup_options.pl). They
build one shared source text (from `load_shared_db_text/1`,
`load_shared_db_file/1`, `load_shared_db_uri/1`) that is served at the node root
`/`, loaded once into a dedicated runtime module, and **imported** by actors
when their private modules are prepared. Shared-db clauses are not copied into
each actor; actors keep private code isolation but all see the same shared
predicates through module import. Actor-specific source options are handled by
the isolation layer.

## Pids and Distribution

The core uses **opaque pids**: a pid is an abstract token, not a structured
`Id@Node` term baked into the runtime. Distribution is layered on top — when
[`distribution.pl`](../prolog/web_prolog/distribution.pl) is loaded, it
globalizes self and routes sends through `Id@Node` via the actor hooks, so
local-only code is unaffected and cross-node code gets uniform routing. Cross
-node messaging, monitor firing, and link propagation are documented in
[`CROSS_NODE_ARCHITECTURE.md`](CROSS_NODE_ARCHITECTURE.md).

## How to Read the Code

A useful reading order moves from the core outward:

1. [`actors.pl`](../prolog/web_prolog/actors.pl) — the layer-0 core and its hooks
2. [`isolation.pl`](../prolog/web_prolog/isolation.pl) and
   [`composition.pl`](../prolog/web_prolog/composition.pl) — module isolation
   and the spine that wires it into spawning
3. [`toplevel_actors.pl`](../prolog/web_prolog/toplevel_actors.pl)
4. [`distribution.pl`](../prolog/web_prolog/distribution.pl) +
   [`rpc.pl`](../prolog/web_prolog/rpc.pl) (with
   [`CROSS_NODE_ARCHITECTURE.md`](CROSS_NODE_ARCHITECTURE.md))
5. [`node.pl`](../prolog/web_prolog/node.pl) and
   [`node_glue.pl`](../prolog/web_prolog/node_glue.pl) — the node and how its
   policy attaches through hooks
6. [`node_engine.pl`](../prolog/web_prolog/node_engine.pl),
   [`node_session.pl`](../prolog/web_prolog/node_session.pl),
   [`node_ws.pl`](../prolog/web_prolog/node_ws.pl)
7. The behaviours:
   [`server_actor.pl`](../prolog/web_prolog/server_actor.pl),
   [`supervisor_actor.pl`](../prolog/web_prolog/supervisor_actor.pl),
   [`statechart_actor.pl`](../prolog/web_prolog/statechart_actor.pl)

## In One Sentence

This codebase is a compact, hook-layered actor-oriented Prolog runtime with
three network faces — stateless query calls, session-style shell calls, and
full actor access over WebSocket — frozen in semantics to the demonstrator kept
under `src/`.
