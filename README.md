# Web Prolog PoC (SWI-Prolog)

A clarity-first proof-of-concept implementation of Web Prolog ideas in
SWI-Prolog.

The code in this repository prioritizes understandability over production
hardening. The goal is to make core ideas easy to read, test, and port to
other Prolog systems.

## What This Repository Contains

- Erlang-style actor runtime and actor-local code loading
- Toplevel/session actors for shell-like workflows
- Generic servers and Erlang-style supervisors
- Statechart actors
- Stateless HTTP, semi-stateful HTTP, and stateful WebSocket node APIs
- Browser tooling: demonstrator, tutorial, logger, admin panel, editors
- Docker deployment bundle for the public node setup

## Quick Start

Load the core modules:

From the repository root:

```bash
swipl load.pl
```

Start a local node:

```prolog
?- [load].
?- node(3010).
true.
```

Then try the stateless API in a browser:

- [http://localhost:3010/call?goal=member(X,[a,b])&format=prolog](http://localhost:3010/call?goal=member(X,[a,b])&format=prolog)

## Run Tests

Run the full suite:

From the repository root:

```bash
swipl -q -s test.pl -g test -t halt
```

## Documentation Map

### Start Here

- [ARCHITECTURE.md](ARCHITECTURE.md)
  High-level structure of the runtime, node layer, and request flows.
- [CROSS_NODE_ARCHITECTURE.md](CROSS_NODE_ARCHITECTURE.md)
  Detailed specification of the cross-node actor layer: wire
  protocol, controller tables, dispatch algorithm, lifecycle
  invariants.  Written so a port to another Prolog system can be
  checked against it line-by-line.
- [WEB_PROLOG_BUILTINS.md](WEB_PROLOG_BUILTINS.md)
  Canonical built-ins catalog for the ACTOR profile surface.
- [WEB_PROLOG_BUILTINS_ACCEPTANCE_MATRIX.md](WEB_PROLOG_BUILTINS_ACCEPTANCE_MATRIX.md)
  Route-by-route verification of what client code is actually accepted.
- [DEMONSTRATOR.md](DEMONSTRATOR.md)
  Current architecture and status of the browser demonstrator.

### Editing, Deployment, and Operations

- [EDITING_AND_DEPLOYING.md](EDITING_AND_DEPLOYING.md)
  Safe workflow for editing tutorial content and shared databases, then deploying.
- [Deployment/README.md](Deployment/README.md)
  Deployment bundle layout and Docker-oriented operational notes.
- [ADMIN-DEPLOYMENT-MANUAL.public.md](ADMIN-DEPLOYMENT-MANUAL.public.md)
  Operator manual for a Docker-based deployment of the public Web Prolog nodes.
- [ADMIN_TOOLS.md](ADMIN_TOOLS.md)
  User guide for the demonstrator admin panel and admin API surface.

### Policy and Security

- [SECURITY_REPORT.md](SECURITY_REPORT.md)
  Consolidated description of the demonstrator's security posture:
  threat model, defences, known limitations, and what would change
  for a production deployment.
- [AUTH_AND_PROFILE.md](docs/policy/AUTH_AND_PROFILE.md)
  Canonical summary of authentication, authorization, profile enforcement, and ownership.
- [PROFILE_MATRIX.md](PROFILE_MATRIX.md)
  Current profile contract matrix.
- [SANDBOX_AND_HARDENING.md](docs/policy/SANDBOX_AND_HARDENING.md)
  Canonical summary of sandboxing, security boundaries, and public-deployment hardening.
- [BLACKLIST_SANDBOX_NOTES.md](docs/policy/BLACKLIST_SANDBOX_NOTES.md)
  Detailed blacklist rationale and sandbox inventory notes.

### Book and Manuscript Alignment

- [IMPLEMENTATION_ALIGNMENT.md](docs/book/IMPLEMENTATION_ALIGNMENT.md)
  Consolidated comparison between the implementation and the current book-facing descriptions.

### Examples and Side Documents

- [examples/services/README.md](examples/services/README.md)
  Node-resident service publication and discovery example.
- [poc-libraries/TREALLA_PORT.md](poc-libraries/TREALLA_PORT.md)
  Porting notes for the smaller actors library on Trealla Prolog.

### Historical Documents

- [docs/archive/README.md](docs/archive/README.md)
  Archived plans and superseded notes removed from the repository root.

## Security Note

Do not expose this node publicly without the deployment hardening described in
[ADMIN-DEPLOYMENT-MANUAL.public.md](ADMIN-DEPLOYMENT-MANUAL.public.md),
[Deployment/README.md](Deployment/README.md), and
[SANDBOX_AND_HARDENING.md](docs/policy/SANDBOX_AND_HARDENING.md).

In particular, public deployment should rely on container isolation,
reverse-proxy control, and resource limits rather than trusting Prolog-level
sandboxing alone.

## License

MIT. See `LICENSE`.
