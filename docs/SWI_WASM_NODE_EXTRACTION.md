# SWI-WASM node extraction: stages 1 and 2

Stages 1 and 2 establish an in-repository runtime boundary and an independent
host. No repository, package release, dependency pin, or live deployment is changed.
The SWI-WASM engine remains `swipl-wasm@8.2.5` / SWI-Prolog 10.1.19.

## Ownership inventory

| Component | Current implementation | Owner after repository extraction |
| --- | --- | --- |
| Actor identities, names, startup transactions, scopes, monitors and delayed sends | `web/vendor/swi-wasm-node.js` | swi-wasm-node |
| Worker creation, shell replacement/retirement, remote actor/WebSocket and HTTP RPC coordination | `web/vendor/swi-wasm-node.js` | swi-wasm-node |
| Generated behaviour and main-engine Prolog bridges, shared-database loader and statechart loader | `web/vendor/swi-wasm-node.js` | swi-wasm-node |
| Main-engine bootstrap, source installation, lazy query driver and bridge installation | `web/vendor/swi-wasm-node.js` | swi-wasm-node |
| Worker bootstrap, mailbox, actor Prolog bridge and statechart host | `web/swi_wasm_actor_worker.js` | swi-wasm-node |
| Browser statechart implementation | Four `prolog/web_prolog/wasm/statechart_wasm*.pl` files | swi-wasm-node |
| Engine distribution and integrity pin | `web/swipl-bundle.js`, `dependencies/swi-wasm.json` | swi-wasm-node |
| Actor transport contract and runtime implementation guide | `docs/browser_actor_transport.md`, `web/README.md` | swi-wasm-node, with consumer links |
| Shared SXML schema | Assembled from exact native pin by `tools/package_wasm_prolog.py` | Native source remains authoritative; browser package carries its pinned build input |
| Tutorial shared database | `prolog/web_prolog/wasm/shared_db.pl` | Demonstrator; supplied as host data |
| Editor, terminal controls, rendering, query presentation and tutorial bridge | `web/demonstrator.html` | Demonstrator |
| Examples, tutorials, discovery, runtime-selection settings, application endpoint selection | Existing demonstrator assets | Demonstrator |
| Runtime semantic tests | `tests/wasm/` | Runtime cases move with the implementation; UI integration assertions stay with the demonstrator |

The complete extracted method inventory and pre-extraction source revision are
in `docs/verification/wasm-runtime-extraction-2026-10-27/inventory.json`.

## Runtime and host interface

`web/vendor/swi-wasm-node.js` exposes `SwiWasmNode` to a browser, and the same API
through CommonJS for tests. It contains no Vue, editor or terminal-widget access.
The `vendor/` location uses the existing native static-file route, allowing this
stage to work with the currently pinned native node without modifying it.

There are two consumers of the same implementation:

* The demonstrator mixes `SwiWasmNode.methods` into its existing host and uses
  `SwiWasmNode.createState()` for fresh reactive state. Its presentation adapters
  remain in the page. This preserves existing main-thread and Worker controls.
* A separate host calls `SwiWasmNode.create(options)`. It receives a Worker session
  API with `open`, `query`, `next`, `stop`, `abort`, `input` and `dispose`.
  Its state and actor registries are independent of every other created host.

Example:

```javascript
const node = SwiWasmNode.create({
  workerUrl: '/swi_wasm_actor_worker.js',
  engineUrl: '/swipl-bundle.js',
  prologBaseUrl: '/wasm/',
  sharedDatabaseUrl: null,
  onEvent(event) {
    if (event.type === 'output') console.log(event.data);
  },
  onInput(promptText) {
    return Promise.resolve(window.prompt(promptText));
  }
});
await node.open({source: 'square(X,Y) :- Y is X*X.'});
const answer = await node.query('square(3,Y)', {limit: 1});
console.log(answer.data); // [{Y: '9'}]
node.dispose();
```

`open` keeps a persistent session; call it again after a shell has died to create
another. For a different source program, dispose/create a new instance. `query`
accepts either canonical Prolog options text or an options object. Its response is
the existing `success`/`failure`/`error`/`timeout` envelope; an answer with `more:true`
is resumed with `next` or discarded with `stop`. Concurrent calls are rejected.
Fatal Worker/startup errors reject the pending operation. A syntax error that
kills a shell retains the existing runtime behaviour; a host can explicitly open
a replacement session.

When a query is waiting, `stop`/`abort` sends interruption and the outstanding
query promise receives its response. When no query is waiting, the returned
promise receives the interruption response. `dispose` is idempotent, terminates
Workers, cancels delayed actor sends, closes remote sockets, and rejects pending
query/startup work. Browser page destruction remains the lifetime boundary.

`onEvent` receives output, traces, logs, traffic, answers and host lifecycle events.
A host must accept output synchronously before acknowledged remote I/O continues;
returning `false` declines output. With no `onInput`, a `prompt` event is followed
by an input wait that the host can satisfy through `input(text)`.

The demonstrator's callbacks render output, format traces, capture terminal input,
restore prompts, refresh examples on readiness, and reset displayed bindings after
shell replacement. Prolog terms and transport envelopes are unchanged. Runtime
source URI restrictions and browser CORS checks are unchanged.

The main-thread compatibility engine still has page-global Prolog bridge callbacks
and DOM access. Its bootstrap is exported as `initSwiWasmSession`, with readiness,
output and errors delivered through the host callbacks. `loadSwiWasmMainSource`
and `driveSwiWasmMainQuery` install source and run the existing lazy Prolog driver;
the terminal adapter supplies its answer presentation callback. The minimal host
verifies these paths independently. The new convenience session API uses Workers; it does not claim
to make multiple compatibility engines on one page independent.

## Independent verification host

`web/vendor/swi-wasm-minimal.html` loads only runtime assets. It does not load
`demonstrator.html`, Vue, terminal/editor libraries, the example database, or a
native execution service. Its Worker checks exercise source loading, paging,
actor messaging, monitoring, statecharts, Unicode, errors and disposal. A separate
button checks compatibility-engine startup, `library(dom)`, host-supplied source,
query execution and promise lifecycle.

Serve it without a Prolog server using an already assembled payload directory:

```sh
python3 tools/serve_wasm_standalone.py --prolog-root /path/to/assembled/payload
```

The command prints its loopback URL. The payload is the output of the existing
`tools/package_wasm_prolog.py` (or `tools/setup_swi.py`); the native schema is a
build input, not a running service dependency.

`tests/wasm/swi_wasm_standalone.js` additionally runs real engines in real Worker
threads using the actual exported coordinator, with no demonstrator HTML. It
checks non-default asset locations, a host-supplied shared database, I/O, abort,
syntax-error recovery and disposal during query/startup. It is part of the WASM
CI tier. Existing semantic scenarios retain their assertions and now import
exported methods rather than reconstructing moved implementations from the page.

## Stages intentionally left for later

* Move ownership into the new repository, publish artifacts and adopt an exact pin.
* Generalize demonstrator endpoint selection and generate a static example index.
* Build a complete distribution under a path prefix; choose a CDN origin and
  cache/update policy. The runtime's configurable assets prepare this work but
  do not make the whole demonstrator CDN-ready yet.
* Add installation and offline support.

Until extraction is released, rollback is the preceding demonstrator revision.
There is one runtime implementation and no legacy selection switch.
