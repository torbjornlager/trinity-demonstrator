# Deployment Bundle

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

By default, the node containers use the examples copied into the image at build time. If you edit files under [`examples/`](examples), rebuild the node containers to make those changes visible in the Examples drawer:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

An optional override file, [`compose.examples-live.yaml`](Deployment/compose.examples-live.yaml), bind-mounts `examples/` read-only from the host so example edits show up without rebuilding. Use it only if Docker Desktop file sharing for the repo root is working:

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
- `shared_db_n1.pl` … `shared_db_n4.pl`: per-node overlays for `n1`–`n4`
- `shared_db_admin.pl`: per-node overlay for `admin`
- `n5` uses the repo default `shared_db.pl` (no overlay); `n0` serves
  `examples/services/discovery_directory.pl` as its shared database
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
   secret and a cookie secret in `.env` (see `.env.n5-sso.example`).

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
  [`shared_db_n1.pl`](Deployment/shared_db_n1.pl)
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
  [`shared_db_n2.pl`](Deployment/shared_db_n2.pl)
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
  `service/2` entries for `counter` and `pubsub_service`, `echo_actor/0`,
  `count_actor/1`, `alarm/0`, `fridge/1`, `fridge/4`, `fridge2/4`,
  `store/3`, `take/3`, `ping/2`, `pong/0`, `ping_pong/0`
- shared DB file:
  [`shared_db_n3.pl`](Deployment/shared_db_n3.pl)
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
  `service/2` entries for `counter` and `pubsub_service`, `echo_actor/0`,
  `count_actor/1`, `alarm/0`, `fridge/1`, `fridge/4`, `fridge2/4`,
  `store/3`, `take/3`, `ping/2`, `pong/0`, `ping_pong/0`
- shared DB file:
  [`shared_db_n4.pl`](Deployment/shared_db_n4.pl)
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
  [`shared_db_admin.pl`](Deployment/shared_db_admin.pl)

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
`examples/services/discovery_directory.pl`), or the node engine
(`prolog/web_prolog/`) only go live after a **rebuild + recreate** — the
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

## SSO node (n5)

`n5.elfenbenstornet.se` is the layered production node at `profile(actor)`,
`auth(private)`. The `oauth2_n5` sidecar authenticates each visitor against
GitHub; the n5 Caddy vhost runs `forward_auth` and injects the verified
identity as `X-Web-Prolog-User` (trusted only from the private proxy peer,
so a public client cannot spoof it). Signed-in users get the
`WP_AUTHENTICATED_DEFAULT_CAPS` ("registered") capability tier. It builds
from `Dockerfile.node` (context `..`) and uses the repo default
`shared_db.pl`.

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
  assume an identity by setting it

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

`load_uri` is now restricted in the application layer on these launchers:

- `n1`, `n2`, `n3`, and `n4` only allow source fetches from:
  `https://n1.elfenbenstornet.se`,
  `https://n2.elfenbenstornet.se`,
  `https://n3.elfenbenstornet.se`,
  `https://n4.elfenbenstornet.se`
- `admin` additionally allows its own hostname

When this allowlist is active, public `load_uri` rejects:

- bare local file paths
- `file://...` URIs
- arbitrary HTTP(S) origins outside the configured set

## Per-Node Shared Databases

Each deployment node now loads:

- the common base
  [`shared_db_common.pl`](Deployment/shared_db_common.pl)
- plus its own overlay file:

- `n1` -> [`shared_db_n1.pl`](Deployment/shared_db_n1.pl)
- `n2` -> [`shared_db_n2.pl`](Deployment/shared_db_n2.pl)
- `n3` -> [`shared_db_n3.pl`](Deployment/shared_db_n3.pl)
- `n4` -> [`shared_db_n4.pl`](Deployment/shared_db_n4.pl)
- `admin` -> [`shared_db_admin.pl`](Deployment/shared_db_admin.pl)

The current deployment split is:

- `shared_db_common.pl`: family-tree relations
- `shared_db_actor_common.pl`: actor predicates (`echo_actor/0`, `count_actor/1`, `alarm/0`, `fridge/1`, `fridge/4`, `fridge2/4`, `store/3`, `take/3`, `ping/2`, `pong/0`, `ping_pong/0`) plus the public service directory; loaded only by `n3` and `n4`
- `shared_db_n1.pl`: `deployment_node(n1).` plus `human(plato)` / `human(aristotle)` (used by `n2`'s rpc chain)
- `shared_db_n2.pl`: isotope-friendly derived predicates over the common base
- `shared_db_n3.pl`: `deployment_node(n3).` plus the `mortal/1` / `human/1` chain that the distributed proof tree pulls through to `n4`
- `shared_db_n4.pl`: `deployment_node(n4).` plus `human(plato)` / `human(aristotle)` (used by `n3`'s distributed proof tree)
- `shared_db_admin.pl`: local deployment facts for admin use

This keeps the repo-level
[`shared_db.pl`](shared_db.pl)
unchanged for non-deployment defaults.

After editing any of the shared DB files, rebuild the node containers:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

`n3` and `n4` additionally start the node-resident `counter` and `pubsub_service`
actors at startup through
[`examples/services/node_resident_services.pl`](examples/services/node_resident_services.pl).

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
