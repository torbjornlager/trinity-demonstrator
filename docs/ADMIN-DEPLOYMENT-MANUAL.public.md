# Public Deployment Manual

This is the redacted operator manual for the Docker-based deployment of the
public Web Prolog nodes.

Public hostnames:

- `n1.elfenbenstornet.se` -> public `isobase`
- `n2.elfenbenstornet.se` -> public `isotope`
- `n3.elfenbenstornet.se` -> public `actor`
- `n4.elfenbenstornet.se` -> second public `actor`

Reserved admin hostname:

- `admin.elfenbenstornet.se`

The intended deployment shape is:

```text
Internet
  -> DNS for n1 / n2 / n3 / n4
  -> router forwards 80 and 443 to the deployment host
  -> Caddy container
  -> private Docker network
  -> wp_n1 / wp_n2 / wp_n3 / wp_n4 / wp_admin containers
```

## Main Rule

Do not run the public deployment by manually starting `swipl` on the host.

The live deployment is managed by Docker Compose.

## Services

Compose service names:

- `caddy`
- `wp_n1`
- `wp_n2`
- `wp_n3`
- `wp_n4`
- `wp_admin`

## Operational Commands

Change to the deployment directory:

```bash
cd Deployment
```

Show service status:

```bash
docker compose ps
```

Follow the main public logs:

```bash
docker compose logs -f caddy wp_n1 wp_n2 wp_n3 wp_n4
```

Follow all logs:

```bash
docker compose logs -f caddy wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

Build and start everything:

```bash
docker compose up --build -d
```

Rebuild only the node containers:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

Recreate the node containers after a Compose-file mount change:

```bash
docker compose up -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

Optional live-examples override:

```bash
docker compose -f compose.yaml -f compose.examples-live.yaml up -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

Restart all services without rebuilding:

```bash
docker compose restart caddy wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

Restart just one service:

```bash
docker compose restart caddy
docker compose restart wp_n1
docker compose restart wp_n2
docker compose restart wp_n3
docker compose restart wp_n4
docker compose restart wp_admin
```

Stop the stack:

```bash
docker compose down
```

## Health Checks

Check that the manuals load over HTTPS:

```bash
curl -I https://n1.elfenbenstornet.se/manual
curl -I https://n2.elfenbenstornet.se/manual
curl -I https://n3.elfenbenstornet.se/manual
curl -I https://n4.elfenbenstornet.se/manual
```

Check node identity JSON:

```bash
curl https://n1.elfenbenstornet.se/node_info
curl https://n2.elfenbenstornet.se/node_info
curl https://n3.elfenbenstornet.se/node_info
curl https://n4.elfenbenstornet.se/node_info
```

Check stateless query routing:

```bash
curl "https://n1.elfenbenstornet.se/call?goal=human(X)"
curl "https://n2.elfenbenstornet.se/call?goal=human(X)"
curl "https://n3.elfenbenstornet.se/call?goal=human(X)"
curl "https://n4.elfenbenstornet.se/call?goal=human(X)"
```

## TLS and Caddy

Caddy terminates HTTPS and stores certificate state in Docker volumes.

If DNS or networking changes, restart Caddy and watch its log:

```bash
docker compose restart caddy
docker compose logs -f caddy
```

What you want to see:

- `certificate obtained successfully`
- no repeated ACME challenge failures

## DNS

Public DNS must contain `A` records for:

- `n1.elfenbenstornet.se`
- `n2.elfenbenstornet.se`
- `n3.elfenbenstornet.se`
- `n4.elfenbenstornet.se`

Those records should point to the current public IPv4 of the deployment host.

Useful checks:

```bash
curl -4 -s https://ifconfig.me
dig +short n1.elfenbenstornet.se A
dig +short n2.elfenbenstornet.se A
dig +short n3.elfenbenstornet.se A
dig +short n4.elfenbenstornet.se A
```

Important note:

- if the public IP changes, DNS must be updated
- do not publish public `AAAA` records unless public IPv6 routing is set up and tested

## Router

The edge router must forward:

- TCP `80` -> deployment host
- TCP `443` -> deployment host

The deployment host should have a reserved LAN address in DHCP so those
forwards stay valid.

The admin service should remain local-only and should not be forwarded
publicly.

## Node Roles

`n1`

- public conservative node
- `profile(isobase)`
- reduced portal is available
- intended UI is runtime-only: Terminal and Logger
- main public routes: `/`, `/call`, `/manual`, `/node_info`, `/img*`, `/portal`
- shared DB role: common base plus `deployment_node(n1)`
- shared DB file: `Deployment/shared_db_n1.pl`

