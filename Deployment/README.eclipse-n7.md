# Owner-only ECLiPSe N7 pilot

The host HTTP adapter listens on loopback and runs the packaged engine in a
separate Linux ARM64 container. The engine has no network or published port.
The adapter exchanges JSON with it over stdin and stdout. The proxy token
stays in the host adapter, and the engine gets neither the token file nor the
Docker socket. This pilot can run alongside the existing nodes.

## Build and run locally

### Set up a fresh checkout

Install Git, Python 3, Docker with Buildx and Compose (with Linux ARM64 support),
threaded SWI-Prolog 10.1.19 or newer on `PATH`, and Node.js 22. Set `N7_NODE`
to the Node.js executable if needed. Fetching the dependencies requires Git
read access to their GitHub repositories.

```sh
git clone --branch codex/n7-shell-preview --single-branch \
  https://github.com/torbjornlager/trinity-demonstrator.git eclipse-node
cd eclipse-node
python3 tools/fetch_swi.py --destination .trinity/deps/swi-prolog-node
python3 tools/fetch_browser.py --destination .trinity/deps/swi-wasm-node
python3 tools/setup_swi.py --native-root .trinity/deps/swi-prolog-node \
  --browser-root .trinity/deps/swi-wasm-node
```

Fetch the pinned N7 conformance runner from GitHub. If you set up this checkout
using the older local conformance instructions, run this block to update the
dependency to the published revision.

```sh
n7_conformance=.trinity/deps/trinity-conformance
git init --quiet "$n7_conformance"
git -C "$n7_conformance" fetch --depth=1 --no-tags \
  https://github.com/torbjornlager/trinity-conformance.git \
  15cfacebd4625d891f0ecea9c551edcc70678bd9
git -C "$n7_conformance" checkout --detach FETCH_HEAD
```

Copy the reviewed Linux ARM64 ECLiPSe archive into the local build context and
check its checksum. Then run the build and all three checks.

```sh
mkdir -p .trinity/n7-local/eclipse-dist
cp /path/to/eclipse_basic.tgz .trinity/n7-local/eclipse-dist/eclipse_basic.tgz
printf '%s  %s\n' \
  7599e154cca23b5601ed133df2f0481c43baf115b8cd6d7757795729d815e0d5 \
  .trinity/n7-local/eclipse-dist/eclipse_basic.tgz | shasum -a 256 -c
./tools/check_n7.sh
```

The command builds `trinity-eclipse-n7:eclipse-node-dev`, tests both N7 routes
with a local sign-in fixture, runs conformance with a disposable SWI peer, and
checks the demonstrator catalog. It saves each run's conformance reports under
the Git-ignored `.trinity/n7-local/conformance.*` directory. The local fixtures
use synthetic credentials, so setup only requires the sources and runtime
archive above.

### Build and probe the adapter separately

From the repository root, put the reviewed Linux ARM64 `eclipse_basic.tgz` in
a dedicated build context. The Dockerfile pins the Debian base and checks the
archive's SHA-256 before extraction. The image includes the runtime's notices.

```sh
n7_dist=$(mktemp -d)
cp /path/to/eclipse_basic.tgz "$n7_dist/"
docker buildx build --load --platform linux/arm64 \
  --build-context "eclipse_dist=$n7_dist" \
  -f Deployment/Dockerfile.eclipse-n7 -t trinity-eclipse-n7:local .
```

For a disposable local test, generate a proxy credential and start the
adapter with a synthetic HTTPS origin and owner identity. The origin is an
expected HTTP header at this stage, and the listener stays on `127.0.0.1`.

```sh
n7_private=$(mktemp -d)
(umask 077; openssl rand -hex 32 > "$n7_private/proxy-token")
python3 experiments/eclipse-clp/isotope_http.py \
  --pilot-image trinity-eclipse-n7:local --port 18087 \
  --private-origin https://n7.example.test --owner owner@example.test \
  --proxy-token-file "$n7_private/proxy-token"
```

Run the probe from a second terminal using the same token file path. It
simulates requests from the trusted proxy. Stop the adapter with Ctrl-C.

```sh
python3 experiments/eclipse-clp/probe_http_private.py \
  --port 18087 --private-origin https://n7.example.test \
  --owner owner@example.test --proxy-token-file /path/to/proxy-token \
  --pilot-limits
```

## Limits

