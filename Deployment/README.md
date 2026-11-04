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
  `/`, `/call`, `/manual`, `/node_info`, `/img*`, `/demonstrator`
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
- proxied routes include `/call`, `/demonstrator`, editor/tutorial/example assets,
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
- `/call`, `/toplevel_*`, `/ws`, `/demonstrator`, examples, statecharts,
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
- `/call`, `/toplevel_*`, `/ws`, `/demonstrator`, examples, statecharts,
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
  `http://127.0.0.1:3054/demonstrator`
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
http://admin.elfenbenstornet.se:3054/demonstrator
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


## GNU Prolog N6

The HTTPS service at **https://n6.elfenbenstornet.se/demonstrator** now uses the
qualified public containment profile. Public queries need no owner login;
continuations belong to a signed, Secure, HttpOnly visitor cookie or an explicit
256-bit client conversation capability. The two identity namespaces are separate.
The original owner-only local and HTTPS configurations below remain available.

Apply the public profile after the local and host overlays:

```sh
docker compose --env-file Deployment/.env.n6 \
  -f Deployment/compose.gprolog-n6-local.yaml \
  -f Deployment/compose.gprolog-n6-host.yaml \
  -f Deployment/compose.gprolog-n6-public.yaml up -d wp_n6
```

The root launcher has only KILL, SETGID, SETUID and SYS_CHROOT capabilities.
It starts a private loopback controller, then permanently drops the presenter to
UID 10001. Every query group uses a distinct UID/GID, an immutable chroot containing
only the worker and its libraries, zero capabilities, no-new-privileges and a
seccomp filter. There is no procfs, writable directory, controller token, ambient
credential, inherited network socket, or direct IP/packet/netlink access in the
query environment. Source and public shared clauses arrive on read-only FDs.
The controller kills and reaps the entire group on completion, timeout, expiry,
cancellation or presenter exit, including orphaned grandchildren.

A peer-credential checked Unix broker permits only the exact HTTPS N1–N5 origins,
with public IPv4 addresses pinned at startup, certificate and hostname validation,
no proxy/redirect/credential forwarding, a 1 MiB UTF-8 response cap, and a two-second
absolute deadline. Egress limits are 16 active requests per query UID, 128 total,
and 240/query, 1200/client-address group, 4800/node requests per minute.

Query/page limits remain two seconds, 300 seconds idle, eight total slots, four
per visitor and six per client-address group. Sampled resident memory remains
256 MiB/query and 512 MiB/node. Each query UID has a hard limit of 32 processes or
threads; each process has 64 FDs, zero file/core output, and 2 GiB virtual address
space (GNU reserves about 1.1 GiB of sparse BSS). The container remains read-only,
with temporary storage mounted noexec, 1 GiB hard memory and 0.75 CPU; its process
ceiling is 384 to accommodate the broker and threaded RPCs.

This qualifies this deployment, not arbitrary GNU wrappers or a shared-kernel
security guarantee. Native allocation bursts can still exhaust and restart the
bounded N6 container before sampled limits intervene. There is no independent
security audit or host-kernel isolation claim. Shared database contents are public.

Reproduce the deployment-specific checks:

```sh
python3 -m unittest tests/test_n6_adapter.py tests/test_n6_egress.py
python3 tests/n6_egress_tls.py
python3 tools/test_n6_containment.py --image trinity-n6-host:latest
python3 tools/test_n6_public.py
```

See [the qualification record](../docs/verification/n6-public-containment-2026-11-04.json).
All public `/portal` and `/portal/` requests permanently redirect to
`/demonstrator`, preserving their query string. Current links use `/demonstrator`.

### Original owner-only localhost profile

N6 is a separate optional stack. It uses the manifest-pinned GNU Prolog port
at the revision recorded with engine 1.6.0 at `5976ac516c9f`, recorded in
`dependencies/gprolog-port.json`. The source checkouts and all runtime changes
remain upstream; this repository owns the deployment, presenter adapter and
consumer tests. The Linux build bootstraps GNU serially, runs its engine checks,
and builds the port with its existing strict Clang settings. It does not disable
compiler diagnostics or patch native source. Source/base-image pins and an image
`build-toolchain.json` record the selected implementation and actual compiler,
libcurl, libc and binary hashes; this is not a byte-for-byte reproducibility claim
for mutable Debian package repositories.

