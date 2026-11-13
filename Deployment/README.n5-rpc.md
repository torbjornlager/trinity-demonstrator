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

Qualification retains one unexplained early candidate welcome timeout after HTTP
101. Later untraced runs, including 80 queries and 400 TLS handshakes, passed.
The historical public 502 was premature backend closure; pressure tests show
reduced memory growth but did not reproduce that closure. The unchanged-live
rerun still has four remote-query watchdog failures. These limitations must
remain in release review; passing reruns alone do not establish their cause.