| Boundary | Pilot setting |
| --- | --- |
| Engine container | 0.75 CPU, 384 MiB RAM with swap disabled, 64 tasks, and a 16 MiB temporary filesystem |
| Container privileges | UID/GID 65532, read-only root, no capabilities, no new privileges, and no network |
| HTTP adapter | 16 concurrent connections, four live or opening sessions, and two outstanding stateless calls |
| Query handling | Three-second ordinary event wait. A resumed query or output awaiting Poll is halted if left unpolled for ten seconds. |
| Engine watchdog | Six seconds for a bridge request and a 512 KiB JSON reply limit. The adapter retires a stalled engine and rejects subsequent execution until restarted. |

The owner proxy must replace any client values for `X-Web-Prolog-User` and
`X-Web-Prolog-Proxy-Token` with the verified owner identity and server-held
token. It must preserve Host, Origin and Fetch Metadata for the adapter's
checks.

## HTTPS and GitHub sign-in

`compose.eclipse-n7-https.yaml` starts a standalone loopback HTTPS gateway
and a dedicated OAuth2 Proxy. It reads the GitHub login and verified email
from the same `OAUTH2_PROXY_GITHUB_USERS` and `WP_N5_OWNER` settings as N5.
OAuth2 Proxy checks the login. The N7 Caddy route checks both the login and
email before forwarding, and the adapter checks the owner again. The N7
cookie is Secure, HttpOnly and host-only, with its own signing secret.

Run the disposable HTTPS smoke test after building the engine image.
It runs the real Caddy and OAuth2 Proxy containers against a local fixture
for the GitHub OAuth and user APIs. Its HTTPS client trusts only the
temporary Caddy CA for this fixture.

```sh
python3 tools/test_n7_https.py
```

For the live route, register a dedicated GitHub OAuth app with the callback
`https://n7.elfenbenstornet.se/oauth2/callback` and point the N7 DNS record
at the demonstrator edge. Keep the N7-only settings in an owner-readable
environment file outside Git. Use the N5 environment file as the first
Compose environment file and the N7 file second. Set these N7 values there.

| Setting | Value |
| --- | --- |
| `N7_ORIGIN` | `https://n7.elfenbenstornet.se` |
| `N7_OAUTH2_CLIENT_ID` and `N7_OAUTH2_CLIENT_SECRET` | The dedicated N7 app credentials |
| `N7_OAUTH2_COOKIE_SECRET` | A newly generated URL-safe base64 encoding of 32 random bytes |
| `N7_PROXY_TOKEN` | The 64-digit token also used by the host adapter's `--proxy-token-file` |

The public edge uses the separate `Caddyfile.eclipse-n7` site with
`N7_TLS_DIRECTIVE` empty for public TLS. Its OAuth upstream must be reachable
from the edge on the N7 network, and its engine upstream must reach the
loopback adapter through the Docker host gateway. The standalone Compose
gateway is for local TLS verification. On the public route, sign in and use
**Start paging**, **Next answer**, and **Ask for a term** on `/demonstrator`.

On the current deployment, the host adapter runs as the user launch agent
`se.elfenbenstornet.trinity-n7-adapter`. The `trinity-n7-https` Compose project
runs only the OAuth2 sidecar on the N7 network. The existing edge has an
additive N7 site import. The import survives a restart of that container.
Recreating the edge container from its image requires reapplying the N7 site.

The live Discovery Hub page probes N7 with a credential-free GET to
`/node_info`. The response contains the engine-reported version and the
private ISOTOPE profile. The OAuth gate still covers the pilot and execution
routes. The live Hub registry also includes N7 through the coexistence seed
and probes its metadata through the container-only listener on port 8087.

## Stateless queries and peer access

Owner-authenticated `/call` requests accept `format=prolog` or
`format=json`, plus optional `src_text` loaded into the request's private
module. The source loader accepts local clauses and dynamic declarations.

Queries can use `rpc(localhost, ...)` and `promise(localhost, ...)` inside
the engine. Each request gets a fresh module. Promises belong to the running
query and can be collected with `yield/2`.

The engine container has no network access. To enable cross-node RPC or
`src_uri` loading, start the host adapter with one `--allow-peer ORIGIN`
argument per trusted HTTP(S) origin. The default allowlist is empty. The
adapter makes bounded GET requests, refuses redirects, and sends no owner
credentials. An allowlisted origin can serve stateless `/call` requests and
source files.

The live N7 adapter currently allowlists only `https://n3.elfenbenstornet.se`.

## Recovery bundle

Capture the running release from the repository root.

```sh
export N7_RECOVERY_DIR=/absolute/path/to/new-n7-recovery
N7_COMPACT_BUNDLE=/absolute/path/to/previous-compact-bundle
python3 tools/n7_recovery.py capture --output "$N7_RECOVERY_DIR"
python3 tools/test_n7_recovery.py "$N7_RECOVERY_DIR" --compact-rollback "$N7_COMPACT_BUNDLE"
```

