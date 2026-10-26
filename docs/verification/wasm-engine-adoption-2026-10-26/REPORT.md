# SWI-WASM 10.1.19 adoption — 26 October 2026

The working repository and the live browser asset selection now use the verified
`swipl-wasm@8.2.5` bundle containing **SWI-Prolog 10.1.19**. The adoption is local
commit **0064d8d1934b0fc84c501ff134aed094c95960f8**. Its only changes are
`web/swipl-bundle.js` and the package/engine/integrity record
`dependencies/swi-wasm.json`. It has not been pushed.

The complete separate acceptance run is retained in
[the acceptance report](../wasm-engine-8.2.5-2026-10-26/REPORT.md): the unchanged
WASM tier passed all 2,751 semantic assertion lines, and its statechart-monitor
UI diagnostic reproduced on the old engine. No adapter repair is included here.

## Publication and verification

The serving clone advanced from `b9ea7c557a61faf5ef9524fb97500bbe1ff89015` to
`0064d8d1934b0fc84c501ff134aed094c95960f8`. Native HTTP asset handlers read this
checkout at request time, so no server restart was required. n5's frontend
continues proxying those same assets. SHA-256 checks confirmed that both
`http://localhost:3053/swipl-bundle.js` and
`http://localhost:3060/swipl-bundle.js` serve the new repository bundle. The
selected browser Prolog payload is unchanged. The commit guard and
`tools/setup_swi.py --validate` passed; see [update record](update.json).

Fresh disposable browser sessions through the live portal verified
`current_prolog_flag(version_data,V),V=swi(10,1,19,[])`,
`write("abc").` and `"é😀"==['é','😀'].` in both main-thread and Worker modes.
The write query prints `[a,b,c]` before `true.`. All six smoke observations pass;
see [results](ui-results.json), [complete UI evidence](ui-evidence.json.gz),
[main screenshot](main-ui.png) and [Worker screenshot](worker-ui.png).
The original main-thread preference was restored and the temporary tab closed.
Existing open pages must be refreshed to replace their already-loaded engine.

[Preservation checks](preservation.json) confirm unchanged process identities and
start times for n3, n5, the n5 frontend and auxiliary Trealla node; unchanged
native engine binaries; unchanged native/Trealla source selections; and no
changes to either browser adapter or statechart support sources. Only the
browser engine and its asset commit selection changed.

## Rollback

The old bundle and selection are retained at:

```
~/.local/share/trinity-local-nodes/wasm-engine-rollback-2026-10-26/
```

The serving clone also retains `refs/rollback/wasm-engine-2026-10-26` pointing to
the prior browser commit. To restore the prior selection, run the **deployed**
script, which has the accompanying saved selection and update record:

```
python3 ~/.local/share/trinity-local-nodes/wasm-engine-rollback-2026-10-26/rollback.py
```

A review copy is [here](rollback.py). It refuses rollback if a later browser
selection or different native source selection is active. It restores the
previous committed browser assets and validates the guard without restarting a
node or changing a native runtime. Rollback was prepared but not executed after
successful adoption. This is a rollback instruction, not a scheduled action.
