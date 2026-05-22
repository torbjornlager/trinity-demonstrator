# Security Report

A consolidated description of the current security posture of this
Web Prolog demonstrator: the threat model, the defences in place,
the explicit limitations, and what would have to change for a
production deployment.

This report is intended for the demonstrator's operator, for
readers of Chapter 4 of *The Prolog Trinity*, and for anyone porting
the implementation who needs to know what is required for a port
to remain safe.

This is a demonstrator, not a production system.  Several of the
defences below are sufficient for "small public node on the open
internet, no user accounts, audited but not tested adversarially."
Section 9 collects what would change before that classification
could be relaxed.

---

## 1. Scope and threat model

The four public nodes (`n1`–`n4` at `elfenbenstornet.se`) are
exposed to the open internet behind a Caddy reverse proxy in a
single-host Docker compose deployment.  An `admin` node runs
local-only.

**Adversary model.**  We assume:

- An attacker can reach any of `n1`/`n2`/`n3`/`n4` over HTTPS from
  the public internet.
- An attacker can run arbitrary code in a victim's browser by
  serving a page from `evil.example`.
- An attacker can attempt to forge any HTTP request, including
  setting any headers and Origin, and can attempt any wire-level
  protocol probing of the WebSocket endpoint.
- An attacker may be in the same RFC1918 private network as the
  host (e.g. if the host were re-deployed to a multi-tenant cloud
  subnet).  We do not assume this for the current deployment
  because the Docker bridge is the only private network reachable
  from the host.

**Out of scope.**  We do not defend against:

- A compromise of the host operating system or the Docker daemon.
- A compromise of the Caddy reverse proxy or its TLS certificates.
- Side-channel attacks on the Prolog interpreter (timing, cache).
- Operator error in editing the deployment (e.g. exposing
  `wp_n3:3053` directly in compose.yaml).  The defences below are
  designed to fail closed under most operator mistakes but cannot
  promise that property under all possible misconfigurations.

**Assets we are protecting.**

- The host operating system, file system, and network from
  arbitrary client code (the *inexpressibility* boundary).
- The set of running actors on each node from observation,
  enumeration, or hijack by another client (the *invisibility*
  boundary).
- Each client's spawned work from outliving its session (the
  *containment* boundary).
- The node owner's ability to install services, mediate access,
  and observe activity (the *operator* boundary).

This mirrors the three structural mechanisms described in book
§4.6 — inexpressibility, invisibility, containment — plus a
deployment layer.

---

## 2. Trust boundaries at a glance

A request to a node passes through these gates, in order:

1. **TLS termination** at Caddy.  Public DNS hits Caddy on `443`;
   Caddy presents the per-host certificate.
2. **Header sanitisation** at Caddy.  All inbound
   `X-Web-Prolog-User`, `X-Web-Prolog-Principal`,
   `X-Web-Prolog-Capabilities`, `X-Web-Prolog-Caps`,
   `X-Web-Prolog-Internal-Proxy`, and `X-Authenticated-User`
   headers are *stripped* before the request reaches the upstream.
   See `(common_proxy_headers)` in
   [Deployment/Caddyfile](Deployment/Caddyfile).
3. **Path allow-list** at Caddy.  Each `@allowed` matcher lists
   exactly the paths the node exposes (e.g. `/call`, `/portal`,
   `/ws`, `/toplevel_*`).  Anything else gets `404` without
   reaching the upstream.
4. **WebSocket Origin check** at the node, on `/ws` only.  See §5.
5. **Profile gate** at the node.  The route's effective profile is
   computed from `node_profile_mode(NodeProfile)` and the route's
   `endpoint_profile_ceiling`; a route disallowed by the profile
   returns a `profile_violation` error.
6. **Principal resolution and capability gate**.  The request's
   principal is derived from authenticated headers (§3) or
   defaults to `anonymous`.  Routes call
   `require_route_access(Principal, RouteId)` → `require_execution_access` →
   require the `execute` capability.
