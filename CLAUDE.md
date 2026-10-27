# Repository guidance

The native implementation has moved to the pinned `swi-prolog-node` dependency.
This repository owns demonstrator assets, tutorials, examples, browser runtimes
and consumer integration tests. Do not reintroduce a native implementation or a
second SXML schema here. Use `tools/setup_swi.py` and `tools/test.sh`; see README.md.

Native changes and their tests belong in swi-prolog-node. Lower-layer test
processes must not preload the complete node. Preserve language semantics;
record intentional observable changes in DEVIATIONS.md. Historical layering
notes remain in docs/LAYERED_REAL_NODE_PLAN.md.
