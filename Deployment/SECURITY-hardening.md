# Node security hardening

How a public web-prolog node is kept from being turned into arbitrary code
execution, and what is left to the deployment. There are two layers: the
**in-process sandbox** (what a client goal may call) and **OS containment**
(what the node process can do to the host even if the sandbox is bypassed).

## 1. In-process sandbox (`node_sandbox.pl`)

Two modes, selected per node by `WP_SANDBOX`:

- **`whitelist`** — every goal must pass `library(sandbox)`'s `safe_goal/1`
  (a strict static allowlist). Strongest, but it rejects the runtime-bound
  `assert`/`format/3`/`call/1`/shared-DB operations that the isotope and
  relation profiles are built around, so those profiles are largely unusable
  under it.
- **`blacklist`** (the default, and what the demonstrator's profiles need) —
  a curated **denylist** (`blacklisted_goal_pattern/2`): I/O streams, threads,
  shell, reflection, and the dangerous **process / filesystem / network /
  environment / native-code** families. Everything else — including the
  permissive dynamic operations — is allowed.

Chart-embedded goals (`<onentry>/<onexit>/<go>` scripts and transition
conditions) are **not** exempt: they are routed through the sandbox via
`statechart_runtime:hook_check_chart_goal/1` (glue in `node_glue.pl`) whenever
a public execution profile is active, so a client `statechart_spawn(load_text(...))`
cannot run dangerous predicates through its scripts. Trusted desktop/test
charts install no hook and are unaffected.

### Known limit of the denylist
A denylist stops **direct** dangerous calls, but it **cannot** stop a goal
*constructed at runtime* and invoked through `call/1`:

```prolog
?- C = process_create(path(sh), ['-c', '...'], []), call(C).
```

`call/1` of a runtime goal is a deliberate isotope-profile feature, and the
offending predicate is invisible to a static check. Closing this requires
either `whitelist` mode or OS containment (§3). **Treat OS containment as the
real boundary for any `WP_AUTH=open` node.**

### `rpc/3` target host is not allowlisted
`load_uri` is restricted to `load_uri_allowed_origins`, but `rpc(URL, Goal)`
will connect to **any** `URL` (`rpc.pl`, `resolve_rpc_uri/2`). It is therefore
an SSRF channel and is bounded only by the network egress policy (§4).

## 2. Container hardening (in compose)

Both `compose.yaml` (n1–n5, admin) and `compose.elfenbenstornet.yaml` (n0, n5)
now run each node with:

- non-root user (`Dockerfile.node`, uid 10001),
- `read_only: true` root filesystem + `tmpfs: /tmp` + `HOME=/tmp`,
- `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`,
- writable state only on the log volume (`/var/lib/web-prolog` or
  `/var/log/webprolog`),
- `init: true`, `mem_limit`/`cpus`, and node HTTP ports bound to `127.0.0.1`
  (only Caddy is published).

These do not affect any tutorial or example: file-writing predicates are
already sandbox-denied, the node writes only to the log volume and the tmpfs,
and the discovery hub's register is in-memory.

## 3. Exec backstop — AppArmor (not seccomp)

A seccomp profile that denies `execve` cannot be used: it also blocks the
runtime's exec of the entrypoint, so the container never starts. Use the
AppArmor profile in `Deployment/apparmor/web-prolog-node` instead — it denies
`execve` of any binary **after** start, closing the `call/1`→`process_create`
residual at the kernel level while leaving SWI-Prolog (which never legitimately
execs) fully functional.

Roll out **in complain mode first**, validate the full example suite, then
enforce and add `apparmor=web-prolog-node` to each node's `security_opt`
(instructions in the profile header). Hosts without AppArmor can instead use a
distroless/minimal node image with no shell to exec.

## 4. Network egress

Nodes reach peers via public DNS (`rpc('https://n2.elfenbenstornet.se', …)`
exits to Caddy's public IP and returns), so **do not blanket-block egress** —
it breaks the cross-node `rpc`/`load_uri` tutorials. Scope it instead.

**Do now (one-liner, cannot break examples):** drop the cloud metadata
endpoint, the highest-value SSRF/credential-theft target:

```sh
iptables -I DOCKER-USER -d 169.254.169.254 -j DROP
```

**Fuller measure (recommended, infra layer):** an egress *allowlist* — permit
only the cluster hosts (`*.elfenbenstornet.se`), the ACME endpoint
(Let's Encrypt), the SSO provider (GitHub, for `oauth2_n5`), and DNS; deny the
rest. Because ACME/GitHub are CDN-fronted (changing IPs), do this with an
FQDN-aware control: a cloud security group / firewall that supports FQDN
rules, or a small egress-proxy sidecar with a domain allowlist. This preserves
every example (cluster traffic + the two known external endpoints) while
blocking arbitrary SSRF/exfil — and is what bounds the `rpc/3` target-host gap
(§1) and the `call/1` residual.

A Docker-only alternative is a dual-network split (nodes on an `internal: true`
network; Caddy/oauth2 on an egress-capable one, with Caddy network-aliased for
the peer hostnames). It works but reroutes cross-node traffic through Caddy —
validate node→n5 health probes against n5's `forward_auth` vhost before relying
on it.

## Deployment checklist

- [x] In-process sandbox: denylist completed for process/file/network/foreign;
      chart scripts routed through it.
- [x] Container hardening: read-only FS, dropped caps, non-root, no-new-privs,
      loopback-bound ports (both compose stacks).
- [ ] AppArmor `web-prolog-node`: load in complain mode, validate, enforce, add
      to `security_opt`.
- [ ] Egress: drop `169.254.169.254` now; add the FQDN allowlist (infra) for
      full SSRF/exfil containment.
- [ ] Consider `WP_SANDBOX=whitelist` for any node that does not need the
      isotope/relation dynamic operations, as the strongest in-process option.
