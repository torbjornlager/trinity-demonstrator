# Controlled SWI update and n3 smoke checks — 24 October 2026

## Outcome

n3 now runs the exact verified private SWI installation, with Jan's protected-wait core fix, PCRE support and the locally maintained HTTP shutdown repair submitted as [SWI-Prolog/packages-http #176](https://github.com/SWI-Prolog/packages-http/issues/176).

- Old n3 PID: `55051`; new n3 PID: `7072`.
- Portal remains `http://localhost:3053/portal`.
- Existing Admin configuration is identical before and after the restart.
- All 13 final HTTP/WebSocket smoke checks and both portal UI queries pass.
- Trealla binaries, auxiliary backend, public n5 backend and n5 frontend retain their previous hashes/process identities and commands.

This updates the active local n3 installation by selecting a complete private runtime prefix. It does **not** replace the macOS application/framework, modify global PATH, or change the native node's source checkout to the extracted repository. The existing n3 source checkout and asset/service configuration are retained.

## Exact installation and startup

Active alias:

`~/.local/share/trinity-runtimes/swi-current`

Target:

`~/.local/share/trinity-runtime-tests/swipl-http-shutdown-2026-10-24/install`

Durable launcher and entry point:

- `~/.local/share/trinity-local-nodes/n3/start.sh`
- `~/.local/share/trinity-local-nodes/n3/start_local_node.pl`
- PID file: `~/.local/share/trinity-local-nodes/n3/n3.pid`
- Log: `~/.local/share/trinity-local-nodes/n3/n3.log`

The launcher uses the active alias, clears inherited SWI home overrides, and runs from the demonstrator checkout with the existing `n3` argument. `TRINITY_SWI_RUNTIME` can explicitly select another complete prefix; no override was used here.

Core commit: `09b6299f696574c9230f23e53b1ab041a942b6f3`, reporting 10.1.18. HTTP package base: `9d1e28e676831618c9894f728ef50872b2eb87d7`, plus the verified shutdown patch. The complete original installation manifest differs only at `thread_httpd.pl` and its matching SWI-generated `thread_httpd.qlf`; native binaries are identical. Live n3's mapped executable, boot image and shared objects resolve to the candidate prefix, with no app/framework mappings from the old system installation. See `before.json` and `n3-loaded-runtime.log`.

## Launcher recovery and rollback

The old live process referenced `/tmp/web-prolog-local-ui/start_local_node_reuse.pl`, but that file had disappeared before this update. Before stopping n3, its source was recovered from this chat's original launcher-creation command and the subsequent recorded `reuseaddr` transformation. Durable copies preserve the recovered launcher. This is reconstruction from the original commands, not a claim that a missing file was copied from disk.

A temporary candidate node on port 51854 confirmed the recovered startup: its full Admin configuration matched live n3's except for the temporary self URL. It was stopped before switching n3. Startup still binds loopback, advertises localhost, uses the ACTOR profile and blacklist sandbox, preserves timeout/resource settings, origins, shared databases, tutorial sections, resident services and per-WebSocket anonymous principal setup.

Rollback assets are retained under:

`~/.local/share/trinity-local-nodes/n3/rollback/`

- `start_local_node_reuse.pl`: recovered original entry point.
- `start.sh`: recommended rollback entry point, delegating to the retained 10.1.17 runtime with its compatible source snapshot.
- `start-macos-10.1.18.sh`: preserved alternate launcher using the unchanged macOS-installed executable; it is not the recommended rollback for the current receive adapter.
- `start-original-10.1.17.sh`: launcher using the retained original 10.1.17 framework/runtime and private compatible source.
- `source/`: private snapshot of demonstrator commit `0bc8978`, with only `prolog/web_prolog/actors.pl` restored to the revision immediately preceding the protected-wait adapter. `rollback-source.json` records both exact revisions.
- `start_compatible_node.pl`: recovered configuration with code imports directed at that private snapshot; shared database and asset paths remain those of the existing demonstrator.
- `bin/swipl`: private copy of the retained old app's launcher stub, relinked explicitly to the preserved 10.1.17 framework and ad-hoc signed. This avoids accidentally loading the newer system framework. Neither retained original backup nor the system app/framework was modified.
- `before.json`: recorded old process, configuration provenance and protected hashes.

