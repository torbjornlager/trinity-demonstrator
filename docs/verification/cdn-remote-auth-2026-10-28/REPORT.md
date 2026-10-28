# CDN remote-node authentication — 28 October 2026

Stage 5 adds explicit cookie credentials for the configured node, node-origin
sign-in/sign-out links, reconnect handling, 401 session cleanup and a repeatable
real-native integration fixture. Same-origin defaults and runtime pins are unchanged.

## Actual browser checks

A static UI at `http://localhost:64810` contacted an authenticating proxy at
`http://localhost:58426`, backed by a disposable private SWI node at port 58425.
The UI first showed no execution access and a readable 401. Top-level node-origin
login set an HttpOnly test-session cookie. Reconnect identified `cdn-test-user`;
WebSocket `member(X,[a,b])` returned and paged both answers.

The browser HTTP harness passed cookie omission (401), authenticated native
identity, stateless first/next pages, JSON preflight, stateful session creation,
call/next/cleanup and identity-header preflight rejection. A UI origin at port
64811 could neither read HTTP replies nor upgrade a WebSocket. Expiring the test
session closed its fixture socket; Reconnect returned the UI to no execution
access with a readable 401.

The checks were repeated using **different hostnames on the same site**:
`http://ui.localtest.me:64810` and `http://node.localtest.me:58429`, backed by a
second private native test node. DNS resolution was checked: both names resolved
to 127.0.0.1. Eleven browser harness checks passed, including a server-side probe
confirming that the node cookie was absent from UI-host requests and unreadable
to UI JavaScript. Authenticated HTTP/stateful HTTP and WebSocket execution passed.
Clicking the UI Sign out link retired its open query/connection before opening
the node's logout page; completing node logout made Reconnect return 401.

These are actual browser CORS/cookie checks, not HTTP-client simulations.
The login application is a disposable fixture, not a real SSO provider.

## Automated and compatibility checks

- 19 real private-native/proxy checks passed: readable 401, strict origin policy,
  unauthenticated preflight, header rejection/stripping, native execution,
  WebSocket admission, logout, expiry and reconnect.
- All 46 Python startup/packaging tests passed, including cookie/session build
  configuration validation. Host/presenter routing, 401 cleanup, endpoint escape
  and legacy runtime identity tests passed.
- The existing WASM tier passed 102 scenarios and 71 Prolog tests, including
  runtime and consumer examples, bridges and schema/algorithm guards.
- A disposable dev-mode node served the original same-origin demonstrator at
  port 58431. Its native WebSocket query and paging worked. No session controls
  appeared without static session configuration.

See [machine results](results.json), [automated native checks](native-integration.log),
[distinct-host browser HTTP/cookie checks](distinct-host-http.png),
[distinct-host WebSocket](distinct-host-ws.png), [denied origin](denied-origin.png),
[expiry](expired-session.png), [logout](logged-out.png), and
[same-origin compatibility](same-origin-native.png).

## Scope and remaining production qualification

All proxies/nodes were disposable loopback services. No real password/token was
entered, and no cookie value is included in the evidence. No live n3/n5 or Caddy
configuration was changed. The fixture explicitly revokes its own sockets on
logout/expiry; this is not a claim that the production provider does so.

Actual HTTPS CDN/SSO callback behaviour, production cookie attributes, browser
third-party-cookie policy, per-node admission and the lifetime of sockets in
other tabs still need qualification from the chosen deployment origin. Native
UI HTTP/WebSocket carriers were tested; authenticated private-peer RPC from the
independent SWI-WASM runtime is not changed or certified by these checks.

Configuration and required scoped proxy policy are documented in
[CDN_REMOTE_AUTH.md](../../CDN_REMOTE_AUTH.md).
