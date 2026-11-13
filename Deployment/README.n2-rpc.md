# N2's RPC route to N4

N2's shared `human/1` keeps its logical peer URL,
`https://n4.elfenbenstornet.se`. Completing `mortal/1` includes that remote
lookup, so N2's four-second response deadline includes the N4 connection and
reply. An external ingress stall can exhaust this deadline even though the
local `socrates` fact was found immediately.

The Compose definition sets `WP_N2_N4_RPC_ENDPOINT=http://wp_n4:3055`.
`start_n2.pl` installs that owner-controlled mapping in N2's runtime context.
Native RPC resolves it before opening the connection or starting a promise
worker. Paging uses the same selected endpoint. Matching is exact, configuration
is scoped to its node, and callers cannot supply an endpoint override as a
public RPC option. N4's normal HTTP execution/profile/admission rules still apply.
The public query and reply terms, source definitions, four-second execution
limit, timeout errors and promise semantics are unchanged. No retries are added.

Outside Compose, an absent or empty variable preserves the public connection.
The variable accepts an HTTP(S) origin without credentials, path, query or
fragment. Other owner-controlled deployments can select their own peer origin.
Use this change with the corresponding native `rpc:hook_rpc_endpoint/2` and node
glue changes; commit and pin that native revision before preparing a release.
The current source work is not deployed or pinned as a release.

The fault qualification runs disposable copies of the deployed SWI, Trealla and
Caddy images on an internal-only network. Its public-looking hostnames and
certificates belong solely to that fixture. A stalled public N4 route reproduces
`resource_error(time)` with the old image. The candidate then runs 63 exact RPC
walkthrough repetitions through N5, including promises and N1 source transfer,
while that public route remains stalled. Only the owner-installed private route
changes; the error and watchdog deadlines do not increase. The test waits for
existing request windows rather than increasing admission limits.

```sh
python3 tools/test_n2_rpc_topology.py \
  --swi-image IMAGE_ID --trealla-image IMAGE_ID --edge-image IMAGE_ID \
  --native-root /path/to/swi-prolog-node \
  --audit-tools /path/to/eclipse-node/tools \
  --wire /path/to/pinned-conformance/runner/run.py \
  --output /path/to/new-output-directory
```

The fixture declares a development-only loader for uncommitted candidate source.
Production pinned startup validation remains intact; a dirty native checkout was
correctly rejected in an earlier fixture attempt. This test verifies the source
and failure mode, and does not qualify a new immutable release. All fixture
containers, anonymous volumes and the private network are removed afterward.
The exact network hop responsible for the older intermittent public failures
has not been established retrospectively; the fix removes that external-route
dependency for N2's known same-deployment peer.
