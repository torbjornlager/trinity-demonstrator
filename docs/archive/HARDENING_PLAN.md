# Hardening Plan for Public Deployment

This document is archived. It is kept for historical context and has been superseded by a newer consolidated note.


This document describes what must be done before exposing the system on the
open web, even for a small research alpha (~100 Prolog-savvy users).

The blacklist sandbox with runtime guard rewriting is acceptable as the
language-level layer, provided the real security boundary is outside
SWI-Prolog.

## Mandatory Before Launch

### 1. OS/Container Isolation

The container is the real security boundary. The Prolog-level sandbox is
defense-in-depth.

- Run each public execution context in a container or VM.
- Non-root user inside the container.
- Read-only filesystem, with a tiny writable temp area if needed.
- No secrets, credentials, or host mounts in the container.
- cgroup CPU, memory, and PID limits.
- No outbound network access, or tightly scoped egress rules.

### 2. Restrict or Remove `load_uri/1` for Public Users

`load_uri/1` is currently in the public `private_db` family in
`node_builtin_policy.pl`. The loader in `source_utils.pl` accepts both
local file paths and arbitrary HTTP(S) URIs.

This creates two risks:

- **Local file read**: a `file://` URI or bare path can read server-side
  files, even if the loaded code is then sandboxed.
- **SSRF**: arbitrary HTTP(S) fetches from the server can probe internal
  services and leak information.

Current status: the runtime now supports per-node exact-origin allowlists via
`load_uri_allowed_origins([...])`. When configured, `load_uri` rejects bare
local file paths, `file://` URIs, and HTTP(S) origins outside the configured
set. Relative URIs still work if they resolve to an allowed origin, and HTTP
redirects are only followed when the redirect target is also on the allowlist.

Further hardening plan: keep restricting `load_uri` to the 3–4 known
deployment nodes. This preserves inter-node source loading for the demo while
eliminating the SSRF and local-file-read surface. Additional refinement:

- Use node aliases instead of raw URLs. Configure named nodes (e.g.
  `node_a`, `node_b`) mapped to fixed base URLs in the node
  configuration. Public `load_uri` accepts only these aliases, not
  arbitrary URIs. This removes URL parsing edge cases entirely.
- Block `file://`, `localhost`, `127.0.0.1`, `[::1]`, and other loopback
  forms unconditionally.
- Optionally refuse HTTP redirects entirely. There is no legitimate reason
  for a known node to redirect a source fetch, and refusing redirects is
  simpler and
  safer than validating redirect targets.
- Restrict to known source-serving paths on the allowed nodes, not
  arbitrary endpoints, if possible.
- Treat the allowed nodes as one trust domain: if one node is
  compromised, it can feed source to the others. This is an accepted
  trade-off for the demo topology.

### 3. Non-Open Deployment Configuration

The code defaults are `auth(open)` in `node_auth.pl` and `sandbox(off)` in
`node.pl`. These must never be the live defaults on an internet-facing
deployment.

- Set `sandbox(blacklist)` (or `whitelist`) as the deployment default.
- Set auth mode to something other than `open`. For a research alpha, a
  shared secret, reverse-proxy auth, VPN restriction, or IP allowlist is
  sufficient. A full auth system is not required.

### 4. HTTPS

Serve over HTTPS. Users will be sending Prolog code over the wire. Use a
reverse proxy (nginx, Caddy, etc.) with TLS termination in front of the
SWI-Prolog HTTP server.

### 5. Tighter Resource Limits

The existing limit infrastructure is good but the defaults are generous for
public exposure. Review and lower:

- Inflight call concurrency (`node_limits.pl`, currently 4 per principal).
- Session caps (`node_limits.pl`, currently 8 per principal).
- Rate limits (`node_rate_limits.pl`, currently 500 `/call` requests/min).
- Source text size (`node_input_limits.pl`, currently 262144 bytes).
- Goal execution timeouts (`node.pl`).

Choose values that allow normal interactive use but limit abuse.

## Soon After Launch

### 6. Logging

Log sandbox rejections and execution timeouts. This serves two purposes:

- **Usability**: shows what legitimate users are bumping into.
- **Security**: shows probing attempts and unexpected rejection patterns.

### 7. Adversarial Test Corpus

Build a regression suite of hostile queries, including:

- `open(pipe(...), ...)` — OS command execution via pipe mode.
- Goal construction via `=..`/`functor`/`arg` followed by execution.
- `catch(throw(open(f,r,S)), G, call(G))` — catcher-as-goal.
- Very large terms and deep recursion (memory/stack bombs).
- Weird DCG edge cases.
- Dynamic DB tricks (`assert` + `clause` + `call` chains).
- `load_uri` deny/allow boundary cases.
- Exception formatting with stale module references.
- Random/fuzzed goal terms.

### 8. Audit Non-ISO Auto-Imported SWI Predicates

The blacklist was assembled from the `iso` predicate property. Dangerous
SWI-specific predicates that are auto-imported into user modules are not
covered by that inventory. Run:

```sh
swipl -q -g "forall((current_predicate(system:Name/Arity), functor(H,Name,Arity), \+ predicate_property(system:H, iso)), writeln(Name/Arity)), halt." | sort
```

Scan the output for predicates involving streams, files, processes, OS
access, or global state mutation. Add any dangerous ones to
`blacklisted_goal_pattern/2`.

Known candidates to check: `process_create/3`, `copy_stream_data/2-3`,
`read_term_from_atom/3`, `term_to_atom/2`, `term_string/2`, `format/2-3`
(stream-directed), `with_output_to/2`.
