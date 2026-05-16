# Authentication, Authorization, and Profile Enforcement

This document is the canonical summary of the current auth/profile model of the
Web Prolog PoC node.

It consolidates the former `AUTH_PLAN.md` and `PROFILE_PLAN.md` notes. The
companion matrix is kept separately in
[PROFILE_MATRIX.md](PROFILE_MATRIX.md).

## Final Model

Authentication, authorization, profile enforcement, ownership, and sandboxing
are separate layers:

- authentication answers who is calling
- authorization answers whether that principal may use the node or a resource
- profile enforcement answers whether the node supports the requested surface
- ownership answers whether a principal may control a given pid or session
- sandboxing answers whether submitted code is safe to execute

The key rule is that profile is node-scoped, not principal-scoped. If a
principal is authorized to execute on a node at all, that principal gets the
node's advertised profile, subject to route ceilings and ordinary ownership or
admin checks.

In practice, execution should be read as:

- `EffectiveProfile = min(NodeProfile, EndpointProfile)`

not as a principal-relative minimum.

## Authentication Sources

The current node supports:

- trusted-header authentication for HTTP and WebSocket requests
- local-only `auth(dev)` for browser testing on `localhost`
- anonymous access in `auth(open)`
- anonymous read-only access in `auth(private)`

Identity extraction lives in
[node_auth.pl](node_auth.pl).
The trust boundary is advertised through `/node_info`.

## Authorization Model

The current capability set is intentionally small:

- `public_read`
- `execute`
- `admin`
- `internal_transport`

Current meaning:

- `execute` gates `/call`, `/toplevel_*`, and `/ws`
- `admin` gates the admin API and implies the other capabilities
- `internal_transport` is reserved for node-to-node traffic

The older idea of per-principal capability ladders such as `stateless_call`
versus `session_use` versus `actor_spawn` is no longer the main model.

## Principal Policy

Authenticated identities are resolved against a node-owned principal table in
[node_principal_policy.pl](node_principal_policy.pl).

Supported startup forms include:

- `owner(Id)`
- `principal(Id, Capabilities)`

Legacy per-principal profile forms are rejected explicitly.

## Profile Enforcement

The node currently recognizes four profiles:

- `relation`
- `isobase`
- `isotope`
- `actor`

Current route ceilings are:

- `relation`: `/call`
- `isobase`: `/call`
- `isotope`: `/call`, `/toplevel_*`
- `actor`: `/call`, `/toplevel_*`, `/ws`

Out-of-profile routes fail with explicit `profile_violation` errors.

Profile checks are implemented for:

- submitted goals
- loaded source text
- source-loading options
- toplevel/spawn option structures

The main enforcement entry points are:

- [node_profile_policy.pl](node_profile_policy.pl)
- [node_sandbox.pl](node_sandbox.pl)

The profile checker and sandbox checker remain separate on purpose:

- profile checker answers “is this in-profile?”
- sandbox checker answers “is this safe?”

## Ownership and Admin Control

Ownership is enforced separately from profile and sandbox policy.

Implemented ownership checks include:

- HTTP ISOTOPE session ownership in
  [node_session.pl](node_session.pl)
- WebSocket actor and toplevel ownership in
  [node_ws.pl](node_ws.pl)

Admin control is not part of profile conformance. A deployment need not expose
an admin API at all. In this repository, the admin API and demonstrator admin
panel are demonstrator tooling layered on top of the core execution model.

## Implemented Today

The implemented model should be read as:

- route-level profile enforcement exists
- goal/source/option profile checks exist
- auth and ownership are implemented, but are distinct from profile
- node-profile semantics, not user-profile semantics, govern execution

The demonstrator reads `/node_info` and clamps its profile hints to the announced
node profile, but that is a frontend convenience rather than part of the core
contract.

## Deferred or Not Implemented

Still outside the implemented model:

- built-in login, cookie sessions, or OIDC
- audit trails for admin changes or ownership-sensitive events
- opaque session handles replacing raw pids
- separate forked sandbox implementations per profile
- a complete machine-readable predicate matrix exported by the node

The internal transport trust model also remains deployment-sensitive: trusted
headers are safe only behind a reverse proxy or equivalent boundary that strips
and re-injects them.

## Companion Documents

- [PROFILE_MATRIX.md](PROFILE_MATRIX.md)
  Exact route/language/source-loading contract matrix.
- [SANDBOX_AND_HARDENING.md](docs/policy/SANDBOX_AND_HARDENING.md)
  Sandbox policy and public-deployment hardening.
- [docs/archive/AUTH_PLAN.md](docs/archive/AUTH_PLAN.md)
  Archived detailed auth note.
- [docs/archive/PROFILE_PLAN.md](docs/archive/PROFILE_PLAN.md)
  Archived detailed profile note.
