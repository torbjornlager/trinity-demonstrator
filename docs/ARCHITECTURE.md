# High-Level Architecture

This repository implements a small Web Prolog system in layers.

At the bottom is an actor runtime. On top of that sit a few reusable actor
behaviours such as toplevel query actors, generic servers, supervisors, and a
statechart interpreter. Above those behaviours sits the "node" layer, which
exposes the system over HTTP and WebSocket so it can be used as a remote
Prolog node.

The design goal is clarity rather than production hardening: most features are
implemented in direct, explicit code with minimal hidden machinery.

## The Main Idea

The central abstraction is an actor:

- one actor is one SWI-Prolog thread
- each actor has a stable logical pid
- actors communicate by mailbox messages
- actors can be linked and monitored
- each actor runs in its own temporary Prolog module

That last point is important. A spawned actor does not just get a new thread;
it also gets a private module where `load_text/1`, `load_list/1`,
`load_uri/1`, and `load_predicates/1` are loaded. This gives actors isolated
code environments while still allowing a node-wide shared database to be
imported.

## Layered Structure

### 1. Actor runtime

[`actor.pl`](../src/actor.pl) is the foundation.

It provides:

- spawning local actors and remote actors
- pids, links, monitors, name registration, and delayed sends
- selective receive
- actor I/O via `output/1` and `input/2`
- per-actor module preparation and source loading
- global pid normalization via `Id@Node`

The local path is straightforward:

1. `spawn/3` allocates a fresh pid.
2. A new thread is created.
3. The actor gets a private module.
4. Shared-db predicates are imported.
5. Any user-supplied source is loaded.
6. The start goal is executed in that module.

Remote actors are routed through the node controller in
[`node_controller.pl`](../src/node_controller.pl), which owns three small
tables tracking, for each remote pid this node knows about, the
local target, the cross-node monitors, and the cross-node links.
A remote spawn request goes over a shared WebSocket connection per
remote node; inbound JSON events are dispatched directly from the
WS reader to the registered local target or watcher.  Ordinary
`send/2`, `exit/2`, and monitor delivery for a remote pid all flow
through the controller without a per-pid local actor in between.
See [`CROSS_NODE_ARCHITECTURE.md`](CROSS_NODE_ARCHITECTURE.md) for
the wire protocol and lifecycle invariants.

### 2. Reusable actor behaviours

These modules all build on `actor.pl`:

- [`toplevel_actor.pl`](../src/toplevel_actor.pl)
  implements a query engine actor. It accepts `'$call'`, `'$next'`, and
  `'$stop'` messages and returns `success`, `failure`, or `error` terms. This
  is the execution engine behind both `/call` continuations and ISOTOPE
  sessions.
- [`server.pl`](../src/server.pl)
  provides a tiny `gen_server`-style request/reply loop with explicit state.
- [`supervisor_actor.pl`](../src/supervisor_actor.pl)
  implements supervisor strategies such as `one_for_one`, `one_for_all`, and
  `rest_for_one`.
- [`statechart_actor.pl`](../src/statechart_actor.pl)
  interprets the Web Prolog statechart profile by storing the parsed model in
  thread-local facts and driving execution through an actor event loop.

Together, these modules show the intended programming model: the core actor
runtime is small, and richer behaviours are ordinary libraries on top of it.

### 3. Node layer

[`node.pl`](../src/node.pl) turns the
runtime into a networked node.

It exposes three interaction styles:

- ISOBASE: stateless HTTP query execution through `/call`
- ISOTOPE: semi-stateful shell/session endpoints built on toplevel actors
- ACTOR: full actor access over WebSocket through `/ws`

It also exports client helpers like `rpc/2-3`, `promise/3-4`, and `yield/2-3`
so one node can call another.

## Request Flows

### Stateless `/call`

The stateless path is designed to look simple to clients while still avoiding
recomputation across pagination.

The flow is:

1. [`node_call_context.pl`](../src/node_call_context.pl)
   parses query parameters and turns text into a `Goal` and `Template`.
2. [`node_engine.pl`](../src/node_engine.pl)
   either reuses a cached toplevel actor or spawns a new one.
3. The toplevel actor evaluates a slice of solutions.
4. If more solutions remain, the toplevel pid is cached by goal hash and
   offset.
5. [`node_response.pl`](../src/node_response.pl)
   serializes the answer as Prolog text or JSON.

Conceptually, `/call` is "stateless at the HTTP boundary, stateful
internally".

### ISOTOPE session endpoints

ISOTOPE is the shell/session layer. A session is a long-lived toplevel actor
plus a dedicated message queue.

The flow is:

1. `/toplevel_spawn` creates a toplevel actor and registers a session queue.
2. `/toplevel_call` optionally refreshes the session's private loaded code and
   sends a query to the actor.
