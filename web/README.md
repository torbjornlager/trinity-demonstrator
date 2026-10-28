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
