# Tutorial ordering publication and restart — 26 October 2026

Published the tutorial-only change as local commit
`6e76af3525bfdd40d642b7ac1ada0913673eef44`, then restarted n3, n5's Trealla backend
and n5's frontend with their existing launchers, runtimes and configuration.
No push was performed. The previous asset commit is retained at
`refs/rollback/tutorial-order-2026-10-26` in the serving clone.

Both public `/actor-profile-tutorial` responses match the repository file and
have the seven headings in the exact requested order. All example blocks, ids,
buttons and content are preserved; only the complete synchronous section moved
after the expert-system section. Health, version and portal endpoints pass on
both nodes. n5's version remains Trealla 3.14.10; n3 uses the selected SWI build.

The new pids are n3 47403, n5 backend 47420 and n5 frontend 47431. All previous
processes exited after SIGTERM; no forced kill was needed. The auxiliary 3061
node was left running. Native and Trealla source selections and engines are
unchanged. The served WASM 10.1.19 engine and adapter repair remain selected.

[Selection before](selection-before.json), [selection after](selection-after.json),
[restart record](restart.json), [served order and endpoint checks](checks.json).
