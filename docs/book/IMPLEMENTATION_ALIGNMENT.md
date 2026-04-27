# Implementation Alignment with the Book

This document is the canonical summary of how the current implementation lines
up with the book-facing descriptions.

It consolidates the former `MANUAL_ALIGNMENT.md` and `CHAPTER3_ALIGNMENT.md`
notes.

## Overall Judgment

The current code still reflects the same core model as the book:

- actor-first runtime
- three protocol families
- shell/toplevel interaction built on mailbox protocols
- Erlang-style concurrency as the main organizing idea

The implementation is therefore aligned with the book at the architectural
level.

It is not, however, a line-by-line realization of every book-era surface or
example. The main drift is in concrete deployment shape, pid semantics,
frontend routes, and the increasing role of policy and sandbox enforcement.

## What Still Matches Well

### Actor-First Structure

The repository is still actor-first. `actor.pl` remains the foundation, with
higher-level pieces layered on top.

### Toplevel, Supervisor, and Statechart Stories

The book-level stories for:

- toplevel actors
- supervisors
- statechart actors
- remote querying via `rpc/3`

still match the code conceptually and, in large part, operationally.

### Three Protocol Layers

The current node still exposes the same three broad protocol families described
in the book:

- stateless HTTP `/call`
- semi-stateful HTTP `/toplevel_*`
- stateful WebSocket actor interaction

## Important Implementation Drift

### 1. Distribution Is No Longer Merely Aspirational

Remote `node(+URI)` support is now implemented rather than being mostly
vision-level.

### 2. The Pid Model Is Now Explicitly Global

The runtime has moved toward canonical global pids of the form `Id@Node`, even
though some JSON-facing surfaces still preserve local integer compatibility for
backward compatibility.

### 3. `link(true)` Is Directional

The current implementation uses parent-to-child lifetime coupling rather than
Erlang-style symmetric links.

### 4. Shared DB Source Is Imported, Not Copied

The node loads shared source into a dedicated runtime module and imports that
module into actor modules. Shared clauses are therefore not duplicated into
private actor databases.

### 5. The Node Surface Is Richer Than Older Drafts Describe

The repository now exposes a broader surface than the older manual and Chapter
3 descriptions emphasize, including:

- `/workbench`
- `/tutorial`
- `/editor_frame`
- `/node_info`
- `/examples`
- `/statecharts`
- `/ws`

### 6. The WebSocket API Is No Longer a TODO

The ACTOR-profile WebSocket API is a first-class implemented part of the
system, not a placeholder.

### 7. Profile Semantics Are More Policy-Driven in Practice

The book presents profiles as sharply separated capability envelopes. The
current implementation is better described as a rich node with explicit route
ceilings and policy checks.

This is a reasonable engineering move, but it is less profile-pure than the
cleanest book formulation.

## Practical Reading of the Current Repo

The current repository should be read as:

- architecturally aligned with the book
- operationally more explicit about pids, routes, and deployment policy
- more frontend-heavy than the book's pure protocol story
- more policy-driven in profile behavior than some earlier draft text suggests

## When to Use Which Document

Use this document when you want the short answer to:

- “Is the code still the same system the book describes?”
- “Where are the main differences now?”

Use the archived source notes when you need the longer detailed comparison.

## Archived Detailed Notes

- [docs/archive/MANUAL_ALIGNMENT.md](docs/archive/MANUAL_ALIGNMENT.md)
- [docs/archive/CHAPTER3_ALIGNMENT.md](docs/archive/CHAPTER3_ALIGNMENT.md)
