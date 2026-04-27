# Editing And Deploying Content

This is the safe workflow for changing tutorial content and node-resident
shared database predicates without editing stale copies inside Docker
containers.

## Rule 1: Edit Host Files, Not Container Files

Use the files in the repository as the source of truth.

In this project, `/app` is the path inside the Docker containers where the
repository is copied at image-build time; it is not a directory on your Mac
that you should edit.

Do not edit files inside running containers such as:

- `/app/tutorial.html`
- `/app/Deployment/shared_db_common.pl`
- `/app/Deployment/shared_db_n1.pl`
- `/app/Deployment/shared_db_n2.pl`
- `/app/Deployment/shared_db_n3.pl`
- `/app/Deployment/shared_db_n4.pl`
- `/app/Deployment/shared_db_admin.pl`

Those copies are disposable. They are replaced the next time the relevant
containers are rebuilt.

## Tutorial Workflow

Canonical source file:

- [`tutorial.html`](tutorial.html)

Recommended pattern:

1. Edit [`tutorial.html`](tutorial.html).
2. Save it.
3. Rebuild the nodes that should serve the new tutorial.

For the public tutorial nodes `n3` and `n4`:

```bash
docker compose -f Deployment/compose.yaml up --build -d wp_n3 wp_n4
```

If you want every deployed node rebuilt:

```bash
docker compose -f Deployment/compose.yaml up --build -d
```

Verification URLs:

- [n3 tutorial](https://n3.elfenbenstornet.se/tutorial)
- [n4 tutorial](https://n4.elfenbenstornet.se/tutorial)

## Shared Database Workflow

The deployment loads one common shared database file plus one node-specific
overlay per node.

Common file loaded by all deployed nodes:

- [`Deployment/shared_db_common.pl`](Deployment/shared_db_common.pl)

Node-specific overlays:

- `n1` -> [`Deployment/shared_db_n1.pl`](Deployment/shared_db_n1.pl)
- `n2` -> [`Deployment/shared_db_n2.pl`](Deployment/shared_db_n2.pl)
- `n3` -> [`Deployment/shared_db_n3.pl`](Deployment/shared_db_n3.pl)
- `n4` -> [`Deployment/shared_db_n4.pl`](Deployment/shared_db_n4.pl)
- `admin` -> [`Deployment/shared_db_admin.pl`](Deployment/shared_db_admin.pl)

How to decide what to edit:

- Put predicates used by every node in `shared_db_common.pl`.
- Put predicates specific to one node in that node's overlay file.
- For public ACTOR demos, edit `shared_db_n3.pl` and/or `shared_db_n4.pl`.

How to decide what to rebuild:

- If you change `shared_db_common.pl`, rebuild all affected nodes.
- If you change only `shared_db_n3.pl`, rebuild only `wp_n3`.
- If you change only `shared_db_n4.pl`, rebuild only `wp_n4`.
- If you change both `shared_db_n3.pl` and `shared_db_n4.pl`, rebuild both.

Examples:

Rebuild only `n3`:

```bash
docker compose -f Deployment/compose.yaml up --build -d wp_n3
```

Rebuild only `n4`:

```bash
docker compose -f Deployment/compose.yaml up --build -d wp_n4
```

Rebuild both public ACTOR nodes:

```bash
docker compose -f Deployment/compose.yaml up --build -d wp_n3 wp_n4
```

Rebuild all nodes because the common shared DB changed:

```bash
docker compose -f Deployment/compose.yaml up --build -d
```

## Practical Pattern To Use With Codex

For tutorial-only edits, use this pattern:

1. Edit [`tutorial.html`](tutorial.html).
2. Tell Codex: `Deploy tutorial.html`.

For shared database edits, use this pattern:

1. Edit the relevant shared DB file under `Deployment/`.
2. Tell Codex which node should be rebuilt, for example:
   - `Deploy shared_db_n3.pl`
   - `Deploy shared_db_n3.pl and shared_db_n4.pl`
   - `Deploy shared_db_common.pl everywhere`

For mixed changes, be explicit:

- `Deploy tutorial.html and shared_db_n3.pl`
- `Deploy tutorial.html, shared_db_n3.pl, and shared_db_n4.pl`

## Why This Pattern Is Safe

- The repository files are the only authoritative copies.
- Docker images are rebuilt from those files.
- You never need to remember whether a container contains an older manual edit.
- The rebuild scope stays clear: tutorial file by itself, node overlay by node,
  or all nodes when the common shared DB changes.
