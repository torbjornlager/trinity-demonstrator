# Prompt examples and timeout results — 12 November 2026

The manual's contract is correct: actor input emits `prompt(Pid,Ref,Prompt)`;
answer with `respond(Pid,Ref,Value)`. Keep both the actor and the fresh reference.
A stale reference cannot answer another prompt. A term such as
`prompt_ref(literal,payload)` is an ordinary prompt payload, not an envelope.

The live N3 transcript combines two old pieces. N3 runs native revision
`55af1efe68a3018c18f9fadc1764327f9ee4f946`, which emits the older nested envelope;
its served tutorial still calls `respond/2`, although that runtime exposes
`respond/3`. N4 and N5 also serve the old expert example. Renaming an arity alone
would leave the event shape wrong. The editable shared source had already been
corrected in `cb1ebe9`, and native/Trealla pins in `74c23c4` support the flat API.
This repair additionally matches the tutorial prompt against `$Pid`.

Example 19 now returns `timeout` explicitly and exposes the reference in
`asynch_test_2(Answer,Ref)`. Its sample collects the eventual result in the same
query, since ECLiPSe retires pending promises when a query ends. The expected
values are `Answer=timeout` and `Later=success([a],false)`. The runtime behavior
of `on_timeout(fail)` remains an exception:
`error(timeout_callback_failed(Ref),_)`. No RPC error semantics were changed.

Verification found two missing runtime changes. Editable ECLiPSe now correlates
local actor prompts by default (explicit internal legacy negotiation remains).
Editable SWI-WASM now exports `respond/3`, emits flat actor prompts, matches
replies by reference, and carries that reference through its terminal bridge.
Its external worker and compatibility implementation were both updated.
These ECLiPSe and SWI-WASM candidates have not been deployed or added to shared
dependency pins. The existing SWI-WASM pin still lacks this correction.

Six focused cases pass on each of SWI, Trealla, ECLiPSe and real SWI-WASM Worker
threads: the actual tutorial snippets; stale replies and a literal prompt_ref
payload; deterministic expert conversations including backtracking and private
fact isolation; both teaching simulations; explicit timeout followed by retry;
and the failed timeout callback followed by retry. The gate holds the remote
request until the test observes the timeout, avoiding a timing-only assertion.
Only the peer URL is substituted in the test copy of example 19.

The reusable driver is `tools/test_actor_examples.py`. It reads a private JSON
configuration naming already running isolated fixtures:

```json
{
  "gate": "http://127.0.0.1:45000",
  "nodes": [{"name":"SWI", "ws":"ws://127.0.0.1:45001/ws",
             "origin":"http://127.0.0.1:45001", "peer":"http://gate:8080"}],
  "wasm_package": "/absolute/path/to/development-package"
}
```

The gate implements `/reset`, `/release`, and blocked forwarding of `/call` to
an isolated native peer. Nodes can supply `headers` and `source_field:true`
(ECLiPSe). Keep synthetic credentials in the private configuration. Run:

```sh
python3 tools/test_actor_examples.py --runner /path/to/runtime-contracts/runner/run.py \
  --config /private/fixtures.json --report /private/results.json --node /path/to/node22
```

ECLiPSe also passes all 247 language cases and the isolated owner HTTPS suite,
including negotiated/unnegotiated prompts and stale-reference rejection.
The unmodified pinned `8f72a69` conformance runner passes six core cases but
AC-007 still calls `respond/2`; its failure is retained. A separate copied
runner adapts only AC-007 to the manual's flat event and `respond/3`, and passes
all seven. This is not a claim that the unmodified runner passes. SWI-WASM's
standalone suite passes; its semantic suite's remaining scenarios pass, with
the reader fixture rerun successfully after teaching its mock to mint and
return the prompt reference.

Machine-readable results, source hashes and preservation checks are in
`docs/verification/prompt-examples-2026-11-12.json`. All changes remain editable;
no commit, push, pin change or live rollout was performed. The live transcript
will keep failing until a coordinated runtime and shared-assets release.
Live containers, N7's owner boundary, four sealed releases, branch refs, saved
stashes and unrelated Eclipse security work were preserved.

## Pinning follow-up

The verified repairs are now being committed and packaged for coordinated
rollout. The shared browser pin selects the clean `c2afe45` package; its native
schema provenance matches the existing `89a2809` dependency. The conformance
runner's new `34557d3` commit accepts the flat prompt contract and retains old
forms for rollback checks. Historical results above describe the earlier
editable-source verification. Live services remain unchanged.
