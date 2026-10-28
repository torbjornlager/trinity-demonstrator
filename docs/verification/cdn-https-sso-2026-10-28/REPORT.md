# HTTPS and real SSO verification — 28 October 2026

**Status: incomplete — real node HTTPS endpoint unreachable.**

The requested real-provider verification was attempted against
`https://n5.elfenbenstornet.se/demonstrator`. The browser reported
`ERR_ADDRESS_UNREACHABLE`. System HTTPS requests to N5's `/version`,
`/oauth2/auth` and `/demonstrator` also failed. TCP connections to N5 on ports
443 and 80 timed out. N3's public port 443 timed out too, while
`https://trinity.elfenbenstornet.se/` returned 200 and its port 443 was reachable.
No TLS handshake, real sign-in, credentialed CORS or production WebSocket test
could be completed. Network failure is recorded separately from CORS rejection.

The existing local n3/n5 `/portal` and `/healthz` endpoints all returned 200.
Their processes, launchers and configuration were not modified. No public
origin permissions, SSO settings, DNS or certificate trust settings were changed.
No login cookies, SSO tokens or identity headers were exported or recorded.

## Prepared artifact

A clean static package was built before source edits from committed demonstrator
`68eb0ccd1d3afd52e20667ea7b55f216aa46d41c`, with `dirty: false`, using the existing
native/browser pins. Its 136 files are stored in the ignored directory
`.trinity/https-sso-2026-10-28/static` and verified against their manifest.

Candidate path: `/cdn-preview/68eb0cc/`.
Candidate UI origin: `https://trinity.elfenbenstornet.se`.
Node: `https://n5.elfenbenstornet.se/`.
Node credentials: explicit `include`.
Login/logout: `/oauth2/sign_in`, `/oauth2/sign_out`.

The candidate origin is the reachable existing project website, not a claim
that it has been approved in the node/proxy configuration. The artifact has
not been uploaded, and the existing website/demonstrator was not replaced.

## Rebuild on another computer

The ignored package is a local build output, not a prerequisite for continuing.
The committed dependency pins and packaging tools let another computer rebuild
it. In a fresh checkout of the desired committed demonstrator revision, with
Python 3, Git and the tested SWI-Prolog installed:

```sh
python3 tools/fetch_swi.py --destination .trinity/native
python3 tools/fetch_browser.py --destination .trinity/swi-wasm-node
python3 tools/setup_swi.py --native-root .trinity/native
python3 tools/package_demonstrator.py \
  --output .trinity/https-sso-preview \
  --prefix /cdn-preview/68eb0cc/ \
  --node-url https://n5.elfenbenstornet.se \
  --node-credentials include \
  --login-path /oauth2/sign_in \
  --logout-path /oauth2/sign_out
```

Use fresh destination directories. To reproduce the original source revision,
check out `68eb0ccd1d3afd52e20667ea7b55f216aa46d41c` before setup/build; the probe
can be run from the newer checkout containing this report. For a newer candidate,
use a clean checkout and change the preview prefix to identify its revision.
These commands build files locally; they do not publish them or change the node's
proxy/SSO configuration. The candidate origin must still be agreed and configured
before real browser verification.

## Repeatable readiness probe

`tools/probe-cdn-sso.py` performs read-only HTTPS requests with normal certificate
verification, no credentials, and no redirect following. It checks signed-out
metadata, version visibility, JSON preflight and rejection of an unlisted origin.
Its report omits response bodies, cookies, identity headers and redirect query
strings/fragments. Four tests cover URL restrictions, redirect handling,
secret redaction and the distinction between network failure and CORS rejection.
The existing six CI-runner tests also passed.

```sh
python3 tools/probe-cdn-sso.py \
  --node-url https://n5.elfenbenstornet.se \
  --ui-origin https://trinity.elfenbenstornet.se \
  --output /fresh/path/https-readiness.json
```

A successful probe is only readiness for browser testing, never proof of real
SSO. Its unit tests are included in CI; CI does not contact the real provider.

## Required continuation

Restore access to the real node/server or supply the intended reachable HTTPS
SSO test address and access method. Then check its actual proxy policy, qualify
the versioned HTTPS UI from the chosen origin, and run real sign-in, native HTTP
and stateful HTTP, WebSocket paging, logout/expiry and same-origin compatibility.
Production cookie and active-socket lifetime checks remain outstanding. The
stage-5 local fixture results do not substitute for this stage.
