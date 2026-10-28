# Repository guidance

The native implementation belongs to the pinned `swi-prolog-node` dependency.
The browser runtime and runtime tests belong to pinned `swi-wasm-node`.
This repository owns demonstrator assets, tutorials, examples, presenter adapters
and consumer integration tests. Runtime paths here are tracked relative symlinks
into the validated external browser package; do not replace them with copies.
Do not reintroduce a native implementation or a second SXML schema here.
Use `tools/setup_swi.py` and `tools/test.sh`; see README.md.

Implementation fixes and runtime tests belong upstream. Lower-layer test
processes must not preload the complete node. Preserve language semantics;
record intentional observable changes in DEVIATIONS.md. Historical layering
notes remain in docs/LAYERED_REAL_NODE_PLAN.md.
