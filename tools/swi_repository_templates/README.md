# Native SWI Web Prolog node

Local extraction rehearsal from `trinity-demonstrator`, source commit
`@SOURCE_REVISION@`. No GitHub repository or remote has
been created yet. The original demonstrator working tree remains complete.

The repository directory is `swi-prolog-node`. The SWI pack remains
`web_prolog` (version 0.2.0), with `library(web_prolog)`, selective layer imports,
`load.pl` and existing URL handlers unchanged. Published package URLs are not
changed before a real repository is published.

## Load and test

```sh
swipl load.pl
SWIPL=/path/to/verified/separate/swipl ./tools/test.sh
```

The default runs LINT, T0, T1_NATIVE, T2, T3_NATIVE, T4_NATIVE and T5 in separate
processes. No frontend is required. T5 uses an ephemeral node and the preserved
annotated `demonstrator-peer` tag, commit
`2b5eae7ad4118e88f4aec77c513b6204dbf3b69e`; it does not contact n3/n5.
Every source commit and tag from the local clone is retained with its original
ID, including pre-layering history. Frontend code omitted from this working
tree remains in that history and in the original demonstrator checkout.

For frontend integration, configure the external demonstrator explicitly:

```sh
WP_ASSET_ROOT=/path/to/trinity-demonstrator \
WP_WASM_SOURCE_DIR=/path/to/assembled/browser-prolog \
SWIPL=/path/to/verified/separate/swipl \
  ./tools/test.sh T1_INTEGRATION T3_INTEGRATION T4_INTEGRATION
```

The demonstrator's `tools/package_wasm_prolog.py` assembles the five browser
modules plus this revision's native `prolog/web_prolog/wasm/sxml_schema.pl` into
a fresh output directory. Its equivalence check accepts `--native-root` and
`--wasm-dir` and checks schema equality as well as the shared interpreter code.
The native copy supplies the schema for assembly; do not edit a generated copy.
The existing demonstrator copy is retained unchanged during rehearsal. The DTD
and default shared database remain native package files.

`interpret_example/1` uses `WP_ASSET_ROOT/examples/statecharts` when configured;
otherwise its original colocated path is retained. Ordinary source loading,
sandbox checks and URI resolution are unchanged.

Two T4_LEGACY_LAYOUT assertions intentionally require the original colocated
checkout and run there. T5's original tag remains self-contained. The browser
suite stays in the demonstrator. Existing test assertions have not been removed.

## Boundaries

No installed engines, live startup scripts, n3/n5, Docker assembly, CI workflows,
book examples or tutorial URLs are switched by this rehearsal. Documentation
under `docs/` preserves investigation history and may refer to the original
layout; `prolog/web_prolog/README.md` remains the detailed runtime guide. Consult
the extraction map and verification report in the demonstrator for current
ownership and the full per-file inventory.