7. **Sandbox check** on any Prolog source or goal supplied by the
   client.  Profile-based, applied uniformly regardless of
   principal.

The first three gates are deployment-layer (Caddy).  Gates 4–7 are
in the Prolog node.

---

## 3. Authentication modes

The node's `auth(...)` startup option selects one of three modes.

| Mode | Anonymous capabilities | Authenticated principals | Dev shortcut |
|---|---|---|---|
| `open`    | `[public_read, execute]` | Yes (via `principal_policy/2` or `internal_transport`) | No |
| `private` | `[public_read]` only | Yes | No |
| `dev`     | `[public_read]` only | Yes | Yes — loopback peer gets the configured dev principal |

The four public production nodes use `auth(open)`.  This means an
unauthenticated browser visitor passes the execute-capability gate
and can drive the node's normal user-facing surface (the `/call`
endpoint, the portal, and on actor nodes the WS commands).

`auth(dev)` is dormant on the production nodes and was hardened
([node_auth.pl:381](node_auth.pl:381)) so that the default
`dev_capabilities` is `[execute]` rather than `[admin]` — the old
default was a foot-gun.  `auth(dev)` requires the request peer to
be loopback; the documentation now warns that a same-host reverse
proxy in front of the node would defeat this check, and explicitly
recommends restricting `auth(dev)` to direct loopback access.

---

## 4. The `internal_transport` capability

`internal_transport` is the cross-node-trust capability.  Holding
it lets the bearer:

- bypass per-pid ownership checks for `ws_actor` operations
  ([node_ws.pl:661–663](node_ws.pl:661));
- bypass the per-principal rate limit
  ([node_rate_limits.pl:223](node_rate_limits.pl:223));
- bypass the per-principal resource caps
  ([node_limits.pl:287–289](node_limits.pl:287)).

It does **not** bypass the Prolog-level sandbox.  The sandbox is
profile-based, not principal-based, and applies to every source
and every goal regardless of which principal submitted them.

### 4.1 Who is granted `internal_transport`

A request is granted `internal_transport` iff *all three* of the
following hold ([node_auth.pl:260–293](node_auth.pl:260)):

1. The `X-Web-Prolog-User` header value starts with `"node:"`.
2. The `X-Web-Prolog-Capabilities` header lists
   `internal_transport`.
3. The HTTP peer address is either loopback (`127.0.0.1` / `::1`)
   or in an RFC1918 private range (`10/8`, `172.16/12`,
   `192.168/16`).

The third condition is the *network-trust* gate; conditions 1 and
2 are claims that have no weight without it.

The earlier behaviour, in which the
`X-Web-Prolog-Internal-Proxy: true` header alone was sufficient
for condition 3, was removed.  Header-only trust was unsafe under
any deployment in which the node's HTTP port was reachable from
the internet without a header-stripping reverse proxy, because the
header itself can be set by any attacker.

### 4.2 Why this is safe for the current deployment

- Browser visitors connect to Caddy on `:443`.  Caddy strips the
  five `X-Web-Prolog-*` headers from inbound traffic (gate 2 in
  §2).  Even if the visitor crafts a request with
  `X-Web-Prolog-Capabilities: internal_transport`, Caddy drops it
  before the upstream sees it.
- Caddy then forwards to `wp_n3:3053` etc. inside the Docker
  bridge.  Those upstreams are not exposed on the host; only Caddy
  can reach them.  The upstream's HTTP peer for these forwarded
  requests is Caddy's container IP, which is in the Docker
  bridge's RFC1918 range — so the peer-network gate succeeds.
- For the routes where Caddy genuinely needs to forward
  `internal_transport` claims (the `/ws` path under
  `@trusted_internal_ws`), Caddy injects the necessary
  `X-Web-Prolog-User` and `X-Web-Prolog-Capabilities` values and
  also sets `X-Web-Prolog-Internal-Proxy: true`.  This snippet is
  gated by `remote_ip private_ranges`, so it does *not* fire for
  internet-origin requests.

