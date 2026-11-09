# Portable Web Prolog Core 0.1 Draft

This profile defines the initial common language and term exchange rules for
SWI-Prolog, SWI-WASM, Trealla, GNU Prolog, and ECLiPSe CLP. A runtime can qualify
for the core independently of its node capabilities. ISOBASE, ISOTOPE, and ACTOR
continue to describe the public surfaces a node offers. The qualification
target is observable Web Prolog behavior. Direct engine probes help locate
differences, and ISO examples provide cases for that comparison.

## Term and query rules

- Portable data consists of finite, acyclic terms built from atoms, numbers,
  variables, lists, and ordinary compounds with at least one argument.
  The initial numeric range for integers is −9,007,199,254,740,991 through
  9,007,199,254,740,991 so they also fit exactly in JavaScript numbers. The
  current floating-point fixture covers `1.5`. The wider floating-point
  contract needs a separate selection.
- Write lists in bracket notation, including `[]` and `[Head|Tail]`. Decode
  answer payloads independently of variable names. Repeated variables in one
  payload must remain shared and distinct variables must remain distinct.
- At the public language boundary, double quotes denote lists of one-character
  atoms. The empty literal denotes `[]`. A supplementary Unicode character
  occupies one list element. Native library string objects and attributed
  variables require application-level conversion before portable exchange.
- A cut inside a meta-call is local to that call. Existing Web Prolog
  guarantees for results, failure, and exceptions continue to apply.
  A malformed goal in a transparent conjunction raises a callable type error
  for the submitted conjunction. A negation checks its argument when execution
  reaches it. In the gate, `call((fail,1))` raises, `call((fail,\+1))` fails,
  and `call((true,\+1))` raises with `1` as the culprit.
- A paged query that produces answers before an application exception
  delivers those answers before delivering the exception. The RPC client
  preserves variable identity in the page and raises the original exception
  when it asks for the next answer.

### Ambiguous and extended terms

For this draft, reserve dotted list notation for explicit import from peers
that use it as a list constructor. A native value that the sender distinguishes
from a list but a receiver would read as a list is outside the portable subset.
Examples are SWI's distinct `'.'/2` compound and its atom `'[]'`. A portable
sender should reject these before serialization. It should likewise reject
zero-arity compounds such as `f()`. The rejection is
`error(representation_error(portable_term), _)` when the engine can construct
the value and the node is asked to encode it. A reader can report a syntax
error for source it cannot parse.

## First qualification

| Surface | Result |
| --- | --- |
| Direct engine probes | 15 of 15 required observations across five engines |
| Loopback `/call` | 16 of 16 required observations across four native nodes |
| Answer replay | 32 of 32 checks across all ordered HTTP node pairs, including self. Each receiver parses the actual sender's answer through `src_text` and checks the reconstructed term. |
| SWI-WASM Worker and main thread | Existing character-list and asynchronous-answer scenarios passed in both modes. These use the real WASM engine under a Node test coordinator. |

The replay covers ordinary data, including the two integer endpoints, and
variable identity. The Unicode query checks the decoded character list by
equality inside each node. Atom quoting can legitimately vary in the written
answer. The selected cases do not qualify every wire payload, predicate,
transport, or advertised capability. [Recorded matrix](verification/portable-core-2026-11-09.json)

## Candidate node changes

The native SWI, GNU, and ECLiPSe node changes and the existing Trealla behavior
pass all three required meta-call cases over HTTP. Native SWI also passes the
three wire rejection checks. All 32 answer replays still pass. The browser
Worker and main-thread candidates pass the same call and wire cases. The
browser checks also cover cut scope, compiled source, and copying that source
without leaking the call wrapper. The direct engine observations can still
differ because the fixes are in the node execution paths.
[Candidate HTTP and engine matrix](verification/portable-core-node-candidate-2026-11-09.json)

The first candidate runs used the baseline inputs below with local changes
in the SWI, GNU, ECLiPSe, and browser runtime worktrees.

## Release gate

The gate runs real `rpc/3` calls between separately listening nodes. Source
submitted to the peer yields an answer with shared and distinct variables,
then throws a tagged application exception. Each caller verifies the
bindings before it advances to the exception. Limits 1 and 2 exercise
both a full page and a short page. All 24 ordered checks pass.

