# Model/Jev text-boundary migration — 2026-10-25

The demonstrator application candidate now accepts character-list text without
turning provider text into JSON arrays. This closes the model/Jev input guards
identified by the preceding portable-text migration audit. Default reading
remains unchanged; the experimental configuration is still opt-in.

## Behaviour and scope

- Public model/Jev prompts accept native SWI strings or proper lists of
  one-character atoms. Numeric code lists, atoms, partial/cyclic lists and
  multi-character elements are rejected; validation does not bind input variables.
- `examples/example_text.pl` centralises the application/native conversions.
  Model conversation content, Jev question descriptions and deployment message
  text become native strings before JSON encoding. Owner endpoint/key and Jev
  question/model identifier conveniences retain their existing atom/string forms
  and additionally accept character lists.
- Model `answer(Text)` and Jev score legends follow the selected language text
  configuration. Standalone library use retains native strings. Raw
  `provenance(Raw)` and arbitrary JSON state retain their native JSON types:
  in particular, an empty string remains distinct from an empty array.
- Responses are decoded from UTF-8 bytes after the existing byte-size check.
  Unicode mocks exposed the previous byte-as-character decoding error. This
  repair does not claim strict malformed-UTF-8 validation.
- Actor example 21 and statechart example 19 accept both text forms and retain
  complete history pairs. The actor's copied predicate set includes the new
  character checks. Book examples are unchanged.

The fixed endpoints, owner-only configuration, sandbox boundaries, request
admission/cooldown, cancellation and timing policies are retained. Public
prompts remain nonempty and at most 500 characters; model conversation limits
remain 1/3/5 alternating messages, 1500 characters per assistant message and
2000 characters total. Histories retain at most two complete exchanges within
1500 characters. Model responses retain the 16384-byte and 4000-character caps;
Jev retains its configured response-byte cap. No provider is contacted and no
real API key is used by the checks.

## Results

| Checks | Default strings | Experimental character lists |
| --- | ---: | ---: |
| New service text regressions | 25/25 | 25/25 |
| Existing model service suite, assertions unchanged | 11/11 | Not rerun as a character-list specification |
| Existing model statechart suite, assertions unchanged | 6/6 | Not rerun as a character-list specification |
| Existing Jev suite, assertions unchanged | 17/17 | Not rerun as a character-list specification |

The 25 selections cover strict/nonbinding validation, empty and Unicode prompt
limits, mixed conversation types and limits, request JSON types, selected reply
types, raw JSON fidelity, response byte/content caps, history trimming, copied
actor helpers, statechart execution and owner endpoint/key text. Two selections
use real public WebSocket goal/source readers with the actual model actor and
statechart assets, double-quoted Unicode prompts and exact selected-mode replies.
These are protocol-level UI-path checks; no graphical browser automation was
performed. Both public fixtures wait for halt acknowledgement before closing.

The pre-existing default test files are byte-identical to their committed
versions. They contain native-string-specific assertions, so the character-list
claim rests on the new exact-type regressions, rather than broadening old
assertions. This is application migration evidence, not a new cross-runtime
conformance total or a claim of Trealla/WASM service support. Live-provider
quality, latency and availability were not tested.

## Reproduction and fixture isolation

Run `python3 docs/verification/model-jev-text-2026-10-25/run-existing.py` from the
demonstrator checkout. The runner loads the explicit native SWI candidate in a
temporary tree, copies the tests and examples, and gives that tree its own asset
root. It bypasses the demonstrator's older dependency pin only inside the test
fixture. Production startup and the pin remain unchanged. Physical asset copies
preserve the existing asset containment policy; symlinking assets outside the
fixture root would be an invalid same-node URI fixture.

`tools/test.sh` also registers the new `SERVICE_TEXT` group for normal test runs
once an appropriate native dependency is selected. Logs and commands are in
[existing-checks.json](existing-checks.json); preservation, input hashes and
selection counts are in [verification.json](verification.json).

## Preserved state and remaining work

The verification snapshot confirms unchanged native Prolog sources, Trealla
sources/libraries, engine binaries, dependency pin and all four protected live
process identities/start times. Regular n3/n5 and installed runtimes were not
restarted or modified. The book is untouched. Earlier unrelated pending repairs
and historical reports are preserved; temporary debugging traces were removed.

The native README and cumulative coverage rollup link this follow-up without
rewriting historical failures. A controlled adoption checkpoint remains separate:
this batch does not enable character-list reading on regular n3, roll repaired
application files into its frozen source tree, or resolve the separate cyclic
exception/actor-message and broader portable-text diagnostics.