### 4.3 The deployment-dependent assumption

The above story collapses if any of the following stops being
true:

- Caddy ceases to strip inbound `X-Web-Prolog-*` headers (the
  `common_proxy_headers` snippet is dropped or edited).
- `wp_n3:3053` (or any other upstream) is exposed on the host
  outside the Docker bridge (e.g. `-p 3053:3053` in
  `compose.yaml`).
- The node is redeployed to a multi-tenant subnet where other
  RFC1918 hosts are not trusted.

For a port that needs stronger guarantees, §9.2 sketches an
HMAC-signed `X-Web-Prolog-Auth` token approach that would make the
network check defence-in-depth rather than the sole gate.

---

## 5. WebSocket Origin policy

CORS does not apply to WebSocket handshakes; the server is the
only party that can restrict which web pages may open a WS to its
endpoint.  Without an Origin check, any page on the web can drive
the actor surface of `n3`/`n4` from a victim's browser.

The current policy is enforced by `ws_require_allowed_origin/1`
([node_ws.pl:165–230](node_ws.pl:165)), called from `ws_handler/1`
before the principal is resolved:

- **No Origin header** → accept.  Native (non-browser) clients,
  including the inter-node WebSocket reader in
  [actor.pl](actor.pl), do not set Origin; locking them out is not
  the intent.
- **Origin equals the request's Host** → accept (same-origin).
  This is the typical browser case where a portal hosted at
  `n3.elfenbenstornet.se` opens `wss://n3.elfenbenstornet.se/ws`.
- **Origin appears in the `ws_allowed_origins` startup option** →
  accept.  Use this to allow specific cross-origin browser
  clients.
- **Otherwise** → throw
  `permission_error(open, websocket_origin, Origin)`.

The unit tests in [tests/node_tests.pl](tests/node_tests.pl) (see
the `ws_origin_*` test set) pin the four acceptance cases plus the
rejection.

---

## 6. Per-WebSocket-connection anonymous principal

With a single shared `anonymous` principal, every unauthenticated
browser visitor to `n3`/`n4` collapses into one identity.  This
breaks per-principal limits (`max_ws_actors_per_principal`,
`max_sessions_per_principal`), makes audit log rows
uninformative, and removes any ability to rate-shape one client
without affecting all of them — which is incompatible with the
*invisibility* and *containment* mechanisms from §4.6 of the book.

`n3` and `n4` set the runtime value `anon_per_ws_connection: true`
([Deployment/start_n3.pl:64](Deployment/start_n3.pl:64),
[Deployment/start_n4.pl:64](Deployment/start_n4.pl:64)).  With
this enabled, `ws_principal/2`
([node_auth.pl:96–145](node_auth.pl:96)) replaces the shared
`anonymous` with a fresh `anon:<64-bit-hex>` principal at
handshake time, carrying the same open-mode capabilities.

Properties of the per-connection id:

- Server-generated; never disclosed to other clients.
- Bound to the WebSocket connection; meaningless outside it.
- Not cryptographic; only collision-resistance and
  forge-resistance-by-non-disclosure matter.
- Restores per-principal limits as per-tab limits in browser
  practice (each browser tab opens its own WS).

This is intentionally a minimal MVP.  It is *not* an
authentication mechanism — anonymous visitors are still
anonymous, just individually so.  See §9.3 for the path to actual
authenticated accounts.

---

## 7. Container and process isolation

The Prolog nodes run inside Docker containers with restricted
capabilities:

- **Read-only root filesystem** inside the container; `/tmp` is
  the only writable area.  See
  [Deployment/compose.yaml](Deployment/compose.yaml).
- **Dropped Linux capabilities** (`cap_drop: ALL`).
- **No raw network access** beyond the per-container loopback and
  the Docker bridge that Caddy uses.
