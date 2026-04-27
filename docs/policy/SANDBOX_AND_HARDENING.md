# Sandbox and Hardening

This document is the canonical summary of the current sandbox model and the
minimum hardening expected for public deployment.

It consolidates the former `SANDBOX_PLAN.md` and `HARDENING_PLAN.md` notes.
Detailed blacklist rationale is kept separately in
[BLACKLIST_SANDBOX_NOTES.md](docs/policy/BLACKLIST_SANDBOX_NOTES.md).

## Current Model

The node currently treats sandboxing as a safety layer over the advertised node
profile, not as a separate profile-narrowing mechanism.

Current contract:

- canonical sandbox modes are `off`, `whitelist`, and `blacklist`
- the current default/public mode in this repo is `sandbox(blacklist)`
- legacy values `on`, `demo`, and `strict` are still accepted, but they
  normalize to `whitelist`, not to `blacklist`
- `blacklist` is the practical public-deployment mode currently described by
  this document
- controller-owned and nested actor/toplevel source-loading paths go through
  the same validated rewrite for `load_uri/1`

Implementation note:

- only `whitelist` mode currently adds SWI's `sandboxed(true)` loader option
- `blacklist` mode instead relies on prevalidation plus the custom blacklist
  checks in `node_sandbox.pl`

The goal is to make every public execution path enforce the same safety policy
for:

- untrusted goals
- untrusted source text
- untrusted spawn options

## What the Sandbox Covers

User-controlled execution paths include:

- stateless HTTP `/call`
- ISOTOPE `/toplevel_spawn`
- ISOTOPE `/toplevel_call`
- WebSocket `toplevel_spawn`
- WebSocket `toplevel_call`
- WebSocket bare `spawn`

User-controlled source-loading paths include:

- `load_text/1`
- `load_list/1`
- `load_uri/1`
- `load_predicates/1`

The main enforcement code lives in
[node_sandbox.pl](node_sandbox.pl).

## What the Sandbox Does Not Solve

`library(sandbox)` helps with goal and clause safety. It does not solve the
whole deployment problem.

In particular, it does not by itself solve:

- resource exhaustion
- queue flooding
- capability abuse through raw WebSocket commands such as `send` and `exit`
- container escape or host-level compromise

That is why the real security boundary must remain outside Prolog.

## Blacklist Model

The current public safety story relies on a blacklist-oriented sandbox plus
runtime guard rewriting.

Important practical points:

- ambient stream and file I/O are denied
- runtime reflection and parser mutation are tightly constrained
- source text is checked before it reaches actor/session private modules
- `clause/2` survives only in a narrowed local-private-module form

For the detailed first-pass inventory and rationale, see
[BLACKLIST_SANDBOX_NOTES.md](docs/policy/BLACKLIST_SANDBOX_NOTES.md).

## `load_uri/1` Status

`load_uri/1` is one of the main remaining deployment-sensitive features.

Current status:

- the runtime supports per-node exact-origin allowlists via
  `load_uri_allowed_origins([...])`
- when configured, bare local paths, `file://` URIs, and arbitrary HTTP(S)
  origins outside the configured set are rejected
- relative URIs still work if they resolve to an allowed origin
- redirects are only followed when the redirect target is also on the allowlist

This is the main mitigation against SSRF and server-side local file reads while
preserving inter-node source loading for the demo topology.

## Mandatory Before Public Exposure

### 1. Container or VM Isolation

The container is the real security boundary. The Prolog sandbox is
defense-in-depth.

Minimum expectation:

- non-root runtime user
- read-only filesystem except for a tiny writable temp area if needed
- no host mounts containing secrets
- CPU, memory, and PID limits
- no unrestricted outbound network access

### 2. Non-Open Runtime Configuration

Public deployment must not run with permissive defaults.

Minimum expectation:

- sandbox enabled
- auth mode not `open`
- reverse-proxy or equivalent trust boundary in front of the node

### 3. HTTPS and Reverse Proxying

Users send Prolog source and commands over the wire. TLS is therefore not
optional on public deployments.

### 4. Tighter Limits

For public exposure, review and lower:

- inflight call concurrency
- session caps
- actor caps
- rate limits
- source text size
- execution timeouts

## Important Remaining Risks

Even with sandboxing enabled, the major deployment-sensitive concerns still
include:

- reverse-proxy trust boundary correctness
- load-uri trust domain design
- process-global fallback behavior for local in-process experimentation
- insufficient logging or adversarial regression coverage

## Recommended Next Hardening Steps

1. make the reverse-proxy trust boundary explicit in deployment docs and startup messaging
2. keep `load_uri` constrained to known nodes or aliases in public deployments
3. log sandbox rejections and execution timeouts
4. build and maintain an adversarial regression corpus
5. audit non-ISO auto-imported SWI predicates for dangerous ambient behavior

## Companion Documents

- [BLACKLIST_SANDBOX_NOTES.md](docs/policy/BLACKLIST_SANDBOX_NOTES.md)
  Detailed blacklist rationale and inventory notes.
- [PROFILE_MATRIX.md](PROFILE_MATRIX.md)
  Contract matrix the sandbox is expected to preserve.
- [docs/archive/SANDBOX_PLAN.md](docs/archive/SANDBOX_PLAN.md)
  Archived detailed sandbox integration plan.
- [docs/archive/HARDENING_PLAN.md](docs/archive/HARDENING_PLAN.md)
  Archived public-hardening note.
