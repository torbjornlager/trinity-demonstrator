# Static demonstrator preparation — 28 October 2026

Stage 4 adds an explicit asset/service boundary and an opt-in static distribution.
The native and browser runtime pins are unchanged. Existing node-hosted startup
remains the default. No CDN publication or live deployment was performed.

The development preview contains 136 files under `/releases/preview/`, including
the editor, tutorials, examples, fonts, licenses, shared database and pinned engine.
Its manifest records that the source contains uncommitted changes; it is not a
release. Build/preview instructions and remaining rollout work are documented in
[CDN_DISTRIBUTION.md](../../CDN_DISTRIBUTION.md).

## Verification

- All 44 Python tests passed, including five static packaging tests.
- Host configuration and actual presenter HTTP/metadata/WebSocket target tests
  passed with distinct asset and service origins. Runtime identity tests passed.
- The WASM tier passed all 102 semantic scenarios, 60 runtime Prolog cases and 11
  consumer Prolog example cases, with the existing bridge and equivalence checks.
- The static Worker UI loaded `01 queens.pl`, returned both four-queen solutions
  through paging, and accepted Stop. Main-thread mode returned `member/2` answers.
- The ACTOR tutorial loaded from the versioned path and its Call button executed
  `append([a],[b,c],Xs)` in the browser shell, returning `Xs = [a,b,c]`.
- The existing node-hosted page executed and paged `member/2` using its native
  WebSocket session on a disposable test node.
- A final copy outside both repositories ran on ordinary `python3 -m http.server`,
  with no custom routing or native backend. It loaded the example and returned
  `Q = [2,4,1,3]`. The final HTTP log had no 4xx/5xx requests. An earlier font
  stylesheet root-path defect was fixed in packaging and covered by a regression
  that resolves every font URL beneath the versioned distribution.
- Package verification passed after relocation; the static tree has no symlinks.

Evidence: [independent static build](relocated-static-final.png),
[Worker mode](static-worker.png), [main-thread mode](static-main.png),
[tutorial bridge](static-tutorial.png), [existing native UI](legacy-native.png),
[results](results.json) and [development manifest](preview-manifest.json).

Selecting a remote node address is verified as routing configuration. Cross-origin
HTTP, node WebSocket origin admission, authentication and cookies still need
end-to-end checks from the eventual hosted origin. No node origin/access rules
were relaxed. Administrative/discovery services remain on the nodes. Installable
or offline operation and a public CDN release are later steps.
