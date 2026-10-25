# Main-thread SWI-WASM output flushing — 2026-10-25

## Cause and repair

`write("abc")` correctly denotes and writes `[a,b,c]`, but the WASM engine keeps
non-newline output in Prolog's stream buffer. The main-thread driver presented
answers without flushing that buffer. Its JS output buffer was therefore empty.
The Worker terminal already flushes Prolog streams before answer delivery and
needs no change.

The main-thread driver now wraps its original lazy runner in cleanup. It flushes
`user_output` and `user_error` after capturing each answer's deterministic flag,
before notifying JS of that answer, and before exception reporting. Cleanup also
flushes on failure, cut or interruption. Flush exceptions are suppressed so they
cannot replace the original query error. Global stream buffering and output
routing remain unchanged. The original goal/choicepoint handling and lazy next
promise remain intact.

Base commit: `3a84a7a72de8d06fa286cb5b6f995682c84cad0a`, plus this working-tree
repair. No native runtime, pin, installed engine, launcher or running node changes.

## Regressions

The real-engine `compatibility_output_ordering` scenario in
`tests/wasm/swi_wasm_contracts.js` records actual `on_output` callbacks alongside
answer, exception and lazy-wait events. It does not substitute output capture
into a temporary string stream, which would hide the reported problem.

It checks character-list and atom writes, newline output and stderr, exact output
before answers, final deterministic flags, failure output before completion,
output before the original exception, first/second-page output without premature
execution or duplication, and no stale output in the next query.

[Before repair](before.log) reproduces the missing-output failures;
[after repair](after.log) passes all 15 assertions. The engine emits its expected
`Unknown message: test_error` diagnostic while formatting the deliberately thrown
atom; the original atom still reaches the test's rejection handler.
The complete WASM tier is recorded in [WASM.log](WASM.log), with its final exit
status in `results.json` after completion.

## UI verification

The browser used a disposable origin at `http://localhost:53737`, backed by the
verified SWI launcher and candidate demonstrator assets. Settings selected
**Main thread + DOM**. No requests or restarts targeted n3/n5.

| Query | Observed terminal order |
| --- | --- |
| `write("abc").` | `[a,b,c]`, then `true.` |
| `write(failed),fail.` | `failed`, then `false.` |
| `write(before_error),throw(test_error).` | `before_error`, then `Test_error` |
| `member(X,[a,b]),write(X).` | `a`, then `X = a`; after explicit Next: `b`, then `X = b.` |

[AX transcript](ui.txt) and [screenshot](ui.png) retain the visible results.
The temporary browser tab and server were closed; see [fixture record](ui-server.json).
[Preservation checks](preservation.json) confirmed exact n3/n5 process identities,
launcher hashes and runtime selection against the preceding migration record.
The running portal continues using its committed assets until separately adopted.
