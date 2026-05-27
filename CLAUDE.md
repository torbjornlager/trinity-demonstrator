# Notes for Claude

## Interaction-log tagging

When you (Claude) make HTTP requests against the **deployed** demonstrator
nodes (`*.elfenbenstornet.se`, or any host running this stack), always
include the agent header so the interaction log can distinguish your
traffic from real public visitors and from the owner's own browsing.

The token lives on the user's machine in the environment variable
`WEB_PROLOG_AGENT_TOKEN` (typically loaded from `Deployment/.env` or the
user's shell). Read it from the environment — never hardcode it.

### curl

```bash
curl -H "X-WP-Agent: $WEB_PROLOG_AGENT_TOKEN" https://n3.elfenbenstornet.se/...
```

### Inside `docker compose exec`

The token is also injected into the containers, so when issuing requests
from inside a container you can do the same:

```bash
docker compose exec -T wp_n3 sh -c \
  'curl -H "X-WP-Agent: $WEB_PROLOG_AGENT_TOKEN" http://localhost:3053/...'
```

### What this affects

Every interaction log line emitted while servicing such a request gets
`"agent":"claude"` added. The secret viewer
(`/__viewer/<WEB_PROLOG_VIEWER_TOKEN>`) hides agent traffic by default,
and offers a **Public only** checkbox that hides both `owner` and
`agent` lines so the user can see only real public visitors.

### When *not* to send it

- Requests against **local** dev servers that are not the deployed stack
  (e.g. ad-hoc `swipl` test servers) — no log is being filtered there.
- Requests where you're explicitly testing the public-visitor code path
  and want to see what an untagged request looks like. Say so in your
  reply when you do this.

If `WEB_PROLOG_AGENT_TOKEN` is unset in the environment, just omit the
header — the server will silently treat the request as public, which is
the correct fallback.
