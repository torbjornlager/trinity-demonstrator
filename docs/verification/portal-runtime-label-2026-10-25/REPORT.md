# Portal runtime identity — 25 October 2026

The restored n5 frontend correctly routed execution to native Trealla v3.14.10,
but served the shared demonstrator HTML with a hard-coded SWI-Prolog greeting,
splash attribution and status bar. The restart smoke checked runtime identity
through the public API, but missed this misleading UI presentation.

The shared portal now derives the native runtime name, version and link from
`/version`. It reads the existing Trealla `trealla` field and SWI `swipl` field;
unknown/unavailable metadata gives the neutral name Prolog. SWI-WASM retains its
SWI attribution independently of the native host. The greeting waits for both
node information and runtime version, avoiding a startup race. Non-numeric
`web_prolog` backend identifiers such as `trealla-port` are not treated as product
version numbers. The SWI logo is shown only with SWI attribution.

No node backend, source snapshot, sandbox rule, engine, listener configuration
or dependency pin was changed. The portal HTML is served from the demonstrator
asset root, so the fix is available on refresh without restarting either node.

## Checks

`tools/test-portal-runtime.cjs` passes for Trealla, native SWI, SWI-WASM and
unavailable version data, including switching metadata and package-version
handling. All inline JavaScript script blocks pass Node syntax checks.
The Node executable used was:

```
/Users/torbjorn.lager/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node
```

The actual in-app browser at `http://localhost:3060/portal` displays:

```
powered by Trealla Prolog.
?- runtime_property(implementation(Which)).
Which = trealla_native.
```

[n5-verified.png](n5-verified.png) records the visible greeting, identity query and
status bar. The browser verification used a fresh temporary tab, leaving the
user's original tab and query history untouched.

The reported `write("abc")` error is separate: Trealla reads those double quotes
as `[a,b,c]`, and its existing sandbox lists `write/1` as forbidden stream I/O.
This UI fix does not weaken that policy or claim to resolve the language-level
I/O difference. No commit or push was performed.
