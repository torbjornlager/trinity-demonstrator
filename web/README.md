# Browser runtime integration

The SWI-WASM implementation guide is maintained in
[swi-wasm-node/docs/runtime.md](https://github.com/torbjornlager/swi-wasm-node/blob/v0.1.0/docs/runtime.md).
The [shared language manual](manual.html) remains the API reference for all nodes.

The demonstrator consumes the exact browser package selected by
[dependencies/swi-wasm-node.json](../dependencies/swi-wasm-node.json).
Runtime, Worker, engine and browser Prolog asset paths are relative symlinks into
that validated package. Setup is required before serving the checkout.

`demonstrator.html` supplies presentation adapters and host callbacks;
`prolog/web_prolog/wasm/shared_db.pl` supplies example data. Those remain
consumer-owned. The package also supplies an independent
[minimal host](vendor/swi-wasm-minimal.html).
See the [extraction and setup guide](../docs/SWI_WASM_NODE_EXTRACTION.md).

SWI-WASM uses the shared [ACTOR tutorial](actor-profile-tutorial.html), also
selected by the demonstrator. The separate SWI-WASM tutorial is retired;
its old URL provides a pointer to the shared tutorial. Its historical content
is preserved in [docs/archive/swi-wasm-tutorial.html](../docs/archive/swi-wasm-tutorial.html)
and is not maintained or served as an active walkthrough.
