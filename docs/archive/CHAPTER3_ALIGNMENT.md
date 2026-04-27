# Chapter 3 Protocol Alignment

This document is archived. It is kept for historical context and has been superseded by a newer consolidated note.


This note compares the current implementation with the protocol architecture
described in Chapter 3 of [book.pdf](/Users/lager/boken/author/book.pdf).

The short version is:

- the current code clearly implements the same three protocol layers
- the public surface mostly matches the chapter
- the current node is less profile-pure than the chapter describes

Chapter 3 presents a clean protocol model. The codebase is a working system
with compatibility layers, frontend endpoints, sandbox policy, and practical
runtime details. That means the implementation mirrors the chapter well at the
architectural level, but not as an exact or strict embodiment.

## Overall Judgment

If the question is whether the implementation still follows the Chapter 3
protocol design, the answer is yes.

If the question is whether the implementation is a strict realization of the
profile model as presented in Chapter 3, the answer is no.

In particular:

- the three API layers are present
- the shell interaction model is recognizably the same
- the wire-level behavior and profile boundaries have drifted

## Already Matches Chapter 3

### Three API layers

The current node exposes the same three protocol families described in Chapter
3:

- stateless HTTP `/call`
- semi-stateful HTTP `/toplevel_*`
- stateful WebSocket actor interaction

Relevant code:

