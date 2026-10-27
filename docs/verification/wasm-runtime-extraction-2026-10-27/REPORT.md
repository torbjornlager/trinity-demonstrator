# SWI-WASM extraction: stage 1 and 2 verification

## Result

The demonstrator now consumes the extracted in-repository runtime through an
explicit method/state and host-callback boundary. The same runtime runs in an
independent static page with no demonstrator HTML, Vue, terminal/editor widgets,
example database, or native execution service. Both browser execution models are
retained. There is no engine upgrade, dependency-pin change, new repository,
commit, push, or live-node restart in this stage.

The ownership boundary, host API and reproduction instructions are in
[SWI_WASM_NODE_EXTRACTION.md](../../SWI_WASM_NODE_EXTRACTION.md).
The extracted method inventory is in [inventory.json](inventory.json).

## Verification

| Check | Result |
| --- | --- |
| Pre-extraction `tools/test.sh WASM` | Passed |
| Final `tools/test.sh WASM` | Passed, exit 0 |
| Real-engine semantic scenarios | All 99 passed |
| Existing JavaScript assertions across WASM smoke/contract tests | All 2,803 passed both before and after extraction |
| Statechart WASM Prolog tests | All 71 cases passed |
| Statechart schema, shared algorithm and runtime-helper equivalence guards | Passed |
| New standalone host test with real Worker threads | Passed, included in WASM tier |
| Startup, packaging, pin and tooling Python tests | All 31 passed |
| Portal identity regression checks | Passed |
| Inline/module JavaScript syntax and whitespace checks | Passed |
| Generated behaviour/main-engine Prolog bridges | Byte-identical to the baseline revision |

The standalone Node and browser checks cover configured asset URLs, a host-supplied database,
source loading, paging/Stop, actor messaging, monitors, statecharts/traces, Unicode,
output/errors, input callbacks and manual input, Abort, shell recovery, failed
startup cleanup, and disposal during startup/query. No demonstrator HTML is loaded.

The browser checks used two disposable loopback servers: a static Python asset
server for the independent host, and a native server selecting the working-tree
assets for demonstrator integration. Existing live n3/n5 processes were untouched.

* Independent Worker page: source, paging, messaging, monitoring, statechart trace,
  Unicode/output, query errors and disposal all passed.
* Independent compatibility page: engine/DOM startup, host-supplied source, query
  driver and promise lifecycle all passed.
* Demonstrator Worker model: readiness, `member/2` paging and Stop; loading the
  queens example created a ready replacement before retiring its old shell, and
  `queens(4,Q)` returned `[2,4,1,3]`. Valid SXML chart startup/trace/exit also worked.
* Demonstrator main model: output and successive answers worked; after extraction
  of the source installer and query driver, RPC to the disposable native server
  returned `a`, then `b` through Next.

Browser evidence: [Worker host](standalone.png), [compatibility host](standalone-main.png),
[demonstrator main/RPC](demonstrator-main.png), with adjacent accessibility captures.
Local tool versions, source hashes and run counts are in [results.json](results.json).
Raw final WASM output is in [wasm.log](wasm.log); focused standalone, bridge and
Python outputs are retained alongside it. Original baseline output is retained
locally under `.trinity/wasm-extraction/baseline.log`, with its hash in results.json.

## Remaining boundary

The new session convenience API uses Workers. Main-thread compatibility retains
its existing page-global bridge callbacks; it is not a multi-instance main-engine
API. The demonstrator still selects remote endpoints and supplies tutorials,
examples and shared data. Whole-application static packaging, CDN deployment,
versioned release adoption and installation remain later stages.
