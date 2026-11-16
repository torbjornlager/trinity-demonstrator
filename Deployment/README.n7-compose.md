# N7 in Docker Compose

N7's trusted Python HTTP/WebSocket adapter runs as `wp_n7` in the `deployment`
Compose project. It launches the existing ECLiPSe engine image as separate
visitor containers. Those workers retain their non-root user, read-only root,
disabled networking, resource limits and absence of host mounts or credentials.
Only the trusted adapter mounts the Docker socket and its owner configuration.

From the repository root, restart N7 with:

```sh
docker compose -p deployment -f Deployment/compose.n7.yaml restart wp_n7
```

Status and logs:

```sh
docker compose -p deployment -f Deployment/compose.n7.yaml ps wp_n7
docker compose -p deployment -f Deployment/compose.n7.yaml logs -f wp_n7
```

The machine's private `Deployment/compose.live.json` captures the running
`deployment` project's actual image, environment, volume and network selections,
including `wp_n7`. It contains private configuration and is ignored by Git.
To restart that whole project:

```sh
docker compose -p deployment -f Deployment/compose.live.json restart
```

N0 and N6 retain their existing separate Compose projects. No LaunchAgent or
standalone N7 ingress relay is needed for the public N7 adapter. The shared
host TLS router's existing loopback destination now reaches Caddy directly on
`127.0.0.1:18497`; Caddy forwards to `wp_n7:18087` on the private Docker network.
The adapter itself publishes no host port. Caddy's configuration and existing
asset trees live in persistent Docker volumes, so recreating Caddy retains them.

## Build or update the adapter

Prepare a context from a verified N7 package. Explicit `--adapter-source`
options can overlay the adapter-only modules `isotope_http.py` and
`n7_actor_ws.py` from the owning `eclipse-node` checkout (repeat the option for
both); their hashes are recorded separately from the package's engine identity.

```sh
python3 tools/prepare_n7_adapter.py \
  --release /absolute/path/to/verified-n7-release \
  --output /absolute/path/to/new-image-inputs
```

Select that input directory for the build, then recreate N7:

```sh
N7_RELEASE_CONTEXT=/absolute/path/to/new-image-inputs \
  docker compose -p deployment -f Deployment/compose.n7.yaml build wp_n7
docker compose -p deployment -f Deployment/compose.n7.yaml up -d --no-deps wp_n7
```

On this machine the default `.trinity/n7-adapter-release` points to the prepared
inputs. Python and Docker CLI bases are digest-pinned; Python dependencies are
installed from the package's existing offline wheels. The ECLiPSe worker image
is selected separately in the mounted configuration and must already exist in
the Docker daemon. A restart uses existing images.

## Configuration and lifecycle

The external `deployment_n7_config` volume holds `adapter.json` and separate
proxy/peer token files. It is mounted read-only at `/run/n7`. Tokens are not
stored in the adapter image or passed to visitor engines. `adapter.json` holds
the existing adapter arguments with container-local asset and credential paths.
The container entrypoint sets `--bind 0.0.0.0`; host launches retain their
loopback default. `N7_DOCKER_SOCKET` can select the daemon socket path when
building a different Docker host setup.

Compose sends SIGTERM through its init process and allows 60 seconds for the
adapter to retire visitor engines and the trusted peer engine. Startup recovers
abandoned public workers using their existing exact-origin label. Health checks
query the local ACTOR metadata endpoint without creating a visitor engine.

The [migration record](../docs/verification/n7-compose-migration-2026-11-16.json)
records the selected images, focused verification and preserved configuration.
