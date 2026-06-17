# Turn-key Node Requirements

Goal: a **pack anyone can install and run as a production Web Prolog node
on the open Web** — secure by default, administrable day-to-day without
editing Prolog source, and resilient to hostile traffic (untrusted code
execution is the product, not an edge case).

This is a gap analysis, not a wish list. Each item is marked against what
the fork has **today**:

- ✅ present
- 🟡 partial — exists but incomplete for turn-key/open-web use
- ❌ missing

**Bold** items are treated as non-negotiable for an open-web turn-key node.
The administration sections (2–5) are the focus.

The node already has an unusually strong *policy core*: auth modes,
principals + capabilities, the profile / route / language matrix
(`PROFILE_MATRIX.md`), whitelist/blacklist sandboxing with a
builtin-family matrix, a deep per-principal limit set, a live runtime
dashboard, the reclaim tool, the JSONL interaction log, the secret
viewer, and the `/ws` origin (CSWSH) check. **The turn-key gap is mostly
operations** — deployment, machine-readable observability, lifecycle, and
headless administration.

---

## 1. Turn-key bootstrap & deployment

- ✅ **One-command deploy bundle** — `Deployment/` carries a Dockerfile
  (pinned `swipl:10.0.2`, non-root, build-time `WP_CHECK` gate, container
  HEALTHCHECK), a `compose.yaml` (node + Caddy, node not host-published),
  a systemd unit (hardened sandbox + drain-aware `TimeoutStopSec`), and a
  root `.dockerignore`. Verified by an actual `docker build` + run: image
  builds, container reports **healthy**, and `/healthz /readyz /version
  /metrics /call` all work through a remapped published port.
- ✅ **TLS / ACME** — the bundled Caddy reverse proxy obtains and renews a
  Let's Encrypt certificate for `SITE_ADDRESS`, terminates TLS, sets HSTS
  + the usual security headers, and proxies WebSocket with no idle
  timeout. `compose.yaml` config validated.
- ✅ **Secure-by-default first run** — `start_node.pl` defaults to
  `auth=private` + `sandbox=whitelist` and **refuses to start world-open**
  (`auth=open`) without `WP_ACK_PUBLIC=yes` — which is deliberately
  env-only, so opening a node to the world is always a conscious act even
  when the config file says `auth = open`. *(Remaining: auto-generate +
  print the admin/viewer tokens on first run.)*
- ✅ **Config validation / dry-run** — `WP_CHECK=1` validates the resolved
  configuration (file + env), prints it, and exits without binding a port;
  bad enums/integers/config syntax fail with clear messages.
- ✅ **Single declarative config file** as the source of truth — a
  `web-prolog.conf` of `key = Value.` terms (`WP_CONFIG`, else
  `./web-prolog.conf`), with every `WP_*` env var overriding the matching
  key (env > file > default). See `Deployment/web-prolog.conf.example`.
- ✅ **Health & readiness endpoints** — `/healthz` (liveness) and
  `/readyz` (200 ready / 503 draining), both unauthenticated and
  side-effect-free, for orchestrators and uptime monitors. Verified live
  in the container, including through a remapped port.
- ✅ **Version/build endpoint** (`/version`) — pack version, SWI version,
  wire-protocol version, git SHA. Verified live.

## 2. Administration — identity & access

- ✅ Auth modes (open / dev / private), principals with capabilities,
  per-principal policies.
- 🟡 **Principal lifecycle without restart** — create / disable / delete /
  re-scope principals at runtime. (An `/admin/principals` page exists;
  confirm full CRUD vs read-mostly.)
