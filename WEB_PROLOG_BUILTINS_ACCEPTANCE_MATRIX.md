# Web Prolog Built-in Acceptance Matrix

This note verifies the entries in `WEB_PROLOG_BUILTINS.md` against the current
public implementation.

It classifies client-submitted code under the current public routes and
`sandbox(blacklist)`. It does not classify host-side HTTP endpoints
themselves. Example: the `/toplevel_spawn` endpoint can be available even
though `toplevel_spawn/1-2` is not accepted as a user goal on
`/toplevel_call`.

Primary basis:

- `node_profile_policy.pl`
- `node_builtin_policy.pl`
- `actor_source.pl`
- `node_sandbox.pl`
- `node.pl`
- `node_ws.pl`
- `node_isotope_controller.pl`

## Legend

- `yes`: accepted as an ordinary unqualified client goal in that route.
- `yes (node:)`: accepted only as a top-level `node:Goal`, not as an
  unqualified goal.
- `yes (local-only)`: accepted with an extra locality restriction.
- `no`: not accepted in that route/context.
- `source only`: accepted only in loaded source text, not as a runtime goal.
- `option only`: accepted only in option positions, not as a callable goal.
- `expression only`: accepted as an arithmetic functor inside arithmetic
  expressions, not as a callable goal.

## Route Model

- `/call` runs at effective profile `isobase`.
- `/toplevel_*` runs at effective profile `isotope`.
- `/ws` runs at effective profile `actor`.
- Public temporary client modules import the route's goal module, the node's
  shared DB module, `statechart_actor`, and the actor I/O prelude.

## Ordinary Goal Acceptance

| Item(s) | `/call` | `/toplevel_*` | `/ws` | Notes |
| --- | --- | --- | --- | --- |
| `true/0`, `fail/0`, `call/1`, `!/0`, `(',')/2`, `(;)/2`, `(->)/2`, `catch/3`, `throw/1` | yes | yes | yes | Core control constructs. |
| `(=)/2`, `unify_with_occurs_check/2`, `(\=)/2`, `subsumes_term/2` | yes | yes | yes | Term unification. |
| `var/1`, `atom/1`, `integer/1`, `float/1`, `atomic/1`, `compound/1`, `nonvar/1`, `number/1`, `callable/1`, `ground/1`, `acyclic_term/1` | yes | yes | yes | Type testing. |
| `(@=<)/2`, `(==)/2`, `(\==)/2`, `(@<)/2`, `(@>)/2`, `(@>=)/2`, `compare/3`, `sort/2`, `keysort/2` | yes | yes | yes | Term comparison. |
| `functor/3`, `arg/3`, `(=..)/2`, `copy_term/2`, `term_variables/2` | yes | yes | yes | Term construction and decomposition. |
| `(is)/2`, `(=:=)/2`, `(=\=)/2`, `(<)/2`, `(=<)/2`, `(>)/2`, `(>=)/2` | yes | yes | yes | Arithmetic evaluation and comparison. |
| `clause/2` | yes (local-only) | yes (local-only) | yes (local-only) | Head must name a predicate defined in the client's temporary module. Imported, shared, and runtime predicates remain blocked. |
| `assert/1-2`, `asserta/1-2`, `assertz/1-2`, `retract/1`, `retractall/1`, `abolish/1-2` | no | yes | yes | Dynamic DB mutation requires at least `isotope`. Asserted clauses are prechecked and rewritten. |
| `findall/3`, `bagof/3`, `setof/3` | yes | yes | yes | All-solutions predicates. |
| `(\+)/1`, `once/1`, `repeat/0`, `call/2-8`, `false/0` | yes | yes | yes | Logic and control. |
| `atom_length/2`, `atom_concat/3`, `sub_atom/5`, `atom_chars/2`, `atom_codes/2`, `char_code/2`, `number_chars/2`, `number_codes/2` | yes | yes | yes | Atomic term processing. |
| `phrase/2`, `phrase/3` | yes | yes | yes | Grammar processing at runtime. |
| `member/2`, `append/3`, `length/2`, `between/3`, `select/3`, `succ/2`, `nth0/3-4`, `nth1/3-4`, `call_nth/2` | yes | yes | yes | Prologue predicates currently visible in the runtime. |
| `maplist/2-5`, `foldl/4-7` | yes | yes | yes | Accepted as higher-order predicates. Runtime guard rewriting still applies to the goals they eventually call. |
| `crypto_data_hash/3` | yes | yes | yes | Local extension currently visible via autoload. |
| `nl/0`, `write/1`, `writeq/1`, `write_term/2`, `writeln/1`, `write_canonical/1`, `print/1`, `display/1`, `format/1-2`, `time/1` | no | yes | yes | These are actor-local prelude overrides, not ambient stream I/O. Profile policy still treats them as side effects and rejects them on `/call`. `time/1` emits a timing-tagged output event rather than printing to the host shell. Stream-target arities such as `nl/1`, `writeln/2`, `print/2`, and `format/3` remain blacklisted. |
| `listing/0` | no | yes | yes | Exposed through the local actor I/O prelude as private-module listing, not the ambient system `listing/0`. |
| `output/1-2`, `input/2-3`, `respond/2` | no | yes | yes | Actor/session I/O requires at least `isotope`. |
| `self/1`, `spawn/1-3`, `actors/1`, `exit/1-2`, `cancel/1` | no | no | yes | Actor lifecycle is `actor`-profile only. |
| `send/2-3`, `!/2`, `receive/1-2`, `monitor/2`, `demonitor/1-2`, `flush/0` | no | no | yes | Actor messaging is `actor`-profile only. |
| `register/2`, `whereis/2`, `unregister/1`, `register_service/2`, `whereis_service/2`, `unregister_service/1` | no | no | yes | Naming and service-registry families are `actor`-profile only. |
| `toplevel_spawn/1-2`, `toplevel_call/2-3`, `toplevel_next/1-2`, `toplevel_stop/1`, `toplevel_abort/1`, `toplevel_halt/2` | no | no | yes | These are accepted as client goals only in the `actor` profile. The HTTP `/toplevel_*` endpoints are separate host-side routes. |
| `statechart_spawn/1-2`, `statechart_halt/2-3` | no | no | yes | Imported into public temporary client modules through `statechart_actor`. |
| `raise/1` | no | no | yes | Imported through `statechart_actor`; meaningful only inside statechart execution. |
| `rpc/2-3`, `promise/3-4`, `yield/2-3` | yes (node:) | yes (node:) | yes (node:) | Profile policy allows them broadly enough, but public temporary client modules do not import `node`, so the currently supported path is `node:rpc(...)`, `node:promise(...)`, `node:yield(...)`. |
| `node/1-2` | no | no | yes (node:) | `node_control` is `actor`-profile only and currently reachable through top-level `node:node(...)`, not as an unqualified client goal. |
| `server_spawn/3-4`, `server_request/3-4`, `server_promise/3-4`, `server_yield/2-4`, `server_upgrade/2`, `server_halt/2` | no | no | no | Catalogued in family policy, but not currently imported into public temporary client modules. Top-level `server_actor:...` qualification is also blocked by blacklist-mode qualified-goal rules. |
| `supervisor_spawn/2-3`, `supervisor_spawn_child/3`, `supervisor_terminate_child/3`, `supervisor_delete_child/3`, `supervisor_respawn_child/3`, `supervisor_which_children/2`, `supervisor_count_children/2`, `supervisor_halt/1` | no | no | no | Same issue as the server family: catalogued, but not currently reachable from public client code under the current blacklist path. |
| `parallel/1` | no | no | no | Catalogued in family policy, but not currently imported into public temporary client modules, and top-level `parallel:parallel(...)` is blocked in blacklist mode. |