- **Sandbox-blacklist mode** on all four nodes (`sandbox(blacklist)`),
  which disables file I/O, OS access, and similar predicate
  families at the language level.  See
  [docs/policy/SANDBOX_AND_HARDENING.md](docs/policy/SANDBOX_AND_HARDENING.md)
  and
  [docs/policy/BLACKLIST_SANDBOX_NOTES.md](docs/policy/BLACKLIST_SANDBOX_NOTES.md).
- **Resource caps** per node: `max_inflight_calls`,
  `max_sessions_per_principal`, `max_ws_actors_per_principal`,
  `max_term_text_bytes`, `max_load_text_bytes`, and rate-limit
  windows for call requests, session spawns, and WS commands.

Even if the Prolog-level sandbox were to leak a single dangerous
predicate, the host filesystem and network are bounded by the
container's `cap_drop: ALL` and read-only mount.  This is the
defence-in-depth layer §4.7.5 of the book refers to as "host
isolation."

---

## 8. Audit log

Each node retains a 24-hour ring buffer of activity events
(`recent_events` in `/admin/runtime`).  Events include:

- Every request: route, action, transport (HTTP or WS), principal,
  peer IP, user-agent, duration, status, optional summary.
- Every actor lifecycle event: `activity_start` and
  `activity_end` per ws_actor, with `started_at`/`ended_at` and
  termination reason.
- Failures: `remote_exit_failed` (cross-node kill loss),
  `spawn_error`, sandbox/profile violations.

The audit log is local to each node's `/admin/runtime` view and is
only available to the local `admin` surface (loopback or admin
principal).  It is not pushed to an external SIEM in the
demonstrator setup; that is a deployment-layer concern.

With the per-WS-connection anonymous principal (§6), each entry's
`principal` field now carries a distinct `anon:<id>` for each
browser tab on `n3`/`n4`, making it possible to trace one tab's
activity through the buffer.

---

## 9. Known limitations

This is a demonstrator.  Each item below is a knowing trade-off,
not an unidentified bug.

### 9.1 `auth(open)` on actor-profile nodes

`n3` and `n4` allow unauthenticated visitors to spawn actors,
issue toplevel calls, send messages to registered services, and
exit actors they own.  This is intentional for a demonstrator
portal — the alternative would require a login flow that nobody
wants to set up for a visitor experience.

The per-WS-connection anon principal (§6) and the Origin check
(§5) together limit the practical impact of this choice:

- A random attacker page cannot drive a victim browser's WS
  because Origin is rejected.
- Per-tab limits cap the damage one bad visitor can do without
  affecting others.
- Sandbox-blacklist mode caps what any visitor's code can express.

For a production deployment with a user base, §9.3 sketches the
authenticated-accounts upgrade path.

### 9.2 Cross-node auth is network-trust based

Section 4 explains the current `internal_transport` model: the
trust boundary is the peer's network position, not a cryptographic
signature.  This is appropriate for a single-host Docker compose
deployment where all containers are on a trusted bridge.

For a multi-host cluster (different physical machines, shared
LAN), an HMAC-signed token would be appropriate:

1. The cluster operator sets a `node_secret(Secret)` startup
   option on every node, where `Secret` is a high-entropy shared
   string.
2. The outbound `actor.pl` cross-node WebSocket handshake adds
   `X-Web-Prolog-Auth: <hmac-sha256(secret, nonce + principal + capabilities)>`.
3. The receiving node validates the HMAC before granting
   `internal_transport`.

This is a feature, not a defect — the demonstrator does not need
it, and adding it would impose configuration burden on the simple
local case.

### 9.3 No authenticated user accounts

The demonstrator has no concept of "user X logs in and gets per-
user capabilities."  `principal_policy/2` supports it — a
principal id can be mapped to a capability set — but no user-facing
auth UX exists.

For a production deployment with named accounts:

1. The reverse proxy validates a bearer token (JWT, OAuth, or
   similar) and sets `X-Web-Prolog-User: user:<canonical-id>` and
   `X-Web-Prolog-Capabilities: <list>` accordingly.
2. The node's startup config maps each principal id to its
   capabilities via `principal(PrincipalId, Capabilities)` or via
   `principal_policy/2`.
3. `anon_per_ws_connection` continues to apply for unauthenticated
   browser sessions; authenticated ones get their real id.

Per-principal limits, audit rows, and capability checks then bind
to the real user id; the rest of the security architecture is
unchanged.

### 9.4 No mutual TLS or client certificates

The connection is HTTPS but the client is not verified.  Adding
mTLS at Caddy is straightforward but unnecessary for a public
demonstrator.

### 9.5 No DoS protection beyond rate limits

The per-principal rate limits and resource caps are enforced
per-node, in-process.  They protect against a single noisy client
exhausting one node's resources, not against a coordinated DDoS at
the network layer.  A real deployment would put the public nodes
behind Cloudflare, a load balancer with rate limiting, or
similar.

### 9.6 In-process integration test caveat

The cross-node integration tests
([tests/cross_node_lifecycle_tests.plt](tests/cross_node_lifecycle_tests.plt))
run two nodes in the same Prolog process.  They share controller
state in [node_controller.pl](node_controller.pl) — so bugs that
only manifest with truly node-local state are not caught.  An
OS-level multi-process test suite would be the right complement
for a production system.

### 9.7 The `admin` HTTP route trusts loopback unconditionally

`require_admin_access/1` ([node_auth.pl:170–179](node_auth.pl:170))
treats any request from a loopback peer as admin under
`auth(open)`.  This is intentional for the operator workflow:
`curl http://127.0.0.1:3053/admin/runtime` on the host machine
should just work.  It does mean that anyone with shell access to
the host can administer the node — which is consistent with the
host-trust model in §1 ("we do not defend against a compromise of
the host OS").

---

## 10. What an operator should monitor

For the deployed demonstrator, the following signals are worth
watching:

| Signal | Where | Significance |
|---|---|---|
| `recent_errors > 0` in `/admin/runtime` | per node | something hit the sandbox or profile gate; investigate by `event_type: "remote_exit_failed"`, sandbox errors, etc. |
| `remote_exit_failed` events | per node `recent_events` | cross-node kill loss; either the remote is unreachable, or the cluster has a bug |
| Rapid growth in `ws_actors` array | per node `/admin/runtime` | a stuck or leaky session; combined with the per-connection anon principal, look for one `anon:<id>` accumulating actors |
| Connection bursts from a single peer | container/proxy logs | a possible scanner or DoS; rate limits should be working but the log confirms it |
| Unfamiliar `Origin` values in WS handshake rejections | container stdout (`permission_error(open, websocket_origin, …)`) | an attacker page or a misconfigured legitimate client |

---

## 11. What changes for "not just a demonstrator"

If this codebase ever became the basis for a non-demonstrator
deployment, the work list would be roughly:

1. **Authenticated accounts** (§9.3).  Bearer-token auth at the
   proxy, principal policies at the node, per-user audit.
2. **HMAC cross-node trust** (§9.2).  Per-cluster shared secret;
   network-trust becomes defence in depth rather than the
   primary gate.
3. **External audit log shipping**.  Push the `recent_events` ring
   to a log aggregator (Loki / Elasticsearch / similar) with a
   longer retention.
4. **DDoS protection** at the edge (§9.5).
5. **Profile-level mTLS** between nodes for full end-to-end
   identity verification.
6. **OS-level multi-process integration tests** (§9.6).
7. **Periodic external penetration testing**.  The current
   defences are reasoned about and tested; they have not been
   adversarially probed.

None of these are needed for the demonstrator's intended audience.
They are listed here so that a future maintainer can find the gap
analysis already done.
