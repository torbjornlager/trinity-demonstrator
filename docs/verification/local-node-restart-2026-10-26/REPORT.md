# Controlled n3/n5 restart — 26 October 2026

Restarted the selected native nodes and n5 frontend using their existing launchers
and configuration. The previous three processes exited after SIGTERM; no forced
kill was needed. The auxiliary Trealla 3061 node was left running.

| Component | Previous pid | New pid | Public URL |
|---|---:|---:|---|
| n3, selected SWI build | 13773 | 45168 | http://localhost:3053/portal |
| n5, Trealla backend | 13791 | 45186 | Backend remains loopback 3062 |
| n5 frontend | 91509 | 45197 | http://localhost:3060/portal |

Native source/engine selections and launchers are unchanged: n3 uses the verified
separate SWI 10.1.18 build containing its recorded fixes; n5 uses Trealla 3.14.10
with matching libraries. Browser assets remain commit f0783fb, including the
adopted SWI-WASM 10.1.19 engine and statechart-monitor repair. No native runtime
upgrade was performed or implied by this restart.

Both public URLs returned 200 for portal, version, node info and health. Fresh
public WebSocket sessions on both nodes passed runtime identity, character-list
literal equality and `write("abc")` output `[a,b,c]`; sessions were halted after
checking. Version endpoints confirm SWI on n3 and Trealla on n5, with no SWI
fallback on n5. Both URLs serve the checksum-pinned new browser bundle.

[Before](before.json), [restart commands/pids](restart.json),
[health and query evidence](smoke.json), [after/selection checks](after.json).
Existing browser tabs should refresh to reconnect and load the selected assets.