`n2`

- public isotope node
- `profile(isotope)`
- portal is available
- adds editor/tutorial/example assets and `/toplevel_*`
- shared DB role: common base plus `mortal/1`, `ancestor/2`, `descendant/2`,
  `family_member/1`
- shared DB file: `Deployment/shared_db_n2.pl`

`n3`

- public actor node
- `profile(actor)`
- adds `/ws`, `/portal`, examples, statecharts, and richer demo routes
- shared DB role: common base plus `echo_server/0`, `echo_actor/0`, `alarm/0`,
  `fridge/1`, and `service/2` entries for `counter` and `pubsub_service`
- shared DB file: `Deployment/shared_db_n3.pl`

`n4`

- second public actor node
- `profile(actor)`
- adds `/ws`, `/portal`, examples, statecharts, and richer demo routes
- shared DB role: common base plus `echo_server/0`, `echo_actor/0`, `alarm/0`,
  `fridge/1`, and `service/2` entries for `counter` and `pubsub_service`
- shared DB file: `Deployment/shared_db_n4.pl`

`wp_admin`

- not publicly routed by Caddy
- intended for localhost-only access
- shared DB role: common base plus deployment-local admin facts
- shared DB file: `Deployment/shared_db_admin.pl`

## `load_uri` Policy

The deployment uses an application-level allowlist for `load_uri`.

Public nodes only allow source fetches from:

- `https://n1.elfenbenstornet.se`
- `https://n2.elfenbenstornet.se`
- `https://n3.elfenbenstornet.se`
- `https://n4.elfenbenstornet.se`

This blocks:

- bare local file paths
- `file://...`
- arbitrary remote HTTP(S) origins

## Troubleshooting

If HTTP redirects to HTTPS but HTTPS fails:

- check DNS
- check port forwarding
- inspect `docker compose logs -f caddy`

If `/manual` works but `/` or `/node_info` fails:

- the problem is probably in the node application layer, not the network edge
- inspect:

```bash
docker compose logs --tail=100 wp_n1
docker compose logs --tail=100 wp_n2
docker compose logs --tail=100 wp_n3
docker compose logs --tail=100 wp_n4
```

If one node misbehaves after a code change:

```bash
docker compose up --build -d wp_n1
docker compose up --build -d wp_n2
docker compose up --build -d wp_n3
docker compose up --build -d wp_n4
docker compose up --build -d wp_admin
```

If example edits under `examples/` are not reflected in the Examples drawer:

- in the default deployment, example files are baked into the image
- rebuild the node containers with:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

- there is an optional `compose.examples-live.yaml` override for read-only
  bind-mounting `examples/`
- if Docker Desktop reports `mounts denied` for `../examples`, do not use the
  live-mount override

If shared DB edits are not reflected on a node:

- each node now has its own shared DB file under `Deployment/`
- all deployment nodes also load `Deployment/shared_db_common.pl`
- rebuild the node containers with:

```bash
docker compose up --build -d wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
```

`n3` and `n4` also start the node-resident `counter` and `pubsub_service`
actors on startup, so a rebuild/restart of `wp_n3` or `wp_n4` is enough to
recreate them.

## Files Likely Safe To Commit

These are reasonable public-repo candidates:

- `Deployment/Caddyfile`
- `Deployment/Dockerfile`
- `Deployment/Dockerfile.caddy`
- `Deployment/compose.yaml`
- `Deployment/start_n1.pl`
- `Deployment/start_n2.pl`
- `Deployment/start_n3.pl`
- `Deployment/start_n4.pl`
- `Deployment/start_admin.pl`
- `Deployment/README.md`
- `ADMIN-DEPLOYMENT-MANUAL.public.md`

## Files Better Kept Private

These should stay out of a public repo:

- detailed private ops notes with LAN addresses and home-network specifics
- future `.env` files
- `compose.override.yaml` or other machine-local overrides
- backup copies of Caddy certificate/config volumes
- router screenshots and account details
- any future credentials or API tokens

## Quick Reference

```bash
cd Deployment
docker compose ps
docker compose logs -f caddy wp_n1 wp_n2 wp_n3 wp_n4
docker compose up --build -d
docker compose restart caddy wp_n1 wp_n2 wp_n3 wp_n4 wp_admin
curl -4 -s https://ifconfig.me
dig +short n1.elfenbenstornet.se A
dig +short n2.elfenbenstornet.se A
dig +short n3.elfenbenstornet.se A
dig +short n4.elfenbenstornet.se A
```
