# Portable JSON

`examples/portable_json.pl` is ordinary client source, with no module or engine
extension. Load it alongside an application using the existing source-loading
API. Its character-list codec is `portable_json_chars(Value, Chars)`: a supplied
character list is parsed; otherwise a supplied ground value is encoded.
`portable_json_value/1` validates a value, `portable_json_object/1` validates an
object, and `portable_json_get(Object, Key, Value)` returns the first matching
property. Select a key with an atom, character list, or `string(Codes)`.

| JSON | Portable term |
| --- | --- |
| Object | `json([string(KeyCodes)=Value, ...])` |
| Array | `[Value, ...]` |
| String | `string(Codes)` |
| Boolean | `@(true)` or `@(false)` |
| Null | `@(null)` |
| Number | Finite Prolog integer or float within the engine's range |

`Codes` contains Unicode scalar integers. Thus the empty array `[]`, empty
string `string([])`, and text `"[]"`, `string([91,93])`, remain distinct. A NUL
string is `string([0])`. Code lists also preserve text on GNU Prolog, whose atom
storage cannot represent a NUL character. Bare native strings, SWI dicts and
the SWI-specific atom `'[]'` never cross this boundary.

The codec preserves property order and duplicate keys. It accepts JSON escapes,
combines UTF-16 surrogate pairs into scalar values, and rejects lone surrogates,
raw controls, invalid numbers, trailing commas and trailing input. Numbers use
the receiving engine's numeric precision; their original spelling is not kept.
Encoding requires ground, acyclic JSON values. Invalid syntax raises
`error(syntax_error(json),portable_json_chars/2)`; invalid supplied values raise
a domain error. Validation predicates fail for invalid terms.

`examples/portable_json_swi.pl` supplies host-only adapters:
`portable_json_from_dict/2`, `portable_json_from_classic/2`, and
`portable_json_to_classic/2`. The latter two interoperate with SWI's classical
`json([Name=Value,...])` representation, with atom strings and wrapped literals.
Native dict-mode booleans/null become wrapped literals; atom strings in classic
mode remain text. No array is guessed to be a string. Jev's typed legend is a
known text field, so its language text is explicitly converted before applying
the generic JSON adapter.

The node-owned Jev service normalizes all four JSON metadata fields before
returning an observation. Client examples 23 and 24 inspect this common shape
and validate the typed scalar fields. ECLiPSe forwards the normalized observation
instead of wrapping dict text in an opaque `swi_dict/1` term. Native SWI provider
code continues to use dicts internally.

## Regression checks

Run `swipl -q -s tests/portable_json_tests.pl -g 'run_tests,halt'` and the existing
`tests/jev_tests.pl` suite. The engine-neutral `tests/portable_json_cases.pl`
loads after the codec and exposes `portable_json_regression/0`. Run that source
in SWI, Trealla, ECLiPSe, GNU ISOBASE and SWI-WASM worker/main modes.

`tests/portable_jev_cases.py` builds deterministic cases for both Jev drawer
examples, using a test-only copied sensor and embedded chart. It checks successful
observations and decisions, unavailable/malformed results, and immediate monitored
errors. Production sensor bindings and chart URLs are unchanged. Fridge example
16 must be run as its full, unpaced Queries-menu sequence: its intentional
`server_down(false)` is followed immediately by a successful request, upgrade,
defensive bad request and shutdown.

`tests/wasm/http_session_examples.cjs` checks both HTTP pages in Chrome with
intercepted endpoints: profile rejection before POST, 404/405 fallback, preserved
401/403 errors, paging and correlated replies. It performs no live writes.

Release preparation must include the new codec and SWI adapter. Upgrade the
SWI service boundary and the ECLiPSe forwarding wrapper together; this contract
must be checked in isolation before cutover. Existing sealed packages are not
edited to pick up these changes.
