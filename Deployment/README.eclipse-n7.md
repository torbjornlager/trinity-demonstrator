# Owner-only ECLiPSe N7 pilot

The host HTTP adapter listens on loopback and runs the packaged engine in a
separate Linux ARM64 container. The engine has no network or published port.
The adapter exchanges JSON with it over stdin and stdout. The proxy token
stays in the host adapter, and the engine gets neither the token file nor the
Docker socket. This pilot can run alongside the existing nodes.

## Build and run locally

### Set up a fresh checkout

Install Git, Python 3, `curl`, `shasum`, Docker with Buildx and Compose (with
Linux ARM64 support), threaded SWI-Prolog 10.1.19 or newer on `PATH`, and
Node.js 22. Set `N7_NODE` to the Node.js executable if needed. Fetching the
dependencies requires Git read access to their GitHub repositories.

```sh
git clone --branch codex/n7-shell-preview --single-branch \
  https://github.com/torbjornlager/trinity-demonstrator.git eclipse-node &&
./eclipse-node/tools/bootstrap_n7.sh
```

If you already cloned the branch, run `./tools/bootstrap_n7.sh` from the
checkout root. The script fetches the pinned SWI-Prolog, SWI-WASM, and
conformance sources from GitHub and downloads the pinned ECLiPSe 7.2_13 Linux
ARM64 archive from the official ECLiPSe CLP site. It verifies the archive's
SHA-256 before running the build and checks. On a retry it reuses the pinned
checkouts and verifies any existing archive again.

The bootstrap calls `./tools/check_n7.sh` to build
`trinity-eclipse-n7:eclipse-node-dev`, test both N7 routes with a local sign-in
fixture, run conformance with a disposable SWI peer, and check the demonstrator
catalog. Run `./tools/check_n7.sh` directly to repeat those checks after setup.
Conformance reports go under the Git-ignored `.trinity/n7-local/conformance.*`
directory. The local fixtures use synthetic credentials.

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
the engine. A fresh query gets its own module. On the owner adapter, a page
with more answers leaves a continuation in the cache. A request with the
same query, source, answer format and effective template resumes it at the
next offset, even if the page size changes. The adapter keeps up to four
idle continuations and stops the oldest when it needs room. Idle time does
not expire an entry. On a cache miss, the query starts again and
skips answers before the requested offset. The isolated whitelist preview
runs each request in its own worker. Promises belong to the running query
and can be collected with `yield/2`.

The engine container has no network access. To enable cross-node RPC or
`src_uri` loading, start the host adapter with one `--allow-peer ORIGIN`
argument per trusted HTTP(S) origin. The default allowlist is empty. The
adapter makes bounded GET requests, refuses redirects, and sends no owner
credentials. An allowlisted origin can serve stateless `/call` requests and
source files.

The live N7 owner adapter allowlists N1 for RPC, N2 for source loading,
N3 for RPC and the published service, and N4 for the asynchronous RPC
examples.

### SXML statecharts

The owner ACTOR shell can validate a chart with
`statechart_validate_text(Text, Diagnostics)` or
`statechart_validate(URI, Diagnostics)`. An empty diagnostic list means the
document passed the XML and SXML 0.2 structural checks. Validation does not
run the chart's embedded Prolog. URI validation can read packaged statechart
examples or fetch from an origin configured with `--allow-peer`.

`statechart_spawn/2` validates the document before creating an actor.
Charts support hierarchy, parallel regions, shallow and deep history,
state-scoped `after` timers, and deferred events. A timer is cancelled
when its state exits. Deferred events are re-offered in arrival order
after the configuration changes and internal processing settles.

In the owner shell’s Examples drawer, try 01 (pause and resume), 06
(parallel completion), 07 (deferred events), or 12 (the timed box shop).
The same interpreter runs GCD and Jev. `statechart_halt/2–3` runs exit
actions. The timed form escalates to a kill if the actor is busy.

Examples 13–17 invoke local actors, toplevels, servers, supervisors, and
nested charts. Children start once their invoking state settles and stop
when it exits, including children created with `link(false)`. Charts loaded
by URI can resolve relative child sources.

In the owner shell, an ordinary `<spawn type="actor">` can set
`node('https://peer.example')` in its options. Add the exact peer origin to
`--allow-peer`. The peer must offer bare actor spawn on its ACTOR WebSocket.
On SWI-Prolog peers, use `terminal_output(Term)` to return a value to the
chart as `output(Child, Term)`. Each invoked actor has its own connection.
N7 closes that connection if the invoking chart exits during startup.
Toplevels, servers, supervisors, and nested charts still run locally. For toplevel children,
`time_limit` counts query execution across pages and `idle_limit` covers
waits for a call or the next page.

Example 18 runs locally. The model and Jev examples (19 and 20) require
`--allow-peer https://n3.elfenbenstornet.se`. N7 calls the protected model
capability over N3’s ACTOR WebSocket and uses HTTP RPC for Jev.

Run the local owner HTTPS regression with `tools/test_n7_https.py --shell
--actor-core /path/to/trinity-conformance/runner/run.py --advertise-actor
--sxml-documents`, using the image built from this checkout.

### Stateless whitelist preview

Start a disposable packaged adapter with the private settings from above
and add `--stateless-whitelist`. The preview serves `GET /call` under the
same owner check and exposes `GET /node_info` for discovery. Its metadata
reports `sandbox: whitelist` and `execution_policy: stateless_preview`.
It implements a subset of ISOBASE.

The engine checks the parsed goal against an explicit list of pure term
and list predicates. It checks the goal arguments of control structures
and collectors such as `findall/3`, and accepts `call/1` only when its goal
is visible at validation time. Arithmetic evaluation, module-qualified
calls, native I/O and source loading are outside the preview. Answer
templates remain data, and the engine rejects cyclic answers before
serialization. The maximum offset is 1,000.

