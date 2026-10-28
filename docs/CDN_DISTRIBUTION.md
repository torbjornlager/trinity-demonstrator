# Preparing the Trinity demonstrator for static/CDN hosting

A CDN stores and delivers files: the page, JavaScript, styles, fonts, images,
tutorials, examples and the SWI-WASM engine. The browser downloads these files
and runs the interface. SWI-WASM executes Prolog in that browser. Native SWI,
Trealla and other remote nodes continue to run as separate services, reached
over HTTP or WebSocket. A CDN does not run those services.

The current node-hosted demonstrator serves files and execution APIs from one
address. Stage 4 separates those roles while preserving that existing default.

## What stage 4 provides

- `web/vendor/trinity-host.js` resolves the asset location independently from the
  selected execution service. Without configuration, the existing node-hosted
  page still uses its own origin for HTTP and WebSocket calls.
- `tools/package_demonstrator.py` builds a complete static tree from the current
  UI and validated pinned dependencies. It replaces server-generated example
  listings with `examples_index.json`, converts UI routes to HTML files, bundles
  the assembled example database and dereferences runtime aliases into ordinary
  files. It includes licenses and a manifest with source/dependency pins and
  SHA-256 hashes. It does not package a native server or credentials.
- Static mode defaults to the browser node if no remote node is configured.
  It does not try to obtain `/version` or `/node_info` from a file server, and
  does not POST usage logs to the CDN. No fabricated node responses are served.
- The UI, editor, tutorials, Worker and engine stay on the same asset origin and
  versioned path. This preserves frame communication and classic Worker loading.
- Optional node configuration directs HTTP API calls, metadata, WebSocket
  connections and admin links to that service. N1–N5 shortcuts continue to open
  their existing node-hosted demonstrators.

The native implementation and SWI-WASM runtime are unchanged. No live nodes,
CDN, hosting account, authentication rules or origin permissions are modified.

## Build and preview

First run normal pinned dependency setup. Then, from the demonstrator checkout:

```sh
python3 tools/package_demonstrator.py \
  --output .trinity/static-preview \
  --prefix /releases/preview/ --allow-dirty
python3 tools/serve_demonstrator.py --package .trinity/static-preview
```

Open the printed URL. This server serves ordinary files on loopback; it has no
Prolog runtime and does not proxy execution requests. The output directory must
be new. A prefix such as `/releases/0.3.0/` is also supported.

`--allow-dirty` is for development previews; the manifest records that state.
A release build omits this flag and requires clean source. Do not label a dirty
preview as a release. To check a distribution later:

```sh
python3 tools/package_demonstrator.py --verify .trinity/static-preview
```

To select a remote service, add `--node-url https://node.example` to the build.
The generated host configuration looks like this:

```javascript
window.WEB_PROLOG_HOST = {
  mode: 'static',
  assetBase: '/releases/0.3.0/',
  nodeUrl: 'https://node.example/' // null selects browser-only startup
};
```

This is an address, not a password. Do not put credentials in it. An HTTPS UI
requires HTTPS/WSS connections. The build itself needs the source checkouts to
assemble the files; the resulting static tree does not need either checkout or
a native Prolog installation to run the browser node.

Existing node-hosted startup remains `swipl load.pl` or the existing deployment
entry point. Static packaging is an additional, explicit operation.

## What still needs to happen before CDN publication

1. Choose the public hosting address and version layout. Upload a tested,
   committed build as a new version; preserve older versions for rollback.
2. Serve JavaScript, HTML, CSS and fonts with appropriate content types. Cache
   immutable version directories for a long time; give a small “current version”
   entry point a short cache lifetime. Never overwrite files inside an already
   published version, which can mix old and new code in browser caches.
3. Test each intended remote node from the actual hosted origin. Browsers restrict
   cross-origin HTTP requests, and nodes validate WebSocket origins and access.
   Selecting a URL does not grant access. CORS responses, WebSocket origin policy,
   authentication, cookies and logout must be verified together; stage 4 does not
   claim arbitrary cross-origin native-node access is ready.
4. Define installation. Loading the page already downloads its code. A separately
   downloaded installation can serve the same file tree from a local web server.
   An installable/offline app would additionally need a service worker, explicit
   cache updates and offline behaviour; those are not implemented in stage 4.

The independent browser node runs without a backend. RPC and other distributed
examples still need their remote peers and remain subject to the existing
source-URI and transport rules. Administrative and discovery applications remain
on their nodes; they are not bundled as static service implementations.

## Verification

`tools/test-trinity-host.cjs` exercises legacy defaults and actual presenter
methods with distinct asset and service origins. `tests/test_static_demonstrator.py`
checks package completeness, example URLs, route relocation, manifest integrity,
configuration validation and release-build provenance. Both are included in the
local/Actions CI plan. The existing WASM and startup tests remain in place.
