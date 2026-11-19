# HTTP context fixes deployed — 19 November 2026

The production dependency pins now select native SWI `a2ff186`, Trealla
`3a5b761`, and browser package `ce96659`. All six SWI services (N0–N4 and
admin) and Trealla N5 were upgraded and passed the post-cutover smoke tests.

Fresh stateless HTTP requests have separate promise ownership even when their
credentials match. Explicit retained WebSocket/HTTP sessions preserve client
state across queries; OPEN exercises still require no login. Ordinary actor
names remain client scoped. SWI retained HTTP sessions expose ISOTOPE; actor-name
isolation is checked through the ACTOR WebSocket API.

Native actor retirement retains the creating node's context through registry
cleanup and monitor notification. Internal linked-child teardown follows the
recorded dependency; public `exit/2` retains its admission checks. These repairs
resolve the parallel, fridge and statechart fixture timeouts without changing
the teaching algorithms.

## Qualification and live verification

- All 34 pinned consumer CI groups passed locally; GitHub CI passed both jobs.
- The packaged browser passed all five selected groups, including native schema
  integration. Its engine and runtime code are unchanged; this release updates
  native schema provenance.
- All 34 visible OPEN entries passed all 136 checks with the production pins.
- The exact SWI and Trealla deployment images each passed the 45-case ACTOR
  release gate with two separate execution-only principals.
- The exact SWI image passed anonymous fresh-request and retained HTTP controls.
- The live run repeated those HTTP controls, all 30 parallel/fridge query checks
  across N3 and N4, HTTP visitor ownership, N1/N2 HTTP conformance, N0 discovery,
  N3/N4 actor core, creation, callback context, links/monitors, URI and naming
  conformance, Linda, N3→N4 actor transport, N5 naming/core/Linda/interop, and
  N5/N7→N1 plus N5/N7→N2→N4 RPC. The 32 smoke groups include 157
  passing versioned conformance cases, in addition to the seven HTTP context
  controls and 30 focused live exercise queries.

[Verification summary](verification.json), [GitHub CI](ci.json),
[deployment journal](journal.json), [live smoke groups](smoke/live-results.json),
[N5 groups](live-smoke-summary.json), [live HTTP controls](smoke/http-context.json),
and [live exercise sequences](smoke/live-exercises.json) retain the observations.
The local [OPEN sweep](open-exercises/results.json),
[pinned consumer results](pinned-ci/results.json), and
[browser qualification](browser-tests/results.json) record release inputs.
The local consumer run began before the pin commit and records predecessor
HEAD `2c4283e`; its manifests selected the new dependencies. The clean published
commit `2b58804` passed both CI jobs before cutover; the
[CI results](ci-artifacts/results.json) and [CI provenance](ci-artifacts/provenance.json)
record that qualification separately.

## Deployment and rollback

Immutable candidates overlay committed sources onto the captured running images.
SWI remains 11.0.0, Trealla remains 3.14.20, and the browser engine remains
10.1.19. Each engine tree matches its predecessor byte for byte. Runtime settings,
credentials, commands, limits, mounts, network aliases/static addresses and
read-only owner/peer payloads were compared after cutover. Existing data volumes,
Caddy and unrelated Compose services were preserved. N6 and N7 runtimes were
not replaced; their RPC consumer paths were exercised.

The frozen operator checks exact predecessor identities and release evidence,
deploys with health checks, and restores changed services if any smoke fails.
An isolated rehearsal injected a health failure and verified predecessor
restoration and retained state without production volumes. No live rollback was
needed. The selected host models and SWI/N5 pointers now identify the new images.

The preparation directory and explicit rollback command are in
[verification.json](verification.json). Keep these local immutable images,
models, snapshots and data volumes available for rollback. Private models and
logs retain credentials and are not included here. Operator source is preserved
under [operators/](operators/deploy.py); its seal hashes and all exported evidence
are covered by [files-sha256.json](files-sha256.json).