The flag requires a compatible packaged engine and is incompatible with
shell assets, WebSockets and peer egress. To test a newly built image
through the owner admission check and the actual engine, run:

```sh
python3 tools/test_n7_stateless_whitelist.py --image trinity-eclipse-n7:local
```

Each admitted query starts a fresh container with the pilot limits. The
adapter removes it before releasing its slot. Two queries can run at once,
with at most one per client IP. Caddy strips incoming
`X-Web-Prolog-Client-IP` and sets it from its direct peer address on the
authenticated upstream request. The adapter requires the proxy credential
and one valid IP address. It ignores client-supplied forwarding headers for
admission. Clients sharing an address also share a budget.

The default rate is 60 admitted queries per address in a rolling minute.
Use `--stateless-calls-per-minute COUNT` to adjust it. Over-budget requests
receive HTTP 429 with `Retry-After` and never enter a queue. Worker saturation
does not consume the rate budget. The normal Prolog execution limit still
applies. If the worker stops responding, a separate six-second deadline covers startup
and the bridge exchange, and only that worker is removed. If Docker
cannot confirm cleanup, the adapter stops admitting new queries.

The test pauses one worker, checks that a second can answer, fills both
slots, and checks that rejected requests can retry after cleanup.
Discovery reports `request_isolation: container` in this mode. To test
the address policy through Caddy and the local OAuth fixture, use:

```sh
python3 tools/test_n7_https.py --image trinity-eclipse-n7:local --stateless-admission
```

The HTTPS test uses two Docker clients with distinct source addresses
and the same fixture owner login. It checks that forged IP headers cannot
evade either limit and that the second client retains its budget.

### Anonymous stateless rehearsal

On the existing N7 HTTPS host, import
`Deployment/Caddyfile.eclipse-n7-preview` inside the N7 site block and set
`--stateless-public-prefix /preview` on the separate preview adapter.
The import exposes only `GET /preview/call` and `GET /preview/node_info`.
Use a dedicated proxy token for this import. The existing shell and API
paths continue to use the owner login. Verify the combined site locally:

```sh
python3 tools/test_n7_https.py --image trinity-eclipse-n7:local --anonymous-preview
```

### Separate staging hostname

Use a separate hostname, loopback port, proxy token, and adapter for the
anonymous rehearsal. Start the packaged adapter as above with the staging
origin, `--port 18097`, `--owner n7-stateless-staging`, and these flags:

```sh
--stateless-whitelist --anonymous-stateless --stateless-calls-per-minute 20
```

The staging Caddy site in `Deployment/Caddyfile.eclipse-n7-staging` routes
only `GET /call` and `GET /node_info`. It supplies the adapter credential
and sets the address budget from the connection it receives. The adapter
still requires its proxy credential. Requests carrying cross-site browser
fetch metadata are rejected.

Run the staging site with fixture TLS before adding the site to the public
edge. The test exercises anonymous calls, blocked routes, direct adapter
admission, and spoofed addresses from two independent clients.

```sh
python3 tools/test_n7_https.py --image trinity-eclipse-n7:local --anonymous-staging
```

For public TLS, point the staging DNS record at the edge. Keep its Caddy
import separate from the owner site so removing the import and stopping
the staging adapter retires the rehearsal. Confirm that two external
networks receive independent budgets before opening the main N7 endpoint.

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
**Sign out of N7** in the shell header disconnects the shell, clears its N7
session, and returns to the sign-in page. Signing in again opens the full
ACTOR shell. GitHub stays signed in.

Run `python3 tools/test_n7_https.py --image trinity-eclipse-n7:shell-preview --shell`
to exercise the preview with disposable TLS and GitHub fixtures. The preview
uses the same access policy as the live shell.

### Local ACTOR WebSocket preview

The packaged adapter accepts `--actor-ws` to enable `/ws` behind the same
owner gate as the HTTP routes. The upgrade requires the configured HTTPS
origin. The WebSocket owns its toplevel sessions and closes them on disconnect.
Add `--advertise-actor` to announce ACTOR in `/node_info` and let the owner
shell select `/ws`. With only `--actor-ws`, discovery advertises ISOTOPE.

After bootstrapping the checkout, install the optional transport dependencies
in a local virtual environment. Set `N7_ACTOR_PYTHON` to add ACTOR core and
the pubsub regression to the standard N7 checks:

```sh
python3 -m venv .trinity/n7-actor-venv
.trinity/n7-actor-venv/bin/python -m pip install -r experiments/eclipse-clp/requirements-actor-ws.txt
N7_ACTOR_PYTHON=.trinity/n7-actor-venv/bin/python ./tools/check_n7.sh
```

Use the same setting with `./tools/bootstrap_n7.sh` to fetch or update the
pinned runner before checking.

The fixture signs in with a synthetic GitHub owner and tests WebSocket
admission, ACTOR core, and the existing HTTP routes. With
`N7_ACTOR_PYTHON` set, the standard checks save and validate
`actor-https.json` alongside the packaged ISOTOPE reports in the private
conformance directory. The standalone HTTPS fixture keeps its ACTOR report
in a temporary directory unless you supply `--actor-report FILE`.

To run the two-connection pubsub regression with the bootstrap-pinned
WebSocket client, select `--pubsub`. This runs the owner HTTPS fixture and
checks broadcast, unsubscribe, and disconnect without running ACTOR core.

```sh
.trinity/n7-actor-venv/bin/python tools/test_n7_https.py --advertise-actor \
  --image trinity-eclipse-n7:eclipse-node-dev \
  --pubsub .trinity/deps/trinity-conformance/runner/run.py
```

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