The local private profile runs at **http://localhost:3057/demonstrator**. Its dedicated
Discovery Hub is **http://localhost:3058/discovery-hub**. Both published ports
bind to `127.0.0.1`; no GNU listener port is published. This stack does not join,
rebuild or restart production N0–N5. Its private SWI asset service supplies the
same shared demonstrator and examples; GNU executes every N6 `/call` request.
The local page adds N6 beside N5 under Remote non-SWI nodes, puts Shared DB
beneath the selected button, uses the ISOBASE tutorials and disables unavailable
actor/session examples. Its explicit node catalog keeps the other buttons linked
to the public N1–N5 services. The public catalog also includes the HTTPS N6 service.

### Start and sign in

With Docker, Python and GitHub read access to the pinned source repositories:

```sh
python3 tools/start_n6.py --build
```

The script uses `TRINITY_BUILD_TOKEN` when supplied, otherwise the local GitHub
CLI credential, only as a BuildKit secret. It creates owner credentials once,
with mode 0600, in `.trinity/n6-access.txt`. The Compose environment file
`Deployment/.env.n6` contains only a salted PBKDF2 password hash. Both paths are
ignored by Git and excluded from build contexts. Existing credentials are never
silently replaced. Read the private file, open the local N6 page, and sign in as
`owner`. Do not paste credentials into URLs or saved shell commands.

A browser login creates an eight-hour, HttpOnly, SameSite=Strict, host-only
signed session cookie. Restarting the N6 presenter invalidates its sessions.
The form has a signed, purpose-separated anti-CSRF token and matching pre-login
cookie. Embedded browsers that submit `Origin: null` are supported only for a
login form with those proofs and a same-origin fetch classification; execution
requests still reject opaque/foreign origins. CLI clients may use HTTP Basic.
HTTP and non-Secure cookies are appropriate only for this localhost preview;
there is no public HTTP deployment path. The launcher accepts only loopback
or the explicitly enabled, fixed HTTPS N6 hostname. As with the upstream port,
same-account local processes and all holders of the owner credential belong to the same trust domain. Cookies are
not port-isolated, so other services on the localhost hostname must be trusted.

To restart without rebuilding, run `python3 tools/start_n6.py`. To stop only
this stack, run `python3 tools/start_n6.py --stop`. Credentials are preserved.

### Execution and access boundaries

The unmodified GNU listener retains bearer authentication, local Host checks,
loopback binding, source policy, live paging and supervised query cleanup.
The presenter validates the browser host/origin, authenticates the owner, then
translates an approved request to that local protocol using a private random
controller credential. Visitor identity headers grant no access. The controller
credential and password hash are not passed into query-worker environments.
Owner-authenticated command-line clients on the dedicated Docker network may
also address `http://wp_n6:3060`; they share the same owner trust domain.

N6 provides ISOBASE, not ISOTOPE or ACTOR: there is no `/ws`, toplevel-session
or administration API. The curated shared database combines the common family
and price relations with `human/1` and `deployment_node(n6)`. The root URL shows
that same source after owner login. Health, version and non-sensitive node
metadata can be read without a query credential for local discovery; metadata
marks unauthenticated execution unavailable. Unsupported interaction telemetry
is disabled rather than reporting a failed logging endpoint.

Initial budgets are a 2-second computation ceiling per HTTP page, 300-second
idle continuation lifetime, 8 query slots, 256 MiB sampled per query and 512 MiB
sampled across the GNU node. The adapter has 16 connection slots and preserves
the GNU transport's 256 KiB request envelope. The container adds a hard 1 GiB
memory limit, 0.75 CPU and 128 PIDs, a non-root user, read-only filesystem,
no extra Linux capabilities, no new privileges and no core dumps. Busy query
admission and idle-first reclamation remain the GNU controller's policy.