The private bundle contains the running engine image under a separate recovery
tag, the adapter, both edge configurations, the OAuth route template, and the
exact catalog and Discovery Hub assets served by the edge. When the full shell
is enabled, it includes that static package and its source revision and
verifies every asset against the package manifest. Capture checks that the live
route matches the template and that the edge changes are N7 additions.
The optional `--compact-rollback` argument takes the previous compact-only
bundle. The rehearsal uses disposable peers and GitHub OAuth fixtures.

Keep the existing N5 and N7 environment files, N7 proxy token file, and the
separate N7 settings file with the OAuth cookie secret alongside the backup.
The installation reads those credentials separately.

To recover the adapter, use the helper inside the bundle with its absolute
path. Write the LaunchAgent outside the bundle, using the verified owner
email and the same token file that supplies `N7_PROXY_TOKEN` to the edge.

```sh
python3 "$N7_RECOVERY_DIR/tools/n7_recovery.py" load "$N7_RECOVERY_DIR"
python3 "$N7_RECOVERY_DIR/tools/n7_recovery.py" launch-plist "$N7_RECOVERY_DIR" \
  --owner "$WP_N5_OWNER" --token-file "$N7_PROXY_TOKEN_FILE" \
  --log "$N7_ADAPTER_LOG" --output "$N7_STAGED_PLIST"
```

Install the staged plist as `~/Library/LaunchAgents/se.elfenbenstornet.trinity-n7-adapter.plist`
and bootstrap it in the user's GUI domain. For a replacement, back up the
current plist and boot out that job first. The generated plist uses the
recorded engine image and the single N3 origin. Full-shell bundles also set
`--shell-assets` to the verified package inside the bundle.

For edge recovery, start only `oauth2_n7` from the bundled
`Deployment/compose.eclipse-n7-https.yaml` in project `trinity-n7-https`,
with the existing environment files. Then add the bundled
`Deployment/compose.eclipse-n7-recovery.yaml` last in the shared edge's
existing Compose file list. Use the same edge project, verified edge image,
and environment files. Recreate only the `caddy` service with
`up -d --no-deps --force-recreate caddy`. The override mounts the bundle
read-only and reconnects the edge to N7's OAuth network.

To roll back that edge recovery, remove the recovery override and recreate
only `caddy` using the same base Compose files and the recorded edge image.
The manifest records whether the image's baked config matches
`Caddyfile.rollback`. For this capture it matches byte-for-byte. Stop the
N7 sidecar and adapter after the edge rollback if removing the pilot.
To return to the compact-only pilot, use the previous bundle for both the edge
and the adapter. This also restores the old catalog and Hub destinations.

## Full demonstrator shell

The compact pilot stays at `/demonstrator`. The opt-in full shell uses the
same origin and owner gate at `/n7-shell/`. Build the browser dependencies
against their pinned revisions, then prepare a static distribution with the
same HTTPS origin as the private adapter.

```sh
python3 tools/package_demonstrator.py --prefix /n7-shell/ \
  --node-url https://n7.elfenbenstornet.se --output /path/to/n7-shell
```

Start the matching preview engine and adapter with
`--shell-assets /path/to/n7-shell`. Use the preview Caddy route so an anonymous
shell visit signs in and returns to the shell. The browser keeps the HTTP
session, editor source and prompt replies on the owner-only N7 origin.

Run `python3 tools/test_n7_https.py --image trinity-eclipse-n7:shell-preview --shell`
to exercise the preview with disposable TLS and GitHub fixtures. The preview
uses the same access policy as the live shell.

## Local verification

The packaged image passed PT-004 through PT-020 using simulated owner
headers. The private probe checked connection and session admission,
stateless and session timeouts, and retirement after an unpolled reply.
It opened and halted 80 sessions sequentially under the 64-task limit
after the actor reaper was changed to close joined native engines.
Pausing the engine container caused the watchdog to return HTTP 502 and
remove the stalled container. The local actor and toplevel probes also
passed after the reaper change.

The HTTPS fixture denied anonymous API requests, a wrong GitHub login, and
an allowed login with a different verified email. Chrome paged through
`a`, `b`, and `c`, submitted a term to a correlated prompt, and closed the
session using the fixture owner. The live N7 route rejects anonymous API
requests and redirects page visits to GitHub with the dedicated callback.
The deployed backend also passed paging and prompt checks using its trusted
proxy credential. The live owner browser also passed paging, prompt replies,
stateless JSON with request-local source, and the N3 allowlist check.
