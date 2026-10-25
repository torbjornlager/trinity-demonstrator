# Live browser-asset update — 25 October 2026

## Result

The live portal at `http://localhost:3053/portal?node=swi-wasm` now serves
repaired demonstrator commit `b9ea7c557a61faf5ef9524fb97500bbe1ff89015`.
It includes the character-list migration and main-thread output-flushing repair.
Both main-thread and Worker UI checks showed exactly `[a,b,c]` followed by
`true.` for `write("abc").`; see [results](ui-results.json),
[main transcript](main.txt), [Worker transcript](worker.txt),
[main screenshot](main.png) and [Worker screenshot](worker.png).
The original main-thread execution preference was restored and the temporary
verification tab closed. Existing open pages need a refresh to load new code.

## Hot selection

No node was restarted. Native HTTP handlers read browser assets from disk at
request time. The committed serving checkout under
`~/.local/share/trinity-local-nodes/committed-adoption-2026-10-25/demonstrator`
advanced from `5b4deb3aeee6e3b9bc66592d0554e4e1e65535ad` to the repaired commit.
The diff was checked before publication: it changes browser/test/documentation
files and the browser-only statechart datamodel reader, with no native runtime,
loader, examples, service or deployment configuration changes.

The selected native schema and five browser Prolog files were assembled from
exact committed inputs into a new ignored payload directory. The old payload
was retained in the rollback directory. A compatibility symlink from the existing
live payload path points to the new directory, so the already-running server
uses the new files without reconfiguration or restart. The ignored setup JSON
now records the new payload; the committed selection guard records the new
**demonstrator** revision. Native and Trealla revision selections remain unchanged.

The HTTP portal and Worker script were compared byte-for-byte with the selected
git commit, and all six served Prolog payloads with their selected sources.
The commit guard and `tools/setup_swi.py --validate` passed. See
[before state](before.json) and [update results](update.json).

n5's frontend already proxies these shared browser assets from n3, so fresh
browser pages through either URL receive the shared update. No n5 process,
launcher, frontend configuration, backend code or Trealla engine was changed.
This is not an engine update or a native-node source adoption.

## Rollback

The prior commit is retained in the serving clone at
`refs/rollback/browser-assets-2026-10-25`. Prior selection/setup files and the
original six-file browser payload are retained at:

```
~/.local/share/trinity-local-nodes/browser-assets-rollback-2026-10-25/
```

If rollback is required, run the retained script from that directory:

```
python3 ~/.local/share/trinity-local-nodes/browser-assets-rollback-2026-10-25/rollback.py
```

It checks that this asset selection is still active and the native selections
have not changed, restores the previous commit, payload and selection files,
and checks the guard. It performs no node restart or engine change. A copy of
the script is retained here for review; execute the deployed copy above because
it is accompanied by the saved payload and `update.json`. Rollback was prepared
and reviewed but not executed after the successful live update.

## Preservation

[Final preservation checks](preservation.json) confirm exact process identities
and start times for n3, n5, the n5 frontend and auxiliary Trealla node. Installed
engine hashes/targets, n3/n5 launchers, the n5 frontend file and n3 admin
configuration are unchanged. Both native source checkouts retain their original
commits and clean tracked files. No source in the working repository was edited;
only this verification/deployment record was added.