Outbound RPC/source access is restricted to the exact HTTPS N1–N5 origins.
Their IPv4 addresses are pinned at startup; DNS failures stop startup, and a
peer address change requires restarting N6. Other destinations are denied.
No owner credential for a peer is installed. GNU can therefore call the public
SWI/Trealla examples, while calls **into** N6 require the owner credential.

### Qualification and scope

```sh
python3 tests/test_n6_adapter.py
node tools/test-node-catalog.cjs
node tools/test-portal-runtime.cjs
node tools/test-trinity-host.cjs
python3 tools/test_n6.py
python3 tools/test_n6_interop.py
```

Native Linux qualification also runs the pinned port's `tests.py`,
`source_tests.py`, `policy_tests.py`, `http_tests.py` and `security_tests.py` in
the Docker build-check environment. The recovery suite completes 1,000 queries
with the same before/after heap baseline. Consumer checks cover browser login,
CSRF/session tampering and expiry, forbidden browser origins, source larger than
64 KiB, paging, shared data, denied filesystem/outbound access, deadline recovery,
discovery harvesting, GNU→SWI/Trealla calls and authenticated SWI/Trealla→GNU calls.
Interop clients run in disposable containers; N6 credentials are never installed
in the live public peer nodes.

This qualifies the selected trusted-owner localhost pilot, not GNU's entire
language/mode audit or a public multi-user service. The upstream
`isobase/THREAT_MODEL.md`, `SECURITY.md` and release checklist retain their scope.
The HTTPS pilot below retains this single trusted-owner model. Anonymous or
multi-user execution still requires separate qualification, including principal
ownership of continuations and broader hostile-input testing.

### Owner-only HTTPS N6

With `n6.elfenbenstornet.se` pointing to the demonstrator server:

```sh
python3 tools/start_n6.py --https --build
```

This starts the separate `trinity-n6-host` project with no host-published ports.
It reuses the existing owner credentials without rotating them. Its internal
admission proxy permits 16 active requests per client and 32 total, with login
POSTs limited to six per minute and a burst of six. Execution budgets remain
those listed above. No anonymous query execution is enabled.

Apply `compose.gprolog-n6-caddy.yaml` after the existing production overlays:

```sh
docker compose --env-file Deployment/.env \
  -f Deployment/compose.yaml -f Deployment/compose.trealla-n5.yaml \
  -f Deployment/compose.trealla-n5-public.yaml \
  -f Deployment/compose.gprolog-n6-caddy.yaml build caddy
docker compose --env-file Deployment/.env \
  -f Deployment/compose.yaml -f Deployment/compose.trealla-n5.yaml \
  -f Deployment/compose.trealla-n5-public.yaml \
  -f Deployment/compose.gprolog-n6-caddy.yaml up -d --no-deps --no-build caddy
```

Caddy obtains the HTTPS certificate and routes N6 to its admission proxy. The
public N6 page requires owner login. HTTPS cookies are Secure and host-only;
the owner cookie uses the `__Host-` prefix, preventing sibling-domain cookie
injection. The local preview keeps its separate HTTP cookies. Both presenters
use independently generated session keys. The shared DB also requires login.
Caddy and Nginx accept the GNU transport's existing 256 KiB request envelope,
including source passed in a GET query.

The Discovery Hub probes through a container-only Caddy listener on port 8086,
which exposes only GET health/version/node metadata. Port 8086 is not published
and cannot execute queries. This avoids DNS-cache and NAT hairpin dependencies.
Rebuild/restart the hub after updating its seed; rebuild the standard UI images
to show N6 from the other nodes.

```sh
python3 tools/test_n6.py --url https://n6.elfenbenstornet.se \
  --hub-url https://n0.elfenbenstornet.se
```

While a local resolver retains NXDOMAIN, `--resolve-ip SERVER_IP` overrides only
the N6 test lookup and still verifies TLS against its hostname. To stop N6 use
`python3 tools/start_n6.py --https --stop`. To remove its external route, recreate
Caddy with the original three production Compose files (omit the N6 overlay).
The localhost stack and credential file are preserved.

## HTTP visitor ownership on N1–N4 and N6

