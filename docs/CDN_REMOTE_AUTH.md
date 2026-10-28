# Static UI: remote-node connections and authentication

Stage 5 verifies the static demonstrator against a real private SWI node behind
an authenticating proxy on a different origin. No native runtime changes or
live-node configuration changes are required for the local checks.

## UI configuration

For an operator-approved, cookie-authenticated service:

```sh
python3 tools/package_demonstrator.py \
  --output .trinity/auth-preview --prefix /releases/auth-preview/ \
  --node-url https://node.example.com \
  --node-credentials include \
  --login-path /oauth2/sign_in --logout-path /oauth2/sign_out \
  --allow-dirty
```

The paths must be node-relative, without query strings, fragments or credentials.
They are addresses for the existing node's login/logout application; the static
UI does not implement a login provider or obtain a password/token. The build
contains no authentication secrets. Release builds still require clean source
and omit `--allow-dirty`.

`credentials` defaults to `same-origin`, preserving the existing node-hosted
behaviour. Explicit `include` applies to the configured node's HTTP requests,
not to the UI's example downloads. WebSocket cookies are managed by the browser.
Session links require a configured node and explicit cookie inclusion. Node
endpoint resolution rejects attempts to escape the configured service base.

The static UI provides **Sign in to node**, **Sign out**, and **Reconnect**.
Login opens the node's own page in another tab. Reconnect retires the old local
transport and refreshes node metadata. Signing out closes the current UI's
sessions before opening the node's logout page. A 401 response clears stale
execution authorization; returning focus to a cookie-enabled static UI refreshes
its node identity. Browser-only SWI-WASM sessions are not retired by these controls.

## Required node/proxy policy

The test proxy demonstrates this policy. It is a disposable fixture, not a
production authentication service or a replacement for oauth2-proxy.

- For approved static UI origins, API replies include the exact
  `Access-Control-Allow-Origin`, `Access-Control-Allow-Credentials: true`,
  `Vary: Origin`, and `Cache-Control: no-store`. Wildcard origins are unsuitable
  for credentialed responses. The browser must be able to read 401 replies too.
- Allow unauthenticated OPTIONS preflight only for the selected execution routes,
  GET/POST, and needed request headers (Content-Type). Reject identity-header
  preflights, unlisted origins and unnecessary routes. Preflight success does
  not authorize the actual request.
- An unauthenticated API request returns 401, without redirecting fetch to an
  HTML login/provider page. Top-level node login keeps its normal flow.
- Strip client-supplied identity, capability and forwarded headers at the edge.
  Verify the session, then supply the verified identity to the private native
  backend. The node's principal/capability policy still decides execution access.
- Add the exact UI origin to `WP_WS_ALLOWED_ORIGINS` on the intended node.
  WebSocket origin admission and authenticated upgrade are separate checks.
- Keep session cookies host-only on the node and HttpOnly. Production uses HTTPS
  and Secure cookies. A UI and node on different subdomains of the same site can
  use the provider's same-site cookie policy; unrelated sites may require
  SameSite=None and can still be blocked by third-party-cookie settings.

These requirements follow [credentialed CORS](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS)
and [cookie attributes](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie).
For Caddy's authentication-response handling, see its official
[forward_auth documentation](https://caddyserver.com/docs/caddyfile/directives/forward_auth).
The existing deployment Caddyfile is unchanged: its public GET-only wildcard
CORS snippet and private-node login redirects are not a ready-made credentialed
CDN API policy. An operator must apply the scoped policy after selecting the
real UI origin; do not globally turn on credentialed CORS.

## Session lifetime and remaining deployment qualification

Logging out of the UI closes its current connections. Deleting or expiring a
cookie alone does not revoke an already authenticated WebSocket in other tabs:
the proxy/node must explicitly close it, or impose an appropriate connection
lease and require authentication on reconnect. The test proxy revokes its own
sockets on logout/expiry; that is a fixture guarantee, not a claim about the
current production SSO proxy.

The browser checks cover different ports and two different hostnames on the
same site: `ui.localtest.me` and `node.localtest.me`, both verified to resolve to
127.0.0.1 during the run. The actual private native node executes the goals.
The host-only session cookie reaches the node, is absent from UI-host requests,
and is unreadable to UI JavaScript. The HTTP fixture uses a short-lived test
identity and no real user credentials; it does not verify TLS or an external
identity provider.

Before deployment, repeat the checks from the actual HTTPS CDN origin with the
real provider, cookie attributes, browser privacy settings, node capabilities,
and WebSocket revocation policy. No claim is made that all live nodes admit the
new origin. Independently hosted SWI-WASM runtime RPC authentication to private
peers is outside these native UI carrier checks; its existing transport/source
restrictions and credential behaviour are unchanged.

## Repeatable checks

After normal dependency setup:

```sh
SWIPL=/path/to/verified/swipl node tools/test-cdn-remote.cjs
node tools/test-trinity-host.cjs
```

The integration runner starts a disposable private native node and loopback
proxy, then cleans both up. It tests authorization, exact-origin policy,
preflight, identity stripping, real execution, WebSocket upgrade, logout,
expiry and reconnection. It never restarts n3/n5. It is included in the CI plan.

`tests/fixtures/cdn_browser_checks.html` is the manual real-browser harness. The
saved [verification record](verification/cdn-remote-auth-2026-10-28/REPORT.md)
contains the tested origins, procedure, results and screenshots. Browser tests
are distinct from the automated HTTP checks: only a real browser proves CORS
and cookie enforcement.
