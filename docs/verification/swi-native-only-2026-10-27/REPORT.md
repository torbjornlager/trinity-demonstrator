# Native-only dependency migration — 27 October 2026

The demonstrator no longer maintains a native SWI implementation. Seventy
native Prolog files, the native pack metadata and obsolete extraction helpers
were removed. Five browser-specific Prolog modules remain; their shared SXML
schema is assembled from the pinned dependency during setup.

## Dependency and publication order

The selected native commit is `470f20b07f3157b07c8861d10610f2b73cd7efd8` on
`codex/supervisor-monitor-test-waits` in the sibling `swi-prolog-node` checkout.
Its parent `3ac61c2488431859a6107f082e7be7352faafd8d` supplies the current committed
runtime fixes required by the demonstrator's statechart tests and browser port.
The old demonstrator pin `abbc56f` predates those fixes and fails their assertions.

The final native commit changes only two test files, not runtime code. It is
local at preparation time: **publish that native commit before publishing or
building the demonstrator with the new manifest**. Repository visibility and
credentials were not changed. Existing frozen local n3/n5 launchers were not
switched to this checkout or restarted by this migration.

## Changes

- All startup paths require validated `swi-prolog-node` setup; the old legacy
  selection fails explicitly. `run.pl` uses the native API's integer port form.
- Tiered tests and benchmark imports resolve the external library without
  preloading higher layers. The standalone native graph tool owns layering checks.
- Browser/native equivalence and both browser execution modes use the same
  assembled schema/payload directory. No committed native schema remains here.
- Automatic native and browser CI jobs check out the exact manifest commit.
- Both Dockerfiles fetch that same commit, validate it, assemble browser files
  and check startup. Optional read credentials use a BuildKit secret; no token
  is stored in Git configuration, build arguments or the build context.
- Two tests that required native and browser files in one package were retired.
  Explicit asset relocation, missing-file/no-fallback and request-path checks
  remain; foreign-directory startup now also checks manual and schema resolution.

## Supervisor fixture repair

Initial native and consumer T3 runs intermittently failed in restart/intensity
fixtures. They used `timeout(0)` to poll a second monitor notification immediately
after receiving the first. Notifications are delivered independently; the first
message does not imply that another monitor's message has arrived.

A disposable diagnostic delayed each system down-message delivery by 1 ms.
The original fixtures failed at these polls ([before](supervisor-delivery-before.log)).
Replacing only the two poll deadlines with bounded one-second waits preserved
all message, exit-reason, cleanup and restart assertions and passed the identical
diagnostic ([after](supervisor-delivery-after.log)). No arbitrary sleeps were
added to the tests or runtime. The authoritative test fix is committed in the
native repository and mirrored in the retained consumer fixtures.

## Verification

All 30 check groups have passing results, with one unchanged fresh-process
retry required for consumer T3. The [initial full run](initial-results.json)
retains that failure; [results](results.json) identifies the retry explicitly.
The run configuration is recorded in [provenance](provenance.json).
The runner validates setup and module origins before executing native tiers,
external-asset integration, retained consumer tiers, service examples, Python
regressions, shared statechart equivalence and the full WASM suite.

The first final-pin consumer T3 run encountered a one-off standard-library
`sgml:select_option/3` autoload error at its first XML parse; subsequent XML tests
in that process passed. The identical full consumer T3 command passed on an
unchanged fresh-process retry ([retry log](consumer-T3-recheck.log)). No assertion
was skipped and no XML-library workaround was added. The [original result](consumer-T3-initial.log) is
retained separately from the retry rather than reported as a clean single run.

An additional temporary SWI-Prolog 10.1.19 node served the portal, manual,
ACTOR tutorial, native shared schema and browser interpreter, and returned the
expected HTTP query answers ([HTTP smoke](http-smoke.json)). Both benchmark
modules load against the external package. Python sources compile, shell syntax
checks pass, YAML parses, and `git diff --check` is clean.

Docker is not installed on this host, so an actual image build/run is unverified.
The official `swipl:10.1.19` image manifest was checked successfully. An image-like
export regression verifies startup using only browser sources in the consumer
tree and a separate native checkout. Actual private dependency checkout in
Actions/Docker still requires owner-provided read access, as documented.

## Reproduction

```sh
python3 tools/setup_swi.py --native-root /path/to/pinned/swi-prolog-node
SWIPL=/path/to/verified/swipl PATH=/path/to/node/bin:$PATH \
  python3 tools/ci_pinned_swi.py \
  --native-root /path/to/pinned/swi-prolog-node \
  --output /fresh/path/results
```

The recorded local engine is the separately verified official SWI-Prolog 10.1.19
installation; Node.js is 24.19.0. Actions selects Node.js 22 independently.