The SWI launchers now enable `node_http_identity:anonymous_visitors`. Browsers
receive signed, Secure, host-only visitor cookies. HTTP continuations and
ISOTOPE sessions have visitor ownership; anonymous WebSocket connections get
independent principals. Native and browser RPC clients carry a cryptographically
random query capability across pages, including cross-site browser calls without
cookies. Capability headers stay out of URLs and Caddy runtime logs.

HTTP admission charges both the visitor and Caddy's overwritten client address.
Existing execution deadlines, page behavior and node/container ceilings remain.
The SWI continuation cache adds ceilings of 16 entries per owner/address and 32
per address, within its existing total of 100. Insertions cannot evict another
owner's work; cache misses retain offset replay. Users behind a NAT share the
address allowance. Creating new cookies/capabilities does not multiply it.
Public Prolog RPC cannot forge proxy identity/address headers or call private
controller/cache entry points, including through meta-calls.

N6 requires separate controller owner and budget namespaces. Its presenter derives
ownership from a validated login cookie or CLI conversation capability and derives
the budget group from trusted ingress/socket addresses. Its existing eight query
slots are bounded to four per owner and six per client-address group (active plus
retained queries). Admission eviction selects only that owner's idle work. The
N6 proxy also limits query requests to 120/minute per address with a burst of 60;
its previous login and connection limits remain in place.

The original ownership-only profile is still owner-only. Ownership and quotas
alone do not establish isolation from hostile native workers; the public profile
above adds and qualifies OS containment. See the [qualification record](../docs/verification/http-visitor-ownership-2026-11-04.json)
for exact pins, checks and the remaining public-release gates. The GNU threat model
still excludes a generally supported public/multi-user service. This change does
not claim a security audit of the Trealla N5 runtime.

```sh
python3 tools/test_http_visitors.py
python3 tools/test_n6.py --url https://n6.elfenbenstornet.se \
  --hub-url https://n0.elfenbenstornet.se
```

The low-volume live check verifies independent paging on N1–N4, HTTPS cookie
properties, browser RPC preflights and separate N6 workers. Admission saturation,
identity tampering, session ownership and forged-proxy tests run against disposable
upstream fixtures, rather than saturating the public services. N6 credentials
are read from the ignored private access file and never printed or sent to public
peers. Test programs should retain their query capability or response cookie for
live pagination; losing it produces a fresh query context.

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

1. Open `https://n3.elfenbenstornet.se/demonstrator` and exercise the node.
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

### Authenticated pooled peer connections

Public N5 strips client-supplied trusted-identity headers. A pooled SWI connection
that delegates actor lifetimes therefore needs a destination-bound bearer token
with `execute` and `internal_transport`; anonymous execution alone cannot claim
transport lineages. Keep this capability off browser and ordinary visitor tokens.
Provision the token through the N5 owner's private administration interface.

The SWI launcher accepts `WP_PEER_TRANSPORT_TOKENS_FILE`, containing one Prolog
list and no other terms, for example:

```prolog
['https://n5.elfenbenstornet.se'-'OWNER_PROVISIONED_TOKEN'].
```

Store the file outside served assets, readable only by the owner and node process.
The URL is the exact public destination, including any port. The launcher rejects
malformed files and prints only the number of configured peers. To configure N3
and N4, add `compose.peer-transport.yaml` after the deployment's existing overlays
and set `WP_N3_PEER_TOKENS_FILE` and `WP_N4_PEER_TOKENS_FILE` to those owner files.
The overlay mounts them read-only; it does not provision tokens or alter the
public proxy's identity-header stripping. Runtime/source updates and credential
rollout must be deployed together before the live actor matrix can pass.

For Docker hosts without bind mounts, use `compose.peer-transport-volumes.yaml`
instead and set `WP_N3_PEER_TOKENS_VOLUME` / `WP_N4_PEER_TOKENS_VOLUME` to
external volumes containing `peers.pl`, readable by the image's `webprolog` user.
Mounts remain read-only. Retain every overlay used by the running deployment;
when N6 is present, `compose.gprolog-n6-caddy.yaml` must also follow the public
N5 overlay so rebuilding Caddy retains N6 routing and its network attachment.
