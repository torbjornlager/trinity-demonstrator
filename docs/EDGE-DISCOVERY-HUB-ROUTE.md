# Serve `/discovery-hub` from N0, not from an edge copy

Prepared 23 November 2026 for the next release. A Claude Code session on
Torbjörn's Mac carries it out, following `HANDOVER.md` §9–10. Tell him before
the live switch and stop if a check fails.

## Why

The live edge (`deployment-caddy-1`) answers `https://n0.elfenbenstornet.se/discovery-hub`
with a static file from the `deployment_edge_assets` volume
(`/srv/trinity/portable-20261112-zsn664hr/hub/discovery-hub.html`). N0 serves the
same page from its own image (`node_discovery_hub_page/1` in `swi-prolog-node`,
file `web/discovery-hub.html` from the pinned demonstrator).

The two copies drift. On 22 November N0 moved to `node_directory_row/10`, but
the edge copy still asked for `/9`, and the page showed "Hub unreachable" until
the edge file was replaced by hand. With the route going to N0, the page always
comes from the same image as the relations it queries.

`Deployment/Caddyfile` in this repository already does this: the `n0` site
proxies `/discovery-hub` and `/admin/tabler.min.css` to `n0:3060`. Only the live
edge configuration differs.

## Where the live configuration is

- Caddyfile: `/etc/caddy/Caddyfile` in `deployment-caddy-1`, on the named volume
  `deployment_edge_config_compose`. It may `import` further files from the same
  volume.
- Static assets: `/srv/trinity` on the named volume `deployment_edge_assets`.

Neither is in Git, so start by capturing both (§1).

## Steps

1. **Capture the predecessor** in a new private directory under `.trinity/`:
   `docker exec deployment-caddy-1 cat /etc/caddy/Caddyfile`, every file it
   imports, the edge-asset file
   `/srv/trinity/portable-20261112-zsn664hr/hub/discovery-hub.html`, and its
   sha256. Record the Caddy container and image IDs.
2. **Find the override.** In the `n0.elfenbenstornet.se` site block, find the
   matcher or `handle` that serves `/discovery-hub` (and possibly
   `/admin/tabler.min.css`) with `root`/`file_server` from
   `/srv/trinity/...hub/`. Note its exact text.
3. **Check N0 serves the page itself** before changing anything:
   `docker exec deployment-caddy-1 wget -qO- http://n0:3060/discovery-hub | grep -c PROFILE_ROUTES`
   must print a non-zero count, and `http://n0:3060/admin/tabler.min.css` must
   return 200. (Use `curl` if the image has it instead of `wget`.)
4. **Edit a copy** of the Caddyfile: remove that override so `/discovery-hub` and
   `/admin/tabler.min.css` fall through to the site's existing
   `reverse_proxy n0:3060` (both must be in its allowed-path matcher, as in
   `Deployment/Caddyfile`). Change nothing else.
5. **Validate** the edited copy in a disposable Caddy of the same image:
   `caddy validate --config <copy> --adapter caddyfile`, with the same imports.
6. **Switch:** install the edited Caddyfile in the volume and reload gracefully
   (`docker exec deployment-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`).
   Do not recreate the container.
7. **Check:**
   - `curl -sI https://n0.elfenbenstornet.se/discovery-hub` no longer shows the
     edge file's `Last-Modified`/file-server `ETag`; the body contains
     `PROFILE_ROUTES` and `Implementation,Version,Description`.
   - The page shows "8 up", every node's engine and description, and no
     "Hub unreachable".
   - `https://n0.elfenbenstornet.se/admin/tabler.min.css` returns 200.
   - The other origins are unchanged: `/demonstrator` on N1 and N4 loads the
     examples and editor, and N7's `/demonstrator` opens its own UI.
8. **Record** the change in a verification note and in `HANDOVER.md`, replacing
   the paragraph about the hub page in the edge volume. Leave the old edge file in
   place; it is no longer served.

## Rollback

Restore the captured Caddyfile (and imports) into the volume and reload
gracefully. The edge file was left untouched, so the previous behaviour returns
exactly.
