# N5 execution routes and WebSocket candidate

Source preparation only: no live service or existing immutable release changes.

N5's owner launcher reads `WP_PEER_RPC_ENDPOINTS_FILE`, a file containing one
Prolog list of public-origin/private-endpoint pairs. The image-baked example
`n5-peer-http-endpoints.example.pl` selects native N1 and N2 backends. The
Trealla Compose overlay installs that map. These are execution destinations;
`WP_LOAD_URI_ORIGIN_ALIASES` remains a separate asset-loading map. In particular,
N5's source alias serves N3's static assets and must never route N5 execution.

Trealla resolves the owner endpoint before starting an RPC or promise worker.
Paging retains that selected endpoint. Default ports normalize to the same exact
origin; lookalike hosts do not match. Malformed files or duplicate origins fail
startup without exposing their contents. An invalid reload retains the prior
map. Client queries cannot supply this option or call the configuration module
through the sandbox. There are no retries, enlarged timeouts or changed public
permissions. Unconfigured installations keep the public route.

N1 keeps its 60-call/minute limit. Audit clients budget 50 calls/minute across
both lanes and inspect raw result terms. The same-image quota control confirms
that request 61 returns a Prolog rate-limit error with HTTP 200.

The WebSocket relay candidate retains each relay's private actor module but
skips the application shared database for that internal actor. Public actors
still receive their independent shared and private source database. Full actor
bootstrap text is formatted into reclaimable characters from a constant template
instead of generating large atoms for each module. This reduces measured
connection memory growth; it does not establish the cause of an older 502.

Run the Trealla unit suite with `tools/test.sh unit` in its runtime repository.
`tools/test_public_ws_n1.py --help` describes the isolated image arguments.
It creates an internal-only Docker network, real TLS/Caddy/Nginx and exact
runtime images, reproduces a stalled public N1 RPC route, overlays candidate
source in its disposable N5 container, and checks source transfer and delayed
promises at original deadlines and quotas. Every owned container/network is
removed in cleanup. Evidence includes failed runs; it is never automatically
retried or relabeled as passing.

Before release, commit and coordinate runtime/shared dependency pins, build a new
immutable image and qualify it with the current proxy and rollback procedure.
The source-overlay fixture is not an immutable release or deployment approval.

Follow-up startup tracing found the relay entry arriving as
`actors:relay_start(...)`. The candidate now explicitly retains `web_prolog`
execution context and waits for relay initialization. Startup and welcome waits
observe relay termination and clean up their monitors, so an exited relay cannot
leave the reader waiting for an impossible ready message.

Use the same isolated fixture arguments with `--relay-fault` for a controlled
relay failure during `transport_hello`. The old image reaches its ten-second
client watchdog. The candidate returns the ordinary
`existence_error(websocket_relay, Pid)` error frame immediately and closes, with
no retry or increased deadline. The fixture records both expected failure stages;
it never deploys its injected source. Normal mode retains its N1/promise checks
and 400 additional TLS handshakes.

The historical public 502 occurred before HTTP 101 and remains a separate,
unproven incident. The earlier unchanged-live run also retained four remote-query
watchdog failures. Neither is cleared by the relay-startup fix or the isolated
candidate checks. The exact cause of the old one-off welcome stall cannot be
reconstructed from its client-only log, but the two concrete startup defects and
the dead-relay hang now have regression coverage.
