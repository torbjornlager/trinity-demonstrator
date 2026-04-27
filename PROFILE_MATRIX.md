# Profile Contract Matrix

This document records the current intended profile contract of the Web Prolog
PoC node, as implemented today.

The key rule is:

- profile is a node-level advertised contract
- any principal authorized for execution gets that advertised profile
- sandboxing may conservatively reject code it cannot prove safe
- sandboxing must not deliberately remove profile-mandated features

The final caveat matters because SWI-Prolog's `library(sandbox)` is
conservative: some safe programs may still be rejected when safety cannot be
proved through meta-calls or dynamically constructed goals.


## Route Matrix

| Profile | Required public routes |
| --- | --- |
| `relation` | `/call` |
| `isobase` | `/call` |
| `isotope` | `/call`, `/toplevel_*` |
| `actor` | `/call`, `/toplevel_*`, `/ws` |

Current route enforcement lives in
[node_profile_policy.pl](node_profile_policy.pl).


## Language Matrix

### `relation`

- no arbitrary Prolog goal execution
- no client source loading
- `/call` queries must match advertised relation patterns

In other words, the request goal is treated as a query pattern against an
advertised relation schema, not as general code to execute.

### `isobase`

- arbitrary submitted goals over `/call`
- shared DB predicates
- built-ins and library predicates accepted by the current implementation,
  subject to profile checks and sandbox safety
- no `toplevel_*`
- no actor predicates such as `spawn/3`, `receive/1-2`, `send/2-3`

### `isotope`

Adds to `isobase`:

- `/toplevel_*` transport
- `toplevel_spawn/1-2`, `toplevel_call/2-3`, `toplevel_next/1-2`,
  `toplevel_stop/1`, `toplevel_abort/1`
- shell/session I/O helpers such as `output/1-2`, `terminal_output/1-2`,
  `input/2-3`, `respond/2`, `flush`
- `read/1-2`, `read_term/2-3`, `with_io_target/2`

### `actor`

Adds to `isotope`:

- `/ws` transport
- actor primitives such as `spawn/1-3`, `receive/1-2`, `send/2-3`, `!/2`,
  `self/1`, `monitor/2`, `demonitor/1-2`, `register/2`, `unregister/1`,
  `whereis/2`, `cancel/1`, `exit/1-2`
- `statechart_spawn/1-2`


## Source-Loading Matrix

The source-loading story depends on both profile and transport.

### `relation`

- no client source loading

### `isobase`

- public `/call` accepts `load_text` directly
- client-side `rpc/3` also accepts `load_list/1`, `load_predicates/1`, and
  `load_uri/1`, but those are normalized client-side into `load_text` before
  the HTTP request is sent

### `isotope`

Adds session/toplevel source loading:

- `/toplevel_spawn` options may include `load_text/1`, `load_list/1`,
  `load_predicates/1`, `load_uri/1`
- `toplevel_call/3` and `toplevel_next/2` options may include the same
  `load_*` options

### `actor`

Adds actor spawn source loading:

- `spawn/3` options may include `load_text/1`, `load_list/1`,
  `load_predicates/1`, `load_uri/1`


## Current Sandbox Status Against That Matrix

With `sandbox(blacklist)`, which is the current default/public mode in this
repo:

- controller-owned public `load_uri/1` paths are supported
- nested actor/toplevel `load_uri/1` paths are also supported through the same
  validated rewrite to `load_text/1`
- `load_predicates/1` is supported
- loaded source is prevalidated before loading
- blacklist mode does **not** use SWI's `sandboxed(true)` loader path; that
  extra loader hook is currently used only in `whitelist` mode

Current remaining caveats:

- blacklist mode is weaker than whitelist mode against execution forms that
  fall outside the current rewrite/walker coverage
- `library(sandbox)` remains conservative in whitelist mode, so some safe
  programs may still be rejected when safety cannot be proved

Legacy note:

- `sandbox(on)` is still accepted, but it normalizes to `whitelist`, not
  `blacklist`


## Auth Interaction

Profile is no longer narrowed per principal.

That means:

- `execute` authorizes access to the node's advertised execution surface
- ownership still gates which pids a principal may control
- admin capabilities still gate the admin API

The legacy `source_load_uri` and `source_load_server_predicates`
capabilities are still accepted in principal policy for backward
compatibility, but they no longer narrow ordinary execution.


## Practical Summary

The repo currently implements:

- all four profiles at the route/contract level
- profile checks for goals and loaded source
- route/profile separation from auth and ownership
- sandbox enforcement that aims to preserve the profile contract
