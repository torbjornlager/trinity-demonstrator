# SWI-WASM character-list migration — 2026-10-25

## Scope and result

The Worker and compatibility main-thread browser engines now use character-list
reading for language text. `"abc"` denotes `[a,b,c]`; `""` denotes `[]`. Unicode
characters, including supplementary characters such as 😀, are one-character
atoms. This changes the browser implementation, not the cumulative profile
baseline or installed native nodes. Native SWI and Trealla were not modified.

The candidate was tested from demonstrator base commit
`6710821f246c2b0a1047651c5a0429a402a7905c` plus this working-tree batch.
No adoption/pin/deployment change is included. Existing n3/n5 continue serving
their committed assets until separately authorised adoption.

## Reader and boundary audit

| Boundary | Reading/conversion |
| --- | --- |
| Worker shell goals and call options | User module uses chars; explicit shell goal reader also specifies chars and user context. |
| Main-thread goals and options | User module uses chars, including queries assembled by the JS shell. |
| Interactive read/input | Language reader specifies chars; the private shell input envelope transfers text before parsing. Existing typed input envelopes retain their terms. |
| Editor/private and fetched source | Ordinary user source reads chars; fetch grouping/order and origin restrictions are unchanged. |
| Shared DB | Explicit load into `wasm_shared_db`, character reading, bridge imports and user import restored. |
| Statechart datamodel | Reads in the statechart data module with chars, restoring the module's previous flag afterward. |
| Local materialised clauses/copied predicates | Already typed terms are serialized under native string reading, then character reading resumes. Source option ordering/grouping is preserved. |
| Internally supplied behaviour source | Native string reading is scoped to implementation blocks; cleanup restores user chars. User override warnings remain covered by existing contracts. |
| Upgrade source | Reads in user context; generated read-mode directives target user explicitly; cleanup restores chars. |
| URI/source/prompt text | Known character-list text is converted explicitly to atoms/native strings. Existing atom/native-string inputs remain supported; numeric code lists are rejected at text-option boundaries. Prompt atoms and arbitrary prompt terms retain their existing targeted protocol representation. |
| JS/native libraries | Native string constructors, output capture, library flags and bridge flags remain native. |
| Canonical messages/Worker startup | Explicit string wire reader preserves native strings, charlists, variables and variable sharing. Supplementary Unicode text atoms are accepted; cyclic terms and non-text blobs remain rejected. |

Explicit remote source retains its existing destination loading convention;
this batch adds no text-mode negotiation. It does not promise that textual source
compiled by a different-mode peer has the caller's literal semantics. Existing
browser runtime limitations remain separate (see `web/README.md`).

## Regressions

`tests/wasm/swi_wasm_contracts.js` adds `portable_text_worker` and
`portable_text_main` against the actual bundled WASM engine. They cover literals,
empty text, Unicode, DCGs, default readers, shared/private source, datamodels,
native library strings, typed source/copy/upgrade, mode restoration, strict text
inputs, canonical sharing and transport rejection controls, and interactive input.

Existing Boolean/URI, source-loading, warning, asynchronous-answer and input
smoke fixtures retain substantive assertions. URI fixtures now reject a list
containing a multi-character atom rather than a valid character list. Native
string expectations explicitly construct/read native strings instead of relying
on double-quoted test literals.

Focused checks passed; see [Worker](portable-worker.log) and
[main-thread](portable-main.log). The complete final tier is recorded in
[WASM-complete.log](WASM-complete.log). Its process exit status is recorded in
`results.json` after completion.

During development, the regressions exposed and corrected raw character lists
reaching native concatenation, supplementary atoms being classified as non-text
blobs, ambiguous shared-module loading, and a prompt displayed as list notation.
The new source-copy check also required preserving explicitly constructed native
strings across generated local source. Intermediate failed logs were replaced by
the final evidence; these were not accepted as passing checks.

## UI checks

A temporary native asset server at `http://localhost:53179` served candidate
browser assets and a copied WASM payload. The copy appended only
`portable_text_fixture("hé😀").` to its shared DB; the repository shared source
was unchanged. The temporary server explicitly selected that copied WASM directory
and used the existing verified SWI launcher. HTTP checks called this same-origin
disposable peer, never n3/n5. Browser Settings on this disposable origin selected
each mode in turn.

| Public-interface check | Worker | Main-thread |
| --- | --- | --- |
| Runtime identity, Unicode literal equality and empty literal | pass | pass |
| Shared fixture equals `[h,é,'😀']` | pass | pass |
| `rpc("http://localhost:53179",atom_string(native,N)),string(N)` | pass | pass |
| `read(X),X=="hé😀"` with input `"hé😀".` and plain prompt | pass | pass |
| Spawn with `src_list` containing native string and chars; exact down notification | pass | pass |
| Editor fact `portable_editor("hé😀").` returns character list | pass | pass |

AX evidence: [Worker](ui-worker.txt), [main](ui-main.txt),
[main editor](ui-main-editor.txt). Screenshots: [Worker](ui-worker.png),
[main](ui-main.png). One main-editor query was mistyped by UI entry as
`runtime_pro perty`; the corrected query passed. No timeout/assertion was weakened.
The temporary browser tab and server were closed after verification;
[ui-server.json](ui-server.json) records the disposable fixture.

## Preservation

[Preservation evidence](preservation.json) compares process identities/start times
and SHA-256 hashes of n3/n5 launchers and committed runtime selection before and
after testing. All matched. Installed engines, n3/n5, dependency pin, native copies,
book and examples remain unchanged. Only ignored working-tree browser payload
assembly was refreshed to serve the candidate on the disposable origin.
