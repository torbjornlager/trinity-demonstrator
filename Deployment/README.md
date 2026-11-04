# Deployment Bundle

For a static UI on another origin, see [CDN remote authentication](../docs/CDN_REMOTE_AUTH.md).
It describes the tested CORS/session policy and the production qualification still
required; the existing live proxy/node configuration is unchanged.

Browser runtime assets now come from the exact `swi-wasm-node` package pin as well
as the native `swi-prolog-node` dependency. Container builds fetch both repositories;
the existing BuildKit `github_token` secret must have read access to both private
repositories. Host `.trinity/` state is excluded and rebuilt inside the image.


## Container image pins

All external `FROM` images, Compose `image:` entries, Dockerfile frontends, and
the N5 smoke test's helper images use `tag@sha256:…` references. These pin the
multi-platform image index, supporting both ARM64 development and AMD64 CI.
The `trealla_runtime` base is a Compose named build context produced from the
source pins below.

To refresh an image, resolve the intended tag with
`docker buildx imagetools inspect IMAGE:TAG` and use its top-level `Digest:`
in every matching reference. Confirm the index includes the required platforms,
then rebuild the affected images and run the deployment smoke tests. Changing a
tag alone does not update a digest-pinned image.

## Native dependency in container builds

Both SWI Dockerfiles fetch the exact commit from `dependencies/swi-prolog-node.json`,
validate it, and assemble the browser payloads before checking node startup.
Python 3 and Git remain available in the image for startup validation. There is
no in-tree native implementation or legacy build mode. SWI-Prolog is pinned to
10.1.19, which includes the required protected-wait fix.
Setup and startup also require the browser package's schema provenance to match
the native repository and revision, and its schema bytes to match the native
schema hash. Update both dependency pins together when moving the native pin.

`start_node.pl` resolves settings as environment > config file > default,
including `ack_public`, `owner`, shared-database paths and discovery seed files.
`WP_PUBLIC_URL` must be an absolute HTTP(S) origin, for example
`https://node.example.com:8443` (an optional trailing slash is accepted).
Credentials, paths, queries and fragments are rejected because the advertised
settings represent an origin. `WP_CHECK=1` validates the same URL as startup
without changing the public HTTP settings or binding a port.
IPv6 literals retain their brackets in advertised URLs, for example
`https://[::1]:8443`. Both SWI and Trealla container health checks use `WP_PORT`.

For a private dependency, provide a read token as a BuildKit secret:

```bash
docker build --secret id=github_token,src=/path/to/read-token \
  -f Deployment/Dockerfile -t web-prolog-node .
```

For Compose builds, supply the same `github_token` build secret through an
owner-local Compose override, or prebuild the tagged images and start without
`--build`. Credentials are never build arguments or persisted Git configuration.
The existing Actions `SWI_NODE_READ_TOKEN` secret serves the same read-access role
in CI. Missing dependency access fails the build rather than loading a fallback.


This folder is the practical deployment for the public `elfenbenstornet.se`
Web Prolog nodes: a **discovery hub**, four public demo nodes, one
**SSO-gated production node**, and a local-only admin node. It is
**self-contained** — every container builds from this repo (no sibling
`web-prolog` checkout is needed).

Target hostnames:

- `n0.elfenbenstornet.se`: public **discovery hub** — a `profile(relation)`
  node that probes the others and publishes the live register; serves the
  directory at `/discovery-hub`. See [Discovery hub (n0)](#discovery-hub-n0).
- `n1.elfenbenstornet.se`: public, `profile(isobase)`, most conservative
- `n2.elfenbenstornet.se`: public, `profile(isotope)`
- `n3.elfenbenstornet.se`: public ACTOR demo, `profile(actor)`
- `n4.elfenbenstornet.se`: second public ACTOR demo, `profile(actor)`
- `n5.elfenbenstornet.se`: the layered production node, `profile(actor)`,
  `auth(private)`, behind GitHub SSO. See [SSO node (n5)](#sso-node-n5).
- `admin.elfenbenstornet.se`: reserved admin hostname, not publicly routed

The shape is:

```text
Internet
  -> DNS for n0 / n1 / n2 / n3 / n4 / n5
  -> router forwards 80 and 443 to the host
  -> Caddy container
  -> private Docker network (deployment_wp_net)
  -> wp_n1 / wp_n2 / wp_n3 / wp_n4 / wp_admin   (Dockerfile, start_nX.pl)
  -> wp_n5 + oauth2_n5                          (Dockerfile.node, GitHub SSO)
  -> n0 discovery hub                           (Dockerfile.node, compose.hub-attach.yaml)
```

Each node is also bound on the host loopback interface for local-only admin
inspection without exposing `/admin` publicly:

- `wp_n1` -> `127.0.0.1:3051`
- `wp_n2` -> `127.0.0.1:3052`
- `wp_n3` -> `127.0.0.1:3053`
- `wp_admin` -> `127.0.0.1:3054`
- `wp_n4` -> `127.0.0.1:3055`

By default, the node containers use the examples copied into the image at build time. If you edit files under [`examples/`](../examples), rebuild the node containers to make those changes visible in the Examples drawer:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

An optional override file, [`compose.examples-live.yaml`](compose.examples-live.yaml), bind-mounts `examples/` read-only from the host so example edits show up without rebuilding. Use it only if Docker Desktop file sharing for the repo root is working:

```bash
docker compose -f compose.yaml -f compose.examples-live.yaml up -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

For day-2 operations and maintenance, see:

- public/redacted guide:
  [`ADMIN-DEPLOYMENT-MANUAL.public.md`](../docs/ADMIN-DEPLOYMENT-MANUAL.public.md)
- focused content-edit workflow:
  [`EDITING_AND_DEPLOYING.md`](../docs/EDITING_AND_DEPLOYING.md)

If you keep a more detailed local operator manual with home-network specifics,
keep that one out of public git.

## Files

Images and orchestration:

- `Dockerfile`: image for `n1`–`n4` + `admin` (copies the repo, launched by
  the per-node `start_nX.pl` scripts below)
- `Dockerfile.node`: lean, env-driven image for `n5` and the `n0` hub —
  `ENTRYPOINT` is `start_node.pl`, configured entirely by `WP_*` env vars
- `compose.yaml`: the main stack — Caddy, `wp_n1`–`wp_n4`, `wp_admin`,
  `wp_n5`, and the `oauth2_n5` SSO sidecar
- `compose.hub-attach.yaml`: the `n0` discovery hub, joined to the main
  stack's `deployment_wp_net` so it can probe the peers internally
- `Caddyfile`: public routing and TLS termination
- `.env` / `.env.n5-sso.example`: stack config; the SSO secrets for `n5`

Node launchers / config:

- `start_n1.pl` … `start_n4.pl`, `start_admin.pl`: per-node launchers
- `start_node.pl`: the generic env-driven launcher (used by `n5` and `n0`)
- `discovery-seed.coexist.pl`: the `n0` hub's seed — probes `wp_n1`–`wp_n5`
  over the container network (see [Discovery hub (n0)](#discovery-hub-n0))
- `discovery-seed.elfenbenstornet.pl`: a public-URL seed variant

Shared databases:

- `shared_db_common.pl`: common shared database loaded by every deployment node
- `shared_db_actor_common.pl`: shared database loaded by ACTOR-profile nodes (`n3`, `n4`)
- `shared_db_n1.pl` … `shared_db_n5.pl`: per-node overlays for `n1`–`n5`
- `shared_db_admin.pl`: per-node overlay for `admin`
- `n5` loads the repo default `shared_db.pl` plus `shared_db_n5.pl`; `n0`
  serves `examples/services/discovery_directory.pl` as its shared database
- `provides/1` facts in these files are the owner-curated capability lists
  the hub harvests (surfaced via `/node_info`, not queryable relations)

## Before You Start

1. Install Docker Desktop on the host and confirm both commands work:

```bash
docker version
docker compose version
```

2. Reserve the host's LAN address in the router DHCP settings.

3. In DNS for `elfenbenstornet.se`, create `A` records for:

   - `n0.elfenbenstornet.se`
   - `n1.elfenbenstornet.se`
   - `n2.elfenbenstornet.se`
   - `n3.elfenbenstornet.se`
   - `n4.elfenbenstornet.se`
   - `n5.elfenbenstornet.se`

   Point them to your current public IPv4.

4. Do not publish `admin.elfenbenstornet.se` in public DNS yet.

5. Forward router ports `80` and `443` to the host.

6. For `n5`'s SSO, register a GitHub OAuth App with callback
   `https://n5.elfenbenstornet.se/oauth2/callback`, then put its client id /
   secret, a cookie secret, your sole GitHub login in
   `OAUTH2_PROXY_GITHUB_USERS`, and your verified GitHub email in
   `WP_N5_OWNER` in `.env` (see `.env.n5-sso.example`). Compose refuses to
   render the N5 services when either owner identity is missing.

## Start The Stack

From this folder, bring up the main stack (Caddy, `n1`–`n4`, `admin`,
`n5` + `oauth2_n5`):

```bash
cd Deployment
docker compose up --build -d
```

Then bring up the `n0` discovery hub, which attaches to the same network:

```bash
docker compose -f compose.hub-attach.yaml up -d --build
```

Check status:

```bash
docker compose ps
docker compose logs -f caddy wp_n1 wp_n2 wp_n3 wp_n4 wp_n5 wp_admin
```

## What Gets Exposed

`n1.elfenbenstornet.se`

- public
- `profile(isobase)`
- reduced portal is proxied
- intended portal surface is runtime-focused: Terminal and Logger
- proxied routes include:
  `/`, `/call`, `/manual`, `/node_info`, `/img*`, `/portal`
- overlay contents:
  `deployment_node(n1).`
- shared DB file:
  [`shared_db_n1.pl`](shared_db_n1.pl)
- local-only admin surface:
  `http://127.0.0.1:3051/admin`

`n2.elfenbenstornet.se`

- public
- `profile(isotope)`
- portal is proxied
- supports the richer semi-stateful portal UI
- proxied routes include `/call`, `/portal`, editor/tutorial/example assets,
  and the `/toplevel_*` session routes
- overlay contents:
  `deployment_node(n2).`, `mortal/1`, `ancestor/2`, `descendant/2`,
  `family_member/1`
- shared DB file:
  [`shared_db_n2.pl`](shared_db_n2.pl)
- local-only admin surface:
  `http://127.0.0.1:3052/admin`

`n3.elfenbenstornet.se`

- public
- `profile(actor)`
- `/call`, `/toplevel_*`, `/ws`, `/portal`, examples, statecharts,
  manual pages, and related assets are proxied
- overlay contents:
  `deployment_node(n3).` plus the `mortal/1` / `human/1` chain that calls n4
- actor-common contents (shared with n4):
  `service/2` entries for `counter`, `pubsub_service`, and `linda`, `echo_actor/0`,
  `count_actor/1`, and the native `ping_pong/0-1` and
  `ping_pong_benchmark/2` predicates
- shared DB file:
  [`shared_db_n3.pl`](shared_db_n3.pl)
- local-only admin surface:
  `http://127.0.0.1:3053/admin`

`n4.elfenbenstornet.se`

- public
- `profile(actor)`
- `/call`, `/toplevel_*`, `/ws`, `/portal`, examples, statecharts,
  manual pages, and related assets are proxied
- overlay contents:
  `deployment_node(n4).` plus `human(plato)` / `human(aristotle)`
- actor-common contents (shared with n3):
  `service/2` entries for `counter`, `pubsub_service`, and `linda`, `echo_actor/0`,
  `count_actor/1`, and the native `ping_pong/0-1` and
  `ping_pong_benchmark/2` predicates
- shared DB file:
  [`shared_db_n4.pl`](shared_db_n4.pl)
- local-only admin surface:
  `http://127.0.0.1:3055/admin`

`admin`

- not proxied publicly by Caddy
- available only on the host as:
  `http://127.0.0.1:3054/portal`
- local-only admin surface:
  `http://127.0.0.1:3054/admin`
- overlay contents:
  `deployment_node(admin).`, `deployment_public_node/1`
- shared DB file:
  [`shared_db_admin.pl`](shared_db_admin.pl)

If you want the canonical hostname locally, add this to your local
`/etc/hosts`:

```text
127.0.0.1 admin.elfenbenstornet.se
```

Then use:

```text
http://admin.elfenbenstornet.se:3054/portal
```

## Discovery hub (n0)

`n0.elfenbenstornet.se` is a `profile(relation)` node — clients can only
**query the published register** over `/call`; there is no `/ws` and no
arbitrary execution, so an outside client cannot create actors on it. It
runs the registry custodian internally: every 30 s it probes each node's
`/node_info`, derives up / unreachable / down status, and republishes a
generation-buffered read replica into its shared database. Discovery is
then a query (a RELATION node serves conjunctions of advertised relations):

```prolog
?- node_profile(N, actor), node_status(N, up), node_provides(N, 'human/1').
```

The browser directory at `https://n0.elfenbenstornet.se/discovery-hub`
renders the register live (status dots, a ~10 s poll, `provides`/`services`
chips) with a query builder that runs the composed goal on the hub.

n0 is its own compose file so it can join the main stack's network and
probe the peers internally (no NAT hairpin):

```bash
docker compose -f compose.hub-attach.yaml up -d --build
```

It builds from `Dockerfile.node` with `WP_DISCOVERY_HUB=yes`, seeding from
`discovery-seed.coexist.pl` (which probes `wp_n1:3051` … `wp_n5:3060`). Add
an `n0.elfenbenstornet.se` vhost to the `Caddyfile` — a plain
`reverse_proxy n0:3060`, mirroring the `n1` block plus `/discovery-hub` and
`/admin/tabler.min.css` in the path allowlist — so Caddy terminates TLS for it.

### Redeploying n0 after code changes

`n0` bakes `web/`, `prolog/`, and `examples/` into its image at build time
(`Dockerfile.node`), so edits to the hub UI (`web/discovery-hub.html`), the
registry service (`examples/services/discovery_hub.pl`,
`examples/services/discovery_directory.pl`), or the pinned node engine
(`dependencies/swi-prolog-node.json`) only go live after a **rebuild + recreate** — the
same command as first bring-up; `--build` is what matters:

```bash
docker compose -f compose.hub-attach.yaml up -d --build
```

The hub only ever shows what it harvests from each node's `/node_info`. So a
change that adds or alters a `/node_info` field (for example a new capability
flag the hub surfaces) also needs the **peer** nodes rebuilt before they
report it — until then the hub shows the old or absent value for them, while
n0 (which self-probes and was just rebuilt) shows the new one:

```bash
docker compose up --build -d        # rebuilds caddy, wp_n1..wp_n5, wp_admin
```

## Model example (n3)

The optional public model capability for example 21 runs on **n3**. Its
setup, resource bounds and focused deployment command are documented in
[MODEL_SERVICE.md](MODEL_SERVICE.md). It is disabled by default and uses
the Mac's native Ollama installation without adding a container.

## SSO node (n5)

`n5.elfenbenstornet.se` is the layered production node at `profile(actor)`,
`auth(private)`. The `oauth2_n5` sidecar authenticates each visitor against
GitHub; the n5 Caddy vhost runs `forward_auth` and injects the verified
identity as `X-Web-Prolog-User` (trusted only from the private proxy peer,
so a public client cannot spoof it). The mandatory GitHub-login allowlist
admits only the configured account. N5 grants capabilities only to the
mandatory `WP_N5_OWNER`; the authenticated-default tier is empty, so any
other identity is denied even if the outer SSO gate is accidentally widened.
Every application route, including `/examples/*` and `/statecharts/*`, is
behind SSO. It builds from `Dockerfile.node` (context `..`) and uses the repo
default `shared_db.pl` plus the deployment overlay `shared_db_n5.pl`.

Because those static routes are private, an N5 process cannot fetch a
node-relative `src_uri('/examples/...')` through its own public URL (the
server-side request has no browser SSO cookie). Load the example in the
editor and use `src_text(<editor>)`, as in the shared-database example.

## Optional Trealla N5

[`compose.trealla-n5.yaml`](compose.trealla-n5.yaml) replaces only N5's
execution backend with the native Trealla port. It is deliberately an
override: the normal `compose.yaml`, SWI N5 image, and normal Caddyfile remain
unchanged as the rollback configuration.

Both source revisions are fixed in
[`dependencies/trealla-port.json`](../dependencies/trealla-port.json): the Web
Prolog port at `2ebaeb9ca78e` and the Trealla v3.14.20 engine at `841f819c7dbd`.
The build fetches and verifies the full commit SHAs itself. It uses neither a
sibling working tree nor an upstream tag as a build selector. Change the
reviewed manifest to update these sources; `TREALLA_N5_VERSION` no longer selects
the engine.

The manifest validator rejects wrong revisions, modified or untracked sources,
and incomplete checkouts. To validate a local checkout or fetch clean pinned
sources explicitly:

```sh
python3 tools/pinned_trealla.py --port-root /path/to/trealla-port
python3 tools/fetch_trealla.py --port-destination .trinity/trealla-port \
  --engine-destination .trinity/trealla-engine
```

These commands never install a system engine or overwrite an existing checkout.
The Docker build checks the compiled engine version and records both revisions
in `/usr/share/doc/trealla/runtime-pins.json`. Only committed port files enter the
application image. Local ignored files and Git credentials are not packaged.

If the port repository requires authentication, pass the same `github_token`
BuildKit secret used for SWI dependencies:

```sh
docker build --secret id=github_token,src=/path/to/read-token \
  -f Deployment/Dockerfile.trealla -t web-prolog-trealla .
```

For Compose, add the secret to `wp_n5_runtime.build.secrets` in an owner-local
override. Credentials are never build arguments or saved Git configuration.

GitHub SSO remains the owner-only public boundary. Behind it, Trealla also
enforces `auth(private)` and accepts the verified owner identity only from
trusted Compose-network proxies. N3 supplies N5's static
demonstrator, tutorial, example, and image files; `/call`, `/ws`, discovery,
health, readiness, version, and metrics go to Trealla. N5 loads attributed
copies of N4's common and actor shared databases and advertises only the
currently supported `local_actor`, `toplevels`, and `distributed_actor`
tutorial sections; the UI hides the other tutorial sections rather than
presenting examples that this deployment has not qualified.

Add a random internal administration token to `Deployment/.env`:

```sh
printf 'WP_TREALLA_N5_ADMIN_TOKEN=%s\n' "$(openssl rand -hex 32)" >> Deployment/.env
```

Validate the merged configuration before changing the running services:

```sh
./tools/test-trealla-n5-override.sh

# Or configuration only:
docker compose -f Deployment/compose.yaml \
  -f Deployment/compose.trealla-n5.yaml \
  --env-file Deployment/.env config --quiet
```

Run the browser-protocol tutorial regressions (currently tutorial 19) with a
sibling `trinity-conformance` checkout:

```sh
./tools/test-trealla-n5-tutorials.sh
```

The test starts an isolated private N5 with an internal N3 example backend,
publishes N5 only on loopback, loads the tutorial source through `toplevel_spawn`, runs its example query, and
checks the promise results returned through the WebSocket protocol. It also
loads N5’s same-origin pause-and-resume statechart URL (including its encoded
space), exercises its events, and checks that unlisted origins stay denied.
N5 source fetches use the same N3 asset backend as its browser UI, without
passing through the public sign-in route. Override
the checkout with `TRINITY_CONFORMANCE_ROOT` or the loopback port with
`TREALLA_N5_TEST_PORT` when needed.

Cut over N5 and Caddy while leaving the other nodes alone:

```sh
docker compose -f Deployment/compose.yaml \
  -f Deployment/compose.trealla-n5.yaml \
  --env-file Deployment/.env \
  build wp_n5 caddy
docker compose -f Deployment/compose.yaml \
  -f Deployment/compose.trealla-n5.yaml \
  --env-file Deployment/.env \
  up -d --no-deps wp_n5 caddy
```

Check the backend and the SSO edge:

```sh
docker compose -f Deployment/compose.yaml \
  -f Deployment/compose.trealla-n5.yaml \
  --env-file Deployment/.env ps
docker compose -f Deployment/compose.yaml \
  -f Deployment/compose.trealla-n5.yaml \
  --env-file Deployment/.env logs --tail=100 wp_n5 caddy
curl -I https://n5.elfenbenstornet.se/demonstrator
```

An unauthenticated `curl` should still redirect to `/oauth2/sign_in`. After
signing in, `/version` should report `"web_prolog":"trealla-port"`,
`/node_info` should report `"profile":"actor"`, and the N5 demonstrator
should connect over WebSocket.

Rollback does not require a Git revert. Recreate the original services using
only the normal Compose file:

```sh
docker compose -f Deployment/compose.yaml \
  --env-file Deployment/.env \
  build wp_n5 caddy
docker compose -f Deployment/compose.yaml \
  --env-file Deployment/.env \
  up -d --no-deps --force-recreate wp_n5 caddy
```

The named `trealla_n5_state` volume is intentionally retained after rollback
so its audit log and token state remain recoverable. It can be removed later
only after confirming it is no longer needed.


## Public Trealla N5 pilot

The public pilot is opt-in through `compose.trealla-n5-public.yaml`, applied
**after** the ordinary and Trealla Compose files. N1–N4 retain their existing
configuration. The owner-only Trealla override and SSO Caddyfile remain the
rollback configuration.

The pilot keeps N5's 300-second active-query and idle limits, four concurrent
calls per principal, 16 WebSocket actors per principal, 128 actors overall,
and its 1 GiB/one-CPU container allowance. It retains blacklist sandboxing and
the existing exact source-origin allowlist so the qualified tutorials keep
working. It changes authentication to `open`, explicitly acknowledges public
execution, and strips visitor-supplied identity/capability headers at both
proxy layers. Administration paths are absent from the public allowlist.

A non-root, read-only Nginx admission service fronts the execution routes.
It allows **16 active requests/WebSockets per client IP and 32 overall**.
Rejected new work receives HTTP 429, `Retry-After: 5`, and a short busy message;
existing connections are not evicted. Caddy overwrites the client-IP header,
so internet visitors cannot choose their quota bucket. These are limits on
active requests and upgraded WebSockets, not idle HTTP keep-alive sockets.
The proxy is not published on the host. Static demonstrator assets still
come from N3 and do not consume N5 execution slots.

The owner-installed Trealla Linda service accepts at most **512 stored tuples
and 256 pending requests**, with at most **4096 logical units per tuple or
pattern** (term nodes plus atom/number text characters). Excess writes/waits
raise `linda_error(tuple_space_full)` or `linda_error(pending_requests_full)`;
oversized terms raise `linda_error(tuple_too_large)`. Reads, takes, probes,
FIFO ordering and cross-session sharing retain their protocol. No existing
data is evicted to make room. These bounds apply to the Trealla service;
the SWI services are unchanged. The service mailbox itself is not a bounded
queue; connection/actor quotas and container limits remain independent
protections against send floods.

Public audit/token state and logs use separate volumes, leaving private N5
state untouched. The public root URL serves a build-time concatenation of
exactly the five curated shared-DB source layers listed in the Trealla
override, so the panel's Shared DB link displays N5's sources. Rebuild the
admission image whenever those layers change.

Build with the existing private-dependency BuildKit secret setup, then deploy:

```sh
docker compose --env-file Deployment/.env \
  -f Deployment/compose.yaml -f Deployment/compose.trealla-n5.yaml \
  -f Deployment/compose.trealla-n5-public.yaml \
  up -d --build --no-deps --wait wp_n5 n5_admission caddy
```

To restore owner-only access, omit the public overlay and rebuild/recreate
`wp_n5` and `caddy` with `--no-deps`. This remounts the private state volume;
it does not delete public state. Stop the now-unused admission service using
the public Compose configuration. Do not run `down --volumes` on production.

### Public pilot validation

Use a disposable Compose project and
`compose.trealla-n5-public-test.yaml` to publish only the candidate admission
service on loopback port 13060. Build the candidate N5/admission images named
in that test overlay first (or set its image variables). Use `--no-build` to
start `wp_n3`, `wp_n5` and `n5_admission` in the disposable project. The test
N5 overrides owner/admin values with dummy credentials.

Run `tools/test_public_n5.py` against that disposable endpoint **only**: it
saturates connection quotas and fills then empties Linda. It verifies forged
identity stripping, sandbox denials, admin exclusion, the shared-DB source,
origin rejection, a query lasting more than ten seconds, survival of an
established query at capacity, quota reclamation, and Linda rejection/recovery.
Also run the conformance `actor-core-0.1` and `demonstrator-tutorials-0.1`
packs, `tools/test_linda_service.py`, and `tools/test_n5_sources.py` through
the candidate admission endpoint without authentication headers.
`tests/linda_public_bounds.pl` covers pending-reader admission and term sizing
on both SWI and Trealla. Normal tutorial/Linda cases should precede saturation.

During initial qualification, 32 open idle WebSockets used about 147 MiB in
the Trealla container; 512 simple stored tuples brought usage to about
198 MiB, and draining them left about 214 MiB. A combined 64-connection and
1024-tuple stress run approached the 1 GiB ceiling, so those larger trial
ceilings were rejected. These figures describe the tested workloads, not a
worst-case memory guarantee. Observe `docker stats`, node `/metrics`, and
admission rejection logs; retain the engine/container ceilings and isolation.

## Security Model

This bundle is a practical first step, not a complete hardening story.

Current protections:

- only Caddy publishes internet-reachable host ports
- the per-node localhost bindings stay limited to `127.0.0.1`
- the public nodes stay on a private Docker network
- filesystem is read-only inside the Prolog containers
- `/tmp` is the only writable area
- Linux capabilities are dropped
- `sandbox(blacklist)` is enabled on all nodes
- `admin` is local-only
- `n0` advertises the narrowest public surface (`profile(relation)`): query
  the register over `/call` only — no `/ws`, no arbitrary goal execution
- `n5` is `auth(private)` behind GitHub SSO; the forwarded identity header
  is trusted only from the private proxy peer, so a public client cannot
  assume an identity by setting it; the required GitHub-login allowlist,
  required owner email, empty authenticated-default tier, and SSO on all N5
  application routes make access owner-only

## Testing Node-Local Logs

The logging facility is per node. Traffic sent to `n3` is logged inside
`wp_n3`, not inside `wp_admin`.

Example flow:

1. Open `https://n3.elfenbenstornet.se/portal` and exercise the node.
2. Inspect the matching local admin surface on the host:
   `http://127.0.0.1:3053/admin`
3. If you want the raw JSON, open:
   `http://127.0.0.1:3053/admin/runtime`

Use the matching localhost port for the node you are testing:

- `n1` -> `127.0.0.1:3051`
- `n2` -> `127.0.0.1:3052`
- `n3` -> `127.0.0.1:3053`
- `n4` -> `127.0.0.1:3055`
- `admin` -> `127.0.0.1:3054`

Still important before public launch:

- keep `admin` off the public internet
- monitor logs after first exposure
- tighten router and host firewall posture
- expect `n3` and `n4` rate limits to apply to all anonymous users collectively

`src_uri` is now restricted in the application layer on these launchers:

- `n1`, `n2`, `n3`, and `n4` only allow source fetches from:
  `https://n1.elfenbenstornet.se`,
  `https://n2.elfenbenstornet.se`,
  `https://n3.elfenbenstornet.se`,
  `https://n4.elfenbenstornet.se`
- `admin` additionally allows its own hostname

When this allowlist is active, public `src_uri` rejects:

- bare local file paths
- `file://...` URIs
- arbitrary HTTP(S) origins outside the configured set

## Per-Node Shared Databases

Each deployment node now loads:

- the common base
  [`shared_db_common.pl`](shared_db_common.pl)
- plus its own overlay file:

- `n1` -> [`shared_db_n1.pl`](shared_db_n1.pl)
- `n2` -> [`shared_db_n2.pl`](shared_db_n2.pl)
- `n3` -> [`shared_db_n3.pl`](shared_db_n3.pl)
- `n4` -> [`shared_db_n4.pl`](shared_db_n4.pl)
- `n5` -> [`shared_db_n5.pl`](shared_db_n5.pl)
- `admin` -> [`shared_db_admin.pl`](shared_db_admin.pl)

The current deployment split is:

- `shared_db_common.pl`: family-tree relations
- `shared_db_actor_common.pl`: actor predicates (`echo_actor/0`,
  `count_actor/1`, and the native `ping_pong/0-1` and
  `ping_pong_benchmark/2` predicates) plus the public service directory;
  loaded only by `n3` and `n4`
- `shared_db_n1.pl`: `deployment_node(n1).` plus `human(plato)` / `human(aristotle)` (used by `n2`'s rpc chain)
- `shared_db_n2.pl`: isotope-friendly derived predicates over the common base
- `shared_db_n3.pl`: `deployment_node(n3).` plus the `mortal/1` / `human/1` chain that the distributed proof tree pulls through to `n4`
- `shared_db_n4.pl`: `deployment_node(n4).` plus `human(plato)` / `human(aristotle)` (used by `n3`'s distributed proof tree)
- `shared_db_n5.pl`: the n5-specific Statechart shared-database example facts
- `shared_db_admin.pl`: local deployment facts for admin use

This keeps the repo-level
[`shared_db.pl`](https://github.com/torbjornlager/swi-prolog-node/blob/main/prolog/web_prolog/shared_db.pl)
unchanged for non-deployment defaults.

After editing any of the shared DB files, rebuild the node containers:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_n5 wp_admin
```

`n3` and `n4` additionally start the node-resident `counter`, `pubsub_service`,
and `linda` actors at startup through
[`examples/services/node_resident_services.pl`](../examples/services/node_resident_services.pl).

## macOS Notes

- Docker Desktop on macOS uses a Linux VM internally.
- The node and admin inspection surfaces are kept local-only by binding their
  published ports to `127.0.0.1`.
- If Docker Desktop reports a mount-denied error for `../examples`, keep using
  the default `compose.yaml` and rebuild after example edits instead of the
  live-mount override.
- If your ISP uses CGNAT, direct router port forwarding may not work. In that
  case, keep the same Compose layout and replace the public edge with a tunnel
  solution.

### Linda on the ACTOR nodes

The owner supplies `linda_out/1`, `linda_in/1`, `linda_rd/1`, `linda_inp/1`, and
`linda_rdp/1`. The Examples drawer shows only their use. N3 and N4 load
`examples/services/linda_client.pl` into their shared databases and start the
owner service during bootstrap.

The Trealla N5 override adds an owner application image layer, built from this
repository on top of the manifest-pinned Trealla runtime. The `wp_n5_runtime` service
is a zero-replica build dependency; it does not run an additional node.
`Dockerfile.n5-linda` packages the shared client predicates and the same portable
owner tuple-space implementation used by N3 and N4. Its deployment adapter
starts Linda before the normal listener and retains maintenance draining.
No host source mounts or Trealla runtime changes are needed. Rebuild N5 with
the active override to deploy owner service changes.

Each node has an independent blackboard, subject to that node's existing access
policy; N5 remains owner-only behind SSO. See the
[owner setup and examples](../examples/services/README.md#linda-tuple-space-service).

### Portable text default

Native SWI and SWI-WASM read double-quoted Web Prolog literals as character
lists by default (`"abc"` is `[a,b,c]`). The pinned native package supplies this
default to every node, including private source, shared databases and
statecharts; Compose needs no experimental opt-in. Native implementation
modules and library interfaces retain their explicit SWI string conversions.
The pinned CI runner includes the TEXT tier to prevent a default-mode regression.