## Source-Only Acceptance

| Item(s) | `/call` source | `/toplevel_*` source | `/ws` source | Notes |
| --- | --- | --- | --- | --- |
| `dynamic/1`, `multifile/1`, `discontiguous/1` | yes | yes | yes | Accepted only as directives in loaded source text. |
| DCG notation and grammar control constructs: `[]//0`, `'.'//2`, `(',')//2`, `(;)//2`, `('|')//2`, `{}/1`, `call//1`, `phrase//1`, `!//0`, `(\+)//1`, `(->)//2` | yes | yes | yes | Source syntax, not runtime goals. |
| Arithmetic functors from `9.1`, `9.3`, and `9.4` | expression only | expression only | expression only | Usable inside arithmetic expressions; not callable goal predicates. |

## Option-Only Acceptance

| Item(s) | Status | Notes |
| --- | --- | --- |
| `load_text/1` | option only | Source-loading option, not an ordinary goal. Public `/call` exposes raw `load_text` directly; other routes and nested spawns use option lists. |
| `load_list/1`, `load_predicates/1` | option only | Source-loading options for spawns, toplevel creation/calls, nested spawns, and similar paths. They are normalized into source text before loading. |
| `load_uri/1` | option only | Source-loading option, not an ordinary goal. In unrestricted nodes it can still load local files, `file://` URIs, HTTP(S), and node-relative URIs. Nodes can now narrow this with `load_uri_allowed_origins([...])`, which blocks local paths and non-allowlisted origins. |

## Proposed but Not Current

| Item(s) | Status | Notes |
| --- | --- | --- |
| `maplist/6-8`, `countall/2` | no | Mentioned as proposed prologue items, but not currently present as such in this runtime. |

## Main Verified Mismatches vs the Catalog

- `rpc/2-3`, `promise/3-4`, `yield/2-3`, and `node/1-2` are currently
  reachable through `node:...`, not as unqualified client goals.
- `server_*`, `supervisor_*`, and `parallel/1` are still better understood as
  family-policy/catalog entries than as publicly reachable built-ins under the
  present blacklist implementation.
- `load_text/1`, `load_list/1`, `load_predicates/1`, and `load_uri/1` are
  source-loading options, not ordinary goals.
