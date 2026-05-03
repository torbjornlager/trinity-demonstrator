# Deployment Bundle

This folder contains a first practical deployment bundle for exposing four
Web Prolog nodes on the public internet and keeping one admin node local-only.

Target hostnames:

- `n1.elfenbenstornet.se`: public, `profile(isobase)`, most conservative
- `n2.elfenbenstornet.se`: public, `profile(isotope)`
- `n3.elfenbenstornet.se`: public ACTOR demo, `profile(actor)`
- `n4.elfenbenstornet.se`: second public ACTOR demo, `profile(actor)`
- `admin.elfenbenstornet.se`: reserved admin hostname, but not publicly routed

The shape is:

```text
Internet
  -> DNS for n1 / n2 / n3 / n4
  -> router forwards 80 and 443 to the host
  -> Caddy container
  -> private Docker network
  -> wp_n1 / wp_n2 / wp_n3 / wp_n4 / wp_admin containers
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
  [`ADMIN-DEPLOYMENT-MANUAL.public.md`](ADMIN-DEPLOYMENT-MANUAL.public.md)
- focused content-edit workflow:
  [`EDITING_AND_DEPLOYING.md`](EDITING_AND_DEPLOYING.md)

If you keep a more detailed local operator manual with home-network specifics,
keep that one out of public git.

## Files

- `Dockerfile`: image for all five SWI-Prolog nodes
- `compose.yaml`: the 6-service Docker Compose stack
- `Caddyfile`: public routing and TLS termination
- `start_n1.pl`: launcher for `n1.elfenbenstornet.se`
- `start_n2.pl`: launcher for `n2.elfenbenstornet.se`
- `start_n3.pl`: launcher for `n3.elfenbenstornet.se`
- `start_n4.pl`: launcher for `n4.elfenbenstornet.se`
- `start_admin.pl`: launcher for the local-only admin node
- `shared_db_common.pl`: common shared database loaded by every deployment node
- `shared_db_actor_common.pl`: shared database loaded by ACTOR-profile nodes (`n3`, `n4`)
- `shared_db_n1.pl`: per-node overlay for `n1`
- `shared_db_n2.pl`: per-node overlay for `n2`
- `shared_db_n3.pl`: per-node overlay for `n3`
- `shared_db_n4.pl`: per-node overlay for `n4`
- `shared_db_admin.pl`: per-node overlay for `admin`

## Before You Start

1. Install Docker Desktop on the host and confirm both commands work:

```bash
docker version
docker compose version
```

2. Reserve the host's LAN address in the router DHCP settings.

3. In DNS for `elfenbenstornet.se`, create `A` records for:

   - `n1.elfenbenstornet.se`
   - `n2.elfenbenstornet.se`
   - `n3.elfenbenstornet.se`
   - `n4.elfenbenstornet.se`

   Point them to your current public IPv4.

4. Do not publish `admin.elfenbenstornet.se` in public DNS yet.

5. Forward router ports `80` and `443` to the host.

## Start The Stack

From this folder:

```bash
cd Deployment
docker compose up --build -d
```

Check status:

```bash
docker compose ps
docker compose logs -f caddy wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
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