- ✅ **API-token lifecycle** — a first-class bearer-token mechanism
  (`node_tokens`). `Authorization: Bearer wp_<id>_<secret>` resolves to a
  principal + capability scope, *proven* against a salted SHA-256 stored
  hash (CSPRNG id + secret; the secret is shown once and never stored),
  with expiry, revocation, and audit timestamps. Issue / list / revoke
  via `/admin/tokens` (GET/POST/DELETE) and a **Tokens** tab in the admin
  panel. Persisted to a configurable store (`WP_TOKENS_FILE`, mounted on
  the deploy bundle's `wp_state` volume) so tokens survive restarts;
  unset ⇒ in-memory only. Tried before the proxy-trusted
  `X-Web-Prolog-User` header; off by default. Rotation = issue-new then
  revoke-old. *Remaining (minor):* scoped expiry presets / a one-call
  rotate convenience.
- 🟡 **Admin role separation** — owner vs admin vs read-only *observer*
  (watch the dashboard, change nothing). (Owner/admin exist; a pure
  observer role is missing.)
- ❌ **Admin credential rotation** — rotate admin and viewer tokens without
  downtime.
- ✅ **Config-change audit trail** — every admin mutation (config,
  principals, tokens, maintenance, reclaim) is recorded via
  `log_admin_event`/`log_admin_audit` with who (the admin principal +
  client meta), what (action + fields — never a token secret), and when,
  both in the live in-memory log and **durably** in the append-only
  interaction log (event names prefixed `admin:`), so it survives
  restarts and shows up in the secret viewer. *Possible hardening:* a
  dedicated audit file separate from the traffic log (so it is not
  rotated by volume), and an `/admin/audit` filtered view.

## 3. Administration — policy & execution control

- ✅ Profile selection (relation/isobase/isotope/actor), sandbox mode,
  builtin-family matrix, `load_text`/`load_uri` size caps + origin
  allowlist, per-call/session/actor timeouts.
- 🟡 **Runtime-editable policy** — change profile, sandbox mode, families,
  limits live. (`/admin/config` does some of this; map exactly which
  settings are hot vs restart-only and close the gaps.)
- 🟡 **Per-actor resource ceilings beyond wall-clock** — *done:* a
  per-`/call` inference ceiling (`max_call_inferences`) stops
  fast-but-infinite goals, and a per-actor stack ceiling
  (`max_actor_stack_bytes`) bounds a single goal's memory; both default
  to unlimited in the library and to bounded values in the deploy
  bundle. *Remaining:* table-space and output-size caps (lower-risk
  vectors).
- ❌ **Kill switch / panic mode** — one toggle that drops the node to
  read-only or refuses new work, for incident response.
- 🟡 **Shared-DB management** — load / replace / inspect / clear the shared
  database at runtime without a restart.
- 🟡 **Per-principal policy tiers** — distinct profiles/limits for
  anonymous vs authenticated vs trusted principals. (Capabilities give
  some of this; a clean per-tier policy table would make it turn-key.)

## 4. Administration — observability

- ✅ Structured JSONL interaction log; the live `/admin/runtime` dashboard
  (active actors, WS connections, activity counters); the secret viewer
  with owner/agent/public filtering.
- ✅ **Machine-readable metrics** (`/metrics`, Prometheus-style) — an
  unauthenticated, aggregate-only `/metrics` endpoint exposes build info,
  uptime, process stats, the live activity gauges (active sessions / WS
  connections / actors / principals, retained events, recent errors), the
  configured limits incl. the resource ceilings, and **cumulative
  counters** (`node_metrics_counters`): `web_prolog_requests_total`,
  `web_prolog_errors_total`, and `web_prolog_rejections_total{reason=...}`
  broken down by auth / profile / sandbox / rate_limit / ip — incremented
  at the policy choke points (`execute_and_respond_logged` and the IP
  gate). Per-node, reset on (re)start (the normal counter reset).
- 🟡 **Log rotation & retention** — *done:* size-based rotation of the
  durable JSONL interaction log (`max_interaction_log_bytes`) keeping a
  bounded number of backups (`max_interaction_log_backups`); off in the
  library, 50 MiB / 5 backups in the deploy bundle. *Remaining:*
  age-based purge and retention of the rotated files.
- ❌ **Alerting hooks** — webhook on threshold breach, repeated auth
  failures, resource saturation, or runaway reaping.
- ❌ **Per-principal usage accounting** — durable counters for quotas,
  abuse triage, or billing.
- 🟡 **Slow-query / heavy-goal log** — surface the goals consuming the most
  time/inferences. (Trace plumbing exists for statecharts/sessions; a
  goal-cost log is the admin-useful generalization.)

## 5. Administration — lifecycle & maintenance

- ✅ **Graceful drain & shutdown** — `start_node.pl` traps SIGTERM/SIGINT
  (so `docker stop` / `systemctl stop`): flip to maintenance, hold a grace
  period (`WP_DRAIN_GRACE_SECONDS`) while `/readyz` is 503 and in-flight
  finishes, stop the server, exit. Zero-downtime upgrades.
- ✅ **Maintenance mode** — a per-node drain flag toggled via the admin API
  (`POST /admin/maintenance {"enabled":Bool}`) and a button in the admin
  panel's Runtime section: `/readyz`⇒503 and the execution entry points
  refuse new work, while `/healthz` and in-flight work are unaffected. The
  panel also shows the resource ceilings (read-only) and a build/protocol
  footer.
- 🟡 **Low-downtime config reload** — apply config changes without dropping
  connections. (Partial via `/admin/config`; must cover the full config
  surface.)
- ❌ **Backup & restore** — snapshot/restore of config + principals +
  shared DB + logs.
- ❌ **Hot upgrade of resident services / shared DB** — swap node-owned
  code without a full restart.
- 🟡 **Runaway reaping + notification** — the reclaim tool exists; pair it
  with an alert and an audit entry so reaping is visible, not silent.

## 6. Abuse resistance & resilience (open-web realities)

- ✅ Per-principal rate limits, max-inflight, frame/command/window caps,
  CSWSH origin check.
- 🟡 **IP / CIDR controls** — *done:* an IP/CIDR **block/allow list**
  (`node_ip_policy`, `WP_IP_BLOCKLIST` / `WP_IP_ALLOWLIST`) enforced at the
  execution edge (`/call`, `/toplevel_spawn`, `/ws` ⇒ 403), off by
  default. The client IP is resolved spoof-resistantly — `X-Forwarded-For`
  is trusted only from a private/loopback proxy peer, taking the rightmost
  entry — so it is correct behind Caddy and unforgeable by clients.
  Plus **per-IP anonymous identity** (`WP_ANON_PER_IP`): individualises the
  shared anonymous principal per client IP (`anon:<ip>`, the resolved
  spoof-resistant IP), so the existing per-principal rate / session / actor
  limits and the audit log all become per-IP instead of one bucket for the
  whole internet — the /call analogue of `anon_per_ws_connection`. Off by
  default. Plus **temporary auto-bans** (`WP_AUTO_BAN_THRESHOLD` /
  `_WINDOW_SECONDS` / `_SECONDS`): an IP that trips the /call rate limit
  too often within the window is auto-blocklisted for a TTL and then
  denied via the same `ip_access_denied` path; allowlisted IPs are exempt.
  Off by default. (Only rate-limit offenses count — not auth denials,
  which include legitimate refusals on a private node.)
- 🟡 **Global concurrency cap + backpressure** — *done:* a global live-actor
  cap (`max_actors`) rejects spawns past the limit with
  `resource_error(actors)` rather than degrading; combined with the
  per-actor stack ceiling this bounds total node memory at
  `max_actors × max_actor_stack_bytes`. *Remaining:* surfacing the
  rejection as an HTTP `503` at the request edge (today it is an error
  answer), and a separate inbound-connection cap.
- 🟡 **Connection hygiene** — slow-loris / header-flood protection; today
  delegated to the (now undocumented) reverse proxy.
- ❌ **Supervised crash recovery** — restart-on-crash with optional state
  persistence (systemd covers the process; the in-node supervisor story
  for resident services should be explicit).

## 7. Federation (Web Prolog-specific — nodes call nodes)

- 🟡 **Inter-node trust** — the `internal_transport` header is gated to
  loopback/RFC1918 peers; on the open Web this needs **mTLS or signed node
  identity** between peers, not network-position trust.
- ❌ **Peer directory & per-peer policy** — which remote nodes may
  `spawn`/`rpc` here, with per-peer limits.
- 🟡 **Remote visibility in admin** — show remote actors/sessions and
  cross-node connections in the dashboard.

## 8. Trust, privacy & legal surface (running on the open Web)

- 🟡 **Data-retention policy & auto-purge** — tie to the (missing) log
  rotation; right-to-erasure for a principal's data.
- ❌ **Acceptable-use / abuse-contact surface** — an `/about` or
  `security.txt` with ToS and an abuse address; expected for anything
  public.
- ✅ **Traffic transparency** — the owner/agent/public log distinction
  already models "what gets recorded"; surface it to users.

## 9. Operator experience / turn-key polish

- 🟡 **Headless admin** — the admin surface is already an HTTP API the web
  panels call, so it is scriptable with `curl` + admin auth (config,
  principals, runtime, reclaim, and now `POST /admin/maintenance` for
  drain). *Remaining:* a packaged `wp-admin` CLI wrapper and token
  rotation.
- ✅ **`/admin/doctor` self-diagnostics** — an admin-gated GET
  (`node_doctor`) returns a green/amber/red review: sandbox mode, auth
  boundary, resource ceilings, TLS (via the request's
  X-Forwarded-Proto), token-store durability, interaction/audit-log
  retention, and maintenance state. Each check is ok/warn/fail with a
  one-line message; the overall status is the worst check.
- 🟡 **Deployment recipes for the common shapes** — *done:* a **single-node
  SSO recipe** (`Deployment/compose.sso.yaml` + `Caddyfile.sso` +
  `.env.sso.example` + `Deployment/SSO.md`): oauth2-proxy in front does
  OAuth/OIDC login and hands the node a verified `X-Web-Prolog-User`
  (which the node trusts only from the private-network proxy), so
  registration = the provider allowlist and no IdP code lives in the
  node. The **"registered" capability tier**
  (`WP_AUTHENTICATED_DEFAULT_CAPS`) makes SSO users usable without
  per-user principal entries: an authenticated principal with no policy
  entry gets the tier's capabilities (never `admin`/`internal_transport`)
  while keeping its own id for audit/rate-limiting. *Remaining:* "public
  sandbox playground" and "federated research node" recipes.
- 🟡 **Operator documentation** — install guide, **secure-config
  checklist**, threat model, incident runbook. (Architecture / profile /
  security docs exist; the operator-facing runbook does not.)

---

## The short version

Most of what is **missing is operational, not semantic**. The language and
policy engine are largely there; what a turn-key open-web node still needs
is:

> **deploy bundle + TLS · `/metrics` + `/healthz` · log rotation · graceful
> drain + maintenance mode · headless admin API · IP-level abuse controls ·
> per-actor inference/memory ceilings · federation trust that does not rely
> on network position** — plus a secure-by-default first run.

Those turn "a node you can run" into "a node anyone can safely run."

## Suggested ordering (maps onto plan Phase 8)

A pragmatic path to a defensible public v1, roughly in dependency order:

1. **Deploy bundle + TLS + `/healthz` + `/version`** — nothing else is
   reachable safely without this.
2. **Secure-by-default first run + config validation + single config file.**
3. **Per-actor inference/memory ceilings + global concurrency cap.** Close
   the resource-exhaustion gap that wall-clock timeouts leave open.
4. **`/metrics` + log rotation + retention.** Make the node observable and
   bounded on disk.
5. **Graceful drain + maintenance mode + headless admin API.** Make it
   operable without downtime or a browser.
6. **IP/CIDR controls + abuse-contact surface + config-change audit.**
7. **Federation trust (mTLS/signed identity) + peer policy.** The
   open-Web-specific item; can trail a single-node v1.

Items 1–5 are the realistic bar for a **public v1**; 6–7 harden it for
multi-tenant and federated use.
