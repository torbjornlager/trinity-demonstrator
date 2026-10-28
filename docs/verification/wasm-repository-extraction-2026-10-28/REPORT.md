# SWI-WASM repository extraction — 28 October 2026

The runtime now lives in the private
[swi-wasm-node repository](https://github.com/torbjornlager/swi-wasm-node),
source commit `278042d4f5928c35cacfe267fe6bd7f83013533f`, tagged `v0.1.0`.
The source commit and tag were published through GitHub Desktop. The
[release workflow](https://github.com/torbjornlager/swi-wasm-node/actions/runs/40644234086)
passed its package and release jobs. The
[published archive](https://github.com/torbjornlager/swi-wasm-node/releases/tag/v0.1.0)
has exactly the same SHA-256 as the locally tested archive.
See [publication evidence](published-release.png).

The demonstrator selects this clean package through an exact source revision and
manifest SHA-256. Runtime/Worker/engine/Prolog paths are tracked relative symlinks
into the validated package. Their public URLs are preserved. Runtime tests live
upstream; seven presenter cases and 11 Prolog example cases remain consumer-owned.
Two pure chart lifecycle methods moved into the runtime; language and engine
versions are unchanged.

## Package verification

- Four package-tooling tests passed.
- Two clean builds produced byte-identical tar.gz archives.
- The committed package passed 95 runtime cases, 60 Prolog cases, schema and
  algorithm equivalence, mailbox and real-engine standalone tests.
- The archive was unpacked outside both source repositories and tested using its
  own tools. All 94 portable runtime cases and 60 Prolog cases passed. The optional
  native serialization fixture was explicitly unselected in that independent run.
- The complete static web tree worked beneath `/release/0.1/`: Worker messaging,
  monitors, statechart lifecycle, source loading, paging, Unicode/output,
  query-error recovery, disposal and main-engine source/query/promise checks.

See [runtime/native results](runtime-native-results.json),
[portable results](runtime-portable-results.json), and
[exact pins and archive digest](provenance.json).

## Demonstrator verification

The full local CI boundary passed all 31 check groups, including native
tiers, consumer tiers, startup/packaging regressions and the final WASM tier.
See [full CI results](full-ci-results.json).

- The WASM tier passed all 102 semantic cases (95 runtime + seven presenter),
  60 runtime Prolog cases and 11 consumer example cases, schema equivalence,
  Worker mailbox, RPC bridge and independent host checks.
- All 39 Python startup/tooling tests passed, including eight new package and
  alias drift checks. Portal runtime identity checks passed.
- A fresh consumer copy outside the source checkout rebuilt and validated the
  pinned package without a copied runtime cache.
- A disposable native node served the switched assets. Worker queries paged
  correctly, Stop worked, and loading `01 queens.pl` replaced the shell and
  returned `Q = [2,4,1,3]`. Main-thread mode also loaded and ran the example;
  RPC to the disposable native node returned and paged both answers.

Browser evidence: [independent package](standalone-package.png),
[Worker example](demonstrator-worker.png), [main-engine RPC](demonstrator-main-rpc.png),
and [main-engine example](demonstrator-main-example.png).

The test tabs and disposable servers were closed. Live n3/n5 deployments were
not changed. Full demonstrator CDN distribution remains a later stage.
