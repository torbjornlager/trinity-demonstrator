# Native SWI 11 integration upgrade — 19 November 2026

The demonstrator now selects native `swi-prolog-node` commit
`26e1ce7d712afafe440e3f87388baec4490232ec` and requires threaded SWI-Prolog
11.0.0 or newer at startup. Both native Dockerfiles pin the official 11.0.0
multi-platform image index, and the shared Actions setup builds checksum-pinned
11.0.0 source from the stable channel.

## Exact inputs

| Input | Selection |
| --- | --- |
| Native node | `26e1ce7d712afafe440e3f87388baec4490232ec` |
| Browser package | `0363b38b3d4939a53f62a57b23fbc4e73997e79f` |
| Browser manifest SHA256 | `00fb7161d9a61968da6238ebf6630416ab51ea25eeed93953879c2349ef0435a` |
| Native engine | Official macOS universal SWI-Prolog 11.0.0 |
| Node.js | 22.23.4 |
| CI source SHA256 | `64b9e2b8a862ee56dd54cf6820775111afc87310511c8f03f6fd978614e37c33` |
| `swipl:11.0.0` image index | `sha256:1296dcde9f7cfe93a21e8ad86c6ee2962b56bc6189622f02e27f2543453fee1c` |

The source archive was downloaded from the official stable URL and its hash
verified against the [official download page](https://www.swi-prolog.org/download/stable).
`docker buildx imagetools inspect swipl:11.0.0` confirmed that the index includes
Linux AMD64 and ARM64.

Strict setup requires the browser schema provenance to match the native commit.
The companion browser commit updates only `dependencies/native-schema.json` and
`dependencies/swi-prolog-node.json`. Comparing the old and new packaged inventories
confirmed that those are the only changed file hashes: runtime code, schema bytes,
and the WASM engine (10.1.19, `swipl-wasm` 8.2.5) are unchanged.
The companion commit is on `codex/swi-11-native-pin` in `swi-wasm-node`.

## Validation

Run from the demonstrator with Node.js 22.23.4 on PATH:

```sh
python3 tools/setup_swi.py --native-root /Users/lager/swi-prolog-node \
  --browser-root .trinity/swi-wasm-node-11
python3 tools/ci_pinned_swi.py --native-root /Users/lager/swi-prolog-node \
  --swipl /usr/local/bin/swipl --output .trinity/swi-11-integration-20261119
SWIPL=/usr/local/bin/swipl bash tools/test.sh SERVICE_TEXT
```

All 34 gates have passing results, including the focused SERVICE_TEXT rerun:

- Native origin audit, layering, portable text, T0–T5 native selections.
- T1, T3 and T4 external-asset integration selections.
- Demonstrator, service text, Linda, model, model SXML and Jev consumers.
- Startup version/thread validation, dependency and browser pins, static
  distribution, HTTPS/SSO probe, host URL handling, cross-origin real native
  authentication, portal runtime and discovery checks.
- CI runner, packaging, watchdog and fetch regressions; browser equivalence;
  complete WASM statechart, worker, standalone and semantic-contract checks.

The first full runner exited 1 because SERVICE_TEXT retained two dict-based
assertions from before the existing Jev portable JSON migration. The service
already returns portable `json(...)` objects, as its implementation and dedicated
Jev tests specify. The consumer test now checks the same legend, Unicode,
empty-string/array and boolean/null values through `portable_json_get/3`.
Its focused rerun passed. No service behavior was changed. Every other gate,
including WASM, passed on the initial full run.

[Results](results.json) preserve the initial SERVICE_TEXT exit and its successful
rerun. Full logs, provenance and the isolated CI setup remain in ignored
`.trinity/swi-11-integration-20261119/`; ordinary local setup was also refreshed
with the new pins. The full CI runner's original results were not overwritten.

These are local macOS integration results. The Linux Actions source build and
complete deployment images were not built here; their source and image inputs
were verified. No public services were rebuilt, restarted or redeployed.
