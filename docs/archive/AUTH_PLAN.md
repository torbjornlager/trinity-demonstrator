# Authentication and Authorization Status

This document is archived. It is kept for historical context and has been superseded by a newer consolidated note.


This document records the current authentication and authorization model of
the Web Prolog PoC node.

It supersedes the earlier staged plan. The implementation no longer follows
the abandoned "per-principal profile ceiling" idea. Profiles are now treated
as node-level contracts, while authorization is kept separate.


## Final Model

Authentication, authorization, profiles, and sandboxing are separate layers:

- authentication answers who is calling
- authorization answers whether that principal may use the node or a resource
- profile enforcement answers whether the node supports the requested surface
- sandboxing answers whether the submitted code is safe to execute

The node profile is node-scoped, not principal-scoped. If a principal is
authorized to execute on a node at all, that principal gets the node's
advertised profile, subject only to the endpoint ceiling and ordinary
authorization checks such as ownership.

Administrative control is not part of node-profile conformance. A node is not
required to expose an admin API or admin UI. In this repository, the admin
API and the demonstrator admin panel are demonstrator tooling.


## Implemented

### Authentication sources

The current node supports:

- trusted-header authentication for HTTP and WebSocket requests
- local-only `auth(dev)` for browser testing on `localhost`
- anonymous access in `auth(open)`
- anonymous read-only access in `auth(private)`

Identity is extracted in
[node_auth.pl](node_auth.pl).
`/node_info` advertises the trust boundary and trusted header names in
[node.pl](node.pl#L617).


### Authorization model

The current capability set is intentionally small:

- `public_read`
- `execute`
- `admin`
- `internal_transport` (reserved for node-to-node traffic)

In the current model:

- `execute` gates `/call`, `/toplevel_*`, and `/ws`
- `admin` gates the admin API and implies all other capabilities

There is intentionally no longer a separate per-principal capability ladder
such as `stateless_call` vs `session_use` vs `actor_spawn`. That older model
conflicted with the book's node-profile semantics.

Legacy `source_load_server_predicates` and `source_load_uri` capability names
are still accepted in principal policy for backward compatibility, but they no
longer narrow ordinary execution. If a node advertises a profile that
includes those source-loading features, every execute-authorized principal
gets them.


### Principal policy

Authenticated identities are resolved against a node-owned principal table in
[node_principal_policy.pl](node_principal_policy.pl).

Supported startup forms are:

- `owner(Id)`
- `principal(Id, Capabilities)`

Legacy per-principal profile forms are now rejected explicitly:

- `principal(Id, Capabilities, Profile)` is rejected
- policy dicts containing `profile` are rejected


### Ownership enforcement

Ownership is enforced separately from profile and sandbox policy.

Implemented ownership checks:

- HTTP ISOTOPE session ownership in
  [node_session.pl](node_session.pl)
- WebSocket actor and toplevel ownership in
  [node_ws.pl](node_ws.pl)

WS ownership is enforced independently of sandbox mode. Internal node-to-node
transport bypasses user-facing ownership checks through the reserved
`internal_transport` capability.


### Per-node runtime config and admin API

Auth mode, profile, sandbox mode, dev-auth config, and principal policy are
request-scoped per node through
[node_runtime_state.pl](node_runtime_state.pl).

Admin-only endpoints are implemented in
[node_admin.pl](node_admin.pl):

- `GET`/`POST /admin/config`
- `GET`/`POST /admin/principals`

The demonstrator includes a small demonstrator UI on top of this API in
[demonstrator.html](demonstrator.html).


## Deferred

The following items are still outside the implemented auth/authz model:

- no built-in login, cookie session management, or OIDC flow
- no audit trail for admin changes or session/actor ownership events
- no opaque session handles; raw pids remain the public resource identifiers
- no guarantee that a deployment exposes the admin API at all

The internal transport trust model also remains deployment-sensitive:

- node-to-node traffic uses trusted headers
- this is safe only behind a reverse proxy or equivalent boundary that strips
  and re-injects those headers


## Remaining Process-Global Limits

The main node-facing runtime resources are now isolated per node, including:

- shared DB source/module used by HTTP and WS execution
- `/call` continuation cache
- timeout/cache tuning

The main remaining process-global behavior is only the no-context local
fallback used for direct in-process experimentation. See
[APPENDIX_A_PROCESS_GLOBAL_LIMITATIONS.tex](APPENDIX_A_PROCESS_GLOBAL_LIMITATIONS.tex)
for a short write-up suitable for the book appendix.


## Recommended Next Hardening Steps

If this repo continues beyond demonstrator scope, the next security steps are:

1. decide whether to keep or remove the no-context global fallback for local
   convenience use
2. make the reverse-proxy trust boundary part of deployment docs and startup
   messaging
3. add optional audit logging for admin changes and ownership-sensitive events
4. keep the auth model aligned with the advertised profile contract as the
   source-loading surface evolves