- [node.pl](node.pl#L16)
- [node.pl](node.pl#L127)
- [node_ws.pl](node_ws.pl#L3)

### Node root and shell entry point

Chapter 3 presents the node root as the shared database and `/shell` as the
interactive entry point. The current implementation still does that.

Relevant code:

- [node.pl](node.pl#L145)
- [node.pl](node.pl#L136)

### PTCP-like semi-stateful shell

The HTTP session API is very close to the shell-oriented PTCP flow described in
the chapter:

- `/toplevel_spawn`
- `/toplevel_call`
- `/toplevel_next`
- `/toplevel_poll`
- `/toplevel_respond`
- `/toplevel_stop`
- `/toplevel_abort`

Relevant code:

- [node.pl](node.pl#L117)
- [node_isotope_controller.pl](node_isotope_controller.pl)
- [node_session.pl](node_session.pl)

### Shell-style JSON result vocabulary

The current implementation still uses the same broad answer categories that
Chapter 3 relies on:

- `success`
- `failure`
- `error`
- `output`
- `prompt`
- `spawned`
- `abort`
- `down`

Relevant code:

- [node_response.pl](node_response.pl#L53)

### ACTOR profile idea

The WebSocket side does expose full actor-style control rather than only remote
querying. This matches the chapter's claim that the ACTOR profile adds real
concurrency and bidirectional interaction.

Relevant code:

- [node_ws.pl](node_ws.pl#L174)
- [actor.pl](actor.pl)
- [toplevel_actor.pl](toplevel_actor.pl)

## Minor Naming and Surface Drift

These differences do not change the basic architecture, but they do mean the
current node does not present exactly the same surface as the chapter.

### WebSocket endpoint name

Chapter 3 uses a WebSocket endpoint of the form:

- `ws://n7.org/actor`

The current code uses:

- `/ws`

Relevant code:

- [node_ws.pl](node_ws.pl#L69)

This is a naming drift, not a structural one.

### Extra HTTP routes

The codebase now exposes several routes that are outside the protocol model of
Chapter 3:

- `/workbench`
- `/tutorial`
- `/editor_frame`
- `/node_info`
- `/img`
- `/examples`
- `/statecharts`

Relevant code:

- [node.pl](node.pl#L136)

These are frontend or support routes. They do not contradict Chapter 3, but
they are not part of its protocol story.

### Canonical pid model

Chapter 3 mostly presents pids as simple numeric ids. The current runtime uses
canonical `Id@Node` pids internally and preserves local integer compatibility at
the JSON boundary.

Relevant code:

- [node_response.pl](node_response.pl#L98)
- [pid_utils.pl](pid_utils.pl)

This is a practical improvement, but it is more explicit than the chapter.

## Meaningful Semantic Drift

These are the places where the current code no longer cleanly matches the
protocol model of Chapter 3.

### Profiles are not enforced as deployed node modes

Chapter 3 presents RELATION, ISOBASE, ISOTOPE, and ACTOR as profiles with
different capability envelopes. The current node exposes all main APIs at once.

Relevant code:

- [node.pl](node.pl#L127)

In practice this means:

- the code reflects the profile hierarchy conceptually
- the deployed node behaves more like a superset node than a strict profile node

### ISOBASE behavior is now policy-driven, not profile-pure

Chapter 3 treats the stateless API as fundamentally limited: no interruptible
session, no actor-private database mutation, no interactive I/O.

The current implementation moved that question into sandbox policy. This is a
reasonable engineering move, but it is not the same as the chapter's cleaner
profile semantics.

Relevant code:

- [node_sandbox.pl](node_sandbox.pl)
- [node.pl](node.pl#L107)

So the implementation is now better described as:

- one rich node
- with policy restrictions

rather than:

- several sharply distinct protocol profiles

### WebSocket protocol is richer than the chapter's presentation

Chapter 3 presents the ACTOR WebSocket protocol mainly through shell/toplevel
examples. The current implementation exposes more than that:

- bare `spawn`
- `send`
- `exit`
- connection-owned actor tracking
- extra event forms such as `statechart_trace`

Relevant code:

- [node_ws.pl](node_ws.pl#L196)
- [node_response.pl](node_response.pl#L73)

This is not wrong. It is simply a broader realized protocol than the chapter
documents.

### Local shell behavior has accumulated presentation logic

The chapter describes protocol behavior. The current frontend layers now
implement additional presentation-level behavior:

- local pid shortening
- `$Var` expansion
- logger formatting
- statechart trace rendering
- tutorial adaptation

Relevant code:

- [shell.html](shell.html)
- [workbench.html](workbench.html)

That is useful, but it means the observed shell behavior is no longer a pure
expression of the protocol alone.

## Net Assessment by Protocol Family

### Stateless HTTP `/call`

Alignment level: medium to strong

Why:

- request/response shape matches Chapter 3 well
- lazy backtracking via `limit` and `offset` is present
- JSON answers are the expected ones

Where it drifts:

- current node policy can permit more than the chapter's profile model would
  suggest
- sandbox and timeout behavior are implementation-policy details, not part of
  the chapter's cleaner story

Relevant code:

- [node.pl](node.pl#L114)
- [node_engine.pl](node_engine.pl)

### Semi-stateful HTTP `/toplevel_*`

Alignment level: strong

Why:

- this is the closest part of the implementation to the chapter's PTCP-style
  interaction model
- the same shell semantics are clearly visible

Where it drifts:

- response/event details are slightly richer in practice
- current UI layers add behavior on top

Relevant code:

- [node.pl](node.pl#L117)
- [node_isotope_controller.pl](node_isotope_controller.pl)
- [toplevel_actor.pl](toplevel_actor.pl)

### Stateful WebSocket `/ws`

Alignment level: medium to strong

Why:

- it clearly realizes the ACTOR-profile idea of push-driven, bidirectional,
  actor-capable interaction

Where it drifts:

- endpoint name differs
- the concrete command set is richer than the chapter shows
- ownership and sandbox checks add implementation semantics not discussed in
  Chapter 3

Relevant code:

- [node_ws.pl](node_ws.pl#L7)

## If Tighter Alignment with Chapter 3 Is a Goal

These are the highest-value changes.

### 1. Make node profiles explicit deployment modes

Instead of exposing all APIs from one node by default, support explicit node
modes such as:

- relation
- isobase
- isotope
- actor

That would make the implementation match the chapter's profile story much more
closely.

### 2. Decide whether `/ws` should be renamed or simply documented

If exact alignment matters, use the chapter's naming more closely.

If backward compatibility matters more, keep `/ws` and document the difference
clearly.

### 3. Tighten ISOBASE behavior if profile purity matters

If the code is meant to demonstrate the chapter faithfully, then `/call` should
be constrained according to the chapter's stateless model, not merely by
sandbox policy.

### 4. Decide how much canonical pid visibility should leak into the public model

The current `Id@Node` model is good engineering, but the book's examples are
simpler. Either:

- update the book-facing documentation to embrace canonical pids
- or hide them more aggressively at the UI/protocol boundary

## Bottom Line

The implementation still mirrors Chapter 3 in the way that matters most:

- same protocol layers
- same shell-oriented interaction model
- same actor-oriented direction

But it is now a more practical and somewhat messier system than the cleaner
profile model presented in the chapter.

That is not a criticism of the current code. It just means that Chapter 3 is
still the design source, while the implementation has accumulated compatibility,
policy, and UI concerns that the chapter intentionally abstracts away.