The original 10.1.17 app/framework backups remain at:

`~/.local/share/trinity-runtime-tests/swipl-installed-update-2026-10-23/`

The rollback runtime was checked for version **10.1.17** and the matching retained runtime home (`rollback-runtime-probe.log`). A simple attempt to use the old app stub with a framework environment override instead reported 10.1.18; explicit relinking of a private stub copy corrected that. The retained 10.1.17 runtime and compatible source were also started on temporary port 51854. Startup passed and its Admin configuration matched the original n3 configuration except for the temporary self URL. That process was stopped afterward. The source snapshot avoids loading the protected-wait receive adapter on an engine that predates its prerequisite; it does not change active node source. A full old-runtime rollback on port 3053 was not performed, since that would undo the authorized update. The new candidate remains active.

For rollback, stop the currently recorded n3 PID first, verify port 3053 has been released, then choose the appropriate saved launcher. Do not start a second n3 against the occupied port. These launchers do not alter or stop n5.

## Smoke checks

`smoke-results.json` records all 13 final assertions:

1. Native runtime properties.
2. Existing shared printer database.
3. Unicode answers.
4. HTTP private source loading.
5. Private-source isolation across requests.
6. Parallel and first-solution completion semantics.
7. Worker cleanup after an exception, preserving the caller actor list.
8. Synchronous toplevel call/next paging and cleanup.
9. Empty supervisor counts using native reply format, followed by halt.
10. Text-source statechart halt and spawn-time monitor delivery.
11. URI-source statechart halt and monitor delivery.
12. Promise timeout callback, retry, successful answer and variable isolation.
13. Sandbox rejection of forbidden state access.

The portal UI independently returned `swi_native`, then the expected `[socrates]`/`[plato]` synchronous pages. Its worker-error query returned the same actor list before and after cleanup. The UI logs the killed losing worker as an actor exit; this is expected cleanup, not a failed query. The temporary browser tab was closed after saving `ui-transcript.txt` and `ui-smoke.png`.

The active-alias runtime probe confirms Unicode PCRE, XML parsing, SSL context creation and crypto hashing. It verifies file identity against the complete candidate using `same_file/2`. The three-case HTTP shutdown regression passes through the active alias. Portal, tutorial and example XML URLs return HTTP 200.

## Smoke harness corrections retained separately

Initial smoke development exposed harness mistakes, not runtime repairs:

- The HTTP source parameter is `src_text`, not `load_text`.
- Stateless `/call` uses ISOBASE execution; worker/toplevel/supervisor/statechart checks belong on the stateful WebSocket route.
- A draft client helper named `read/2` collided with SWI's built-in; the private smoke helper was renamed `read_json/2`.
- The first supervisor assertion mistakenly used the browser runtime's `counts(0,0)` reply instead of native `[specs-0,active-0,supervisors-0,workers-0]`. Native statechart halt also replies `true`, rather than the browser's `stopped`.
- Old installation probes required the literal substring `/install/` in runtime paths. The new alias legitimately hides that substring; `runtime-probe.pl` uses resolved file identity and retains the substantive PCRE/XML/SSL assertions instead.

Corresponding initial/draft logs and results are retained. No runtime code, semantics or production timeout was changed to make these checks pass. The final smoke script routes each test through its appropriate public API.

## Preservation

`after.json` confirms identical Admin configuration and unchanged macOS app/framework and Trealla executable hashes. n5 process IDs `42134`, `97669` and `97896` retain their start times and commands. No Trealla source, runtime selection, libraries or n5 launcher was edited. Only n3 was stopped and restarted. Full acceptance suites were not redundantly rerun during the switch; the exact candidate's earlier acceptance and shutdown verification remain in the adjacent reports.