3. Output, prompts, success, failure, and errors are collected from the queue.
4. `/toplevel_next`, `/toplevel_poll`, `/toplevel_respond`, and
   `/toplevel_abort` keep interacting with the same session actor.

[`node_session.pl`](../src/node_session.pl)
holds most of the session-specific logic:

- queue bookkeeping
- session readiness handshake
- load-text persistence across calls
- rewriting `write/1`, `writeln/1`, and `read/1` into actor I/O

[`node_isotope_controller.pl`](../src/node_isotope_controller.pl)
is the thin controller layer that glues request parsing, session helpers, and
toplevel actor commands together.

### ACTOR WebSocket mode

[`node_ws.pl`](../src/node_ws.pl)
implements the ACTOR profile.

Each WebSocket connection gets:

- a reader loop that receives JSON commands
- a relay thread that sends JSON events back
- a per-connection queue that actors target for output/events

The browser can:

- spawn toplevel actors
- call/next/stop/abort/respond to them
- spawn bare actors
- send messages to actors
- exit actors

This is the most direct exposure of the actor runtime. The shell frontend in
[`demonstrator.html`](../web/demonstrator.html)
is the current demonstrator frontend and switches between stateless HTTP,
ISOTOPE, and ACTOR modes.

## Shared Database and Actor Code

Node startup options are parsed by
[`node_startup_options.pl`](../src/node_startup_options.pl).
They build one shared source text from:

- `load_shared_db_text/1`
- `load_shared_db_file/1`
- `load_shared_db_uri/1`

That shared database is:

- served at the node root `/`
- loaded once into a dedicated runtime module
- imported by actors when their private modules are prepared

This is an important design choice: shared-db clauses are not copied into each
actor's private database. Actors keep private code isolation, but they all see
the same shared predicates through module import.

Separately, actor-specific source options are handled by `actor.pl` and
[`source_utils.pl`](../src/source_utils.pl).
Those options affect only the spawned actor or session being prepared.

## Pids and Distribution

The code now uses a global pid model:

- local actors can be represented as `Id@Node`
- remote actors are represented as `Id@RemoteNode`
- helper predicates normalize between integer, atom/string, and compound forms

The purpose is to make distribution explicit and uniform. Local-only code can
still often work with plain integers, but the runtime has enough information to
route messages, exits, and session lookups correctly across node boundaries.

Cross-node messaging is mediated by the node controller in
[`node_controller.pl`](../src/node_controller.pl): one outbound WebSocket
connection per remote URL, three dynamic tables on the local node
(`remote_target_/2`, `remote_monitor_/3`, `remote_link_/2`), and a
single dispatch loop in `actor.pl`'s `remote_ws_dispatch/3`.
Higher-level code can treat remote actors much like local ones;
the controller handles delivery, monitor firing, and link
propagation transparently.  The full protocol and the lifecycle
invariants are documented in
[`CROSS_NODE_ARCHITECTURE.md`](CROSS_NODE_ARCHITECTURE.md).

## Response and Text Normalization

Several smaller modules keep the edge handling out of the main control code:

- [`node_response.pl`](../src/node_response.pl)
  converts internal answer terms into JSON or Prolog output and simplifies
  common error messages.
- [`node_client.pl`](../src/node_client.pl)
  implements the client side of the HTTP API and shared timeout/load-text
  normalization.
- [`node_isotope_options.pl`](../src/node_isotope_options.pl)
  parses spawn options for ISOTOPE endpoints and injects the shell prelude.
- [`dollar_expansion.pl`](../src/dollar_expansion.pl)
  stores recent variable bindings so the shell can support `$Var` expansion
  across queries.

These modules do not define new execution models. They keep the data plumbing
readable.

## How to Read the Code

A useful reading order is:

1. [`actor.pl`](../src/actor.pl)
2. [`node_controller.pl`](../src/node_controller.pl) — small companion to
   `actor.pl`; the three tables that drive cross-node routing
3. [`toplevel_actor.pl`](../src/toplevel_actor.pl)
4. [`node.pl`](../src/node.pl)
5. [`node_engine.pl`](../src/node_engine.pl)
6. [`node_session.pl`](../src/node_session.pl)
7. [`node_ws.pl`](../src/node_ws.pl)
8. Then the higher-level behaviours:
   [`server.pl`](../src/server.pl),
   [`supervisor_actor.pl`](../src/supervisor_actor.pl),
   and
   [`statechart_actor.pl`](../src/statechart_actor.pl)

That order moves from the core runtime outward to the protocols built on top of
it.  For a focused deep dive on the cross-node layer specifically, read
[`CROSS_NODE_ARCHITECTURE.md`](CROSS_NODE_ARCHITECTURE.md) alongside
the source files above.

## In One Sentence

This codebase is a compact actor-oriented Prolog runtime with three network
faces: stateless query calls, session-style shell calls, and full actor access
over WebSocket.