Retained checks load source at session creation, collect a short page,
receive the original exception on continuation, and run another query in
the same session. All three checks pass across SWI and Trealla WebSocket
sessions and ECLiPSe HTTP sessions. The same release run retains the
31 core HTTP checks and 32 answer replays.
[Release matrix and exact source revisions](verification/portable-core-release-2026-11-09.json)

The SWI, SWI-WASM, GNU, and Trealla manifests select the published
`portable-core-0.1` commits. ECLiPSe uses a separate release branch and a
locally verified N7 image.
[ECLiPSe release branch](https://github.com/torbjornlager/trinity-demonstrator/tree/portable-core-eclipse-0.1)

The malformed-output `sort/2` and invalid-list `length/2` cases remain
diagnostic until their exact outcomes are selected for Web Prolog. Diagnostic
rows preserve the observations and any reference outcome separately from
the required pass count.
[SWI7 and ISO Prolog](https://www.complang.tuwien.ac.at/ulrich/iso-prolog/SWI7_and_ISO)
· [Length comparison](https://www.complang.tuwien.ac.at/ulrich/iso-prolog/length)

## Run the probes

Select any installed engines and start the HTTP nodes as disposable loopback
fixtures. The HTTP runner uses the existing Trinity conformance checkout
next to this repository by default. Use `--conformance-root` to select a
different checkout. For fixture setup, see the existing
[baseline launcher](https://github.com/torbjornlager/trinity-conformance/blob/main/docs/BASELINE_RUNNER.md)
and the [ECLiPSe adapter guide](../Deployment/README.eclipse-n7.md).
The ECLiPSe engine option takes a local ARM64 N7 image and launches its
interpreter with networking disabled.

```sh
python3 tools/probe_portable_core.py \
  --swi swipl --trealla /path/to/tpl --gnu /path/to/gprolog \
  --wasm node --eclipse trinity-eclipse-n7:local \
  --http swi=http://127.0.0.1:18081 \
  --http trealla=http://127.0.0.1:18082 \
  --http gnu=http://127.0.0.1:18083 \
  --http eclipse=http://127.0.0.1:18084 \
  --report /tmp/portable-core.json
```

The four ports are examples. An engine or node omitted from the invocation
has no result row. Required assertion failures and unavailable diagnostics
produce a nonzero exit. The `replay` section lists the sender and receiver
for every check. Pinned CI runs the direct SWI and SWI-WASM core probes. For
candidate HTTP nodes, add `--require-node-call` to gate the three call cases
on every selected node, and `--require-wire-rejection swi` to gate rejection
on the selected SWI node.

For the full release gate, start the four native HTTP fixtures with the
other loopback origins allowlisted for RPC on GNU and ECLiPSe. Add
`--release-gate` to the command above. The gate requires all four named
nodes and selects their retained transports.

The two browser modes use the pinned runtime's existing boundary tests.
Run these after [setting up the pinned dependencies](../README.md#native-dependency-architecture).

```sh
for test in portable_text_worker portable_text_main \
            asynchronous_answers_worker asynchronous_answers_main; do
  node tests/wasm/swi_wasm_contracts.js "$test" || exit
done
```

### Recorded fixture inputs

The 9 November 2026 run used native SWI and SWI-WASM 10.1.19, native node
`139f32f9ea59ec08ec701070a888a3f6de935e10`, and browser package
`65f94c761796b9b963605c33ad9767e3dd905137`. It used Trealla 3.14.20 with port
`696323089baa3cd3c0764d4c6e0035d1242d0cbd` and GNU Prolog 1.6.0 with the
local ISOBASE binary SHA-256
`cb119c2cdff7872f75aad70e6404c49a68c1d9d71ead464baa75554e77f4aeff`.
The ECLiPSe interpreter came from the local `trinity-eclipse-n7:appendix-b11-local`
image. The ECLiPSe loopback adapter used revision
`f6ee095b54bc5691c3c1524bbc757b0eae7afbba` and the Linux ARM64 archive
SHA-256 `7599e154cca23b5601ed133df2f0481c43baf115b8cd6d7757795729d815e0d5`.
HTTP framing and fixture-term comparison used the conformance runner at
`5e4ecdd92a4f7e3eaa80c86a598809ab6be9801c`.
