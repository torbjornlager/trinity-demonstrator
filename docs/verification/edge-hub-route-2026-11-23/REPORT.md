# Edge hub route — live verification, 23 November 2026

**Deployed and verified.** `/discovery-hub` on `n0.elfenbenstornet.se` is now
proxied to N0 (`n0:3060`) by Caddy instead of served as a static file from
the `deployment_edge_assets` volume.

## What changed

The N0 site block in `/etc/caddy/Caddyfile` (on the `deployment_edge_config_compose`
volume) previously contained:

```
@n7_discovery_asset {
    method GET
    path /discovery-hub
}
handle @n7_discovery_asset {
    root * /srv/trinity/portable-20261112-zsn664hr/hub
    rewrite * /discovery-hub.html
    header Cache-Control "no-cache"
    file_server
}
```

This 11-line block was removed. `/discovery-hub` and `/admin/tabler.min.css` were
already in the site's `@allowed` path matcher and therefore fall through to the
existing `reverse_proxy n0:3060`. Nothing else was changed.

## Pre-change checks (from inside deployment-caddy-1)

- `curl -s http://n0:3060/discovery-hub | grep -c PROFILE_ROUTES` → `3`
- `curl -sI http://n0:3060/admin/tabler.min.css` → `HTTP/1.1 200 OK`
- Both `/discovery-hub` and `/admin/tabler.min.css` present in `@allowed` matcher

## Caddy predecessor captured

- Caddyfile, `n7.Caddyfile`, `n7-ingress.Caddyfile` saved to
  `.trinity/edge-hub-route-20261123/private/`
- Edge file `portable-20261112-zsn664hr/hub/discovery-hub.html`
  sha256 `51add514…` saved; file left in place (no longer served)
- Caddy container `56591dbdf62b`, image `sha256:95a6701892f9`

## Validation

Candidate Caddyfile validated in a throwaway Caddy of the same image:
`caddy validate --config ... --adapter caddyfile` → `Valid configuration`.
Same pre-existing warnings as previous reloads; no errors.

## Checks after graceful reload

| Check | Result |
|-------|--------|
| `/discovery-hub` ETag/Last-Modified absent (proxied, not file-server) | ✓ |
| Body contains `PROFILE_ROUTES` (3×) | ✓ |
| Body contains `Implementation`, `Description` | ✓ |
| Hub rows: 8 up, all engines and descriptions correct | ✓ |
| `/admin/tabler.min.css` HTTP 200 | ✓ |
| N1 `/demonstrator`: editor + examples present | ✓ |
| N4 `/demonstrator`: editor + examples present | ✓ |
| N7 `/demonstrator`: own UI, no `/index.html` redirect | ✓ |

## Rollback

Copy `.trinity/edge-hub-route-20261123/private/Caddyfile` back into the volume
and reload gracefully. The edge file is untouched so the previous behaviour
returns exactly.
