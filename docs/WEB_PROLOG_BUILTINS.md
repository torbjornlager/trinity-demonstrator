# Web Prolog Built-in Predicates — Actor Profile

This document is the canonical human-facing catalog of predicates available in
the Web Prolog `actor` profile under `sandbox(blacklist)`.

The ISO core predicates follow the categorization of IS 13211-1:1995 (with
Cor.2:2012 and Cor.3:2017 additions) and TS 13211-3:2025. Blacklisted
predicates are excluded. Web Prolog extensions follow the ISO categories where
natural, then appear in their own sections.

For a route-by-route and context-by-context verification against the current
implementation, see `WEB_PROLOG_BUILTINS_ACCEPTANCE_MATRIX.md`.

This is the union of the ACTOR profile surface, not just the stateless `/call`
route. In profile terms, `actor` includes the lower `relation`, `isobase`, and
`isotope` layers.

Primary basis:

- [node_builtin_policy.pl](../prolog/web_prolog/node_builtin_policy.pl)
- [node_profile_policy.pl](../prolog/web_prolog/node_profile_policy.pl)
- [actor_io_support.pl](../prolog/web_prolog/actor_io_support.pl)
- [node_sandbox.pl](../prolog/web_prolog/node_sandbox.pl)
- [BLACKLIST_SANDBOX_NOTES.md](policy/BLACKLIST_SANDBOX_NOTES.md)

## Notes on Scope

- This is a predicate catalog, not a full catalog of flags, error classes,
  option terms, or every helper predicate exported by internal runtime
  modules.
- This document records the intended built-in surface of the `actor` profile.
  The acceptance matrix is the more precise companion when the question is what
  client-submitted code is actually accepted on a given route.
- Some predicates are context-specific as well as profile-specific. For
  example, conversational I/O requires an actor or session context, and
  `raise/1` is meaningful only inside statechart execution.
- Ambient stream and file I/O are blacklisted. Web Prolog instead supplies
  actor-local output predicates such as `write/1`, `writeln/1`, and `format/2`
  through the actor runtime prelude.
- `clause/2` remains available only in its narrowed blacklist-safe form: the
  head must name a local predicate in the client's own private module.

## 7.4.2 Directives

`dynamic/1`, `multifile/1`, `discontiguous/1`.

**Blacklisted:** `op/3`, `char_conversion/2`, `initialization/1`,
`include/1`, `ensure_loaded/1`, `set_prolog_flag/2`.

## 7.8 Control Constructs

`true/0`, `fail/0`, `call/1`, `!/0`, `(',')/2`, `(;)/2`,
`(->)/2`, `catch/3`, `throw/1`.

## 8.2 Term Unification

`(=)/2`, `unify_with_occurs_check/2`, `(\=)/2`, `subsumes_term/2`.

## 8.3 Type Testing

`var/1`, `atom/1`, `integer/1`, `float/1`, `atomic/1`, `compound/1`,
`nonvar/1`, `number/1`, `callable/1`, `ground/1`, `acyclic_term/1`.

## 8.4 Term Comparison

`(@=<)/2`, `(==)/2`, `(\==)/2`, `(@<)/2`, `(@>)/2`, `(@>=)/2`,
`compare/3`, `sort/2`, `keysort/2`.

## 8.5 Term Creation and Decomposition

`functor/3`, `arg/3`, `(=..)/2`, `copy_term/2`, `term_variables/2`.

## 8.6 Arithmetic Evaluation

`(is)/2`.

## 8.7 Arithmetic Comparison

`(=:=)/2`, `(=\=)/2`, `(<)/2`, `(=<)/2`, `(>)/2`, `(>=)/2`.

## 8.8 Clause Retrieval and Information

`clause/2` — conditionally allowed; the head must name a local predicate
defined in the client's own temporary module. Imported, shared, and runtime
predicates are blocked.

**Blacklisted:** `current_predicate/1`, `predicate_property/2`.

## 8.9 Clause Creation and Destruction

`asserta/1`, `asserta/2`, `assertz/1`, `assertz/2`, `assert/1`, `assert/2`,
`retract/1`, `retractall/1`, `abolish/1`, `abolish/2`.

Asserted facts and rules are prechecked with the same source-term walker used
for loaded source text. A clause body containing a blacklisted goal is rejected
before it reaches the actor's private database.

## 8.10 All Solutions

`findall/3`, `bagof/3`, `setof/3`.

## 8.12–8.14 Actor I/O (Overrides)

The ambient stream I/O predicates of ISO 8.11–8.14 are **blacklisted**. In
their place, the actor runtime prelude injects local overrides that route
output through the actor messaging layer via `actor:terminal_output/1-2`:

`nl/0`, `write/1`, `writeq/1`, `write_term/2`, `writeln/1`,
`write_canonical/1`, `print/1`, `display/1`, `format/1`, `format/2`,
`time/1`, `listing/0`.

These are local predicates in the actor's temporary module and shadow the
system-level definitions. They do not provide stream-level access. The local
`time/1` emits a timing output event instead of printing to the host shell.

## 8.15 Logic and Control

`(\+)/1`, `once/1`, `repeat/0`, `call/2..8`, `false/0`.

## 8.16 Atomic Term Processing

`atom_length/2`, `atom_concat/3`, `sub_atom/5`, `atom_chars/2`,
`atom_codes/2`, `char_code/2`, `number_chars/2`, `number_codes/2`.

## 8.18 Grammar Processing

`phrase/2`, `phrase/3`.

DCG notation (`-->/2`) is supported in loaded source text. Grammar control
constructs: `[]//0`, `'.'//2`, `(',')//2`, `(;)//2`, `('|')//2`, `{}//1`,
`call//1`, `phrase//1`, `!//0`, `(\+)//1`, `(->)//2`.

## 9 Arithmetic Functors

### 9.1 Simple Arithmetic Functors

`(+)/2`, `(-)/2`, `(*)/2`, `(//)/2`, `(/)/2`, `(rem)/2`, `(mod)/2`,
`(-)/1`, `abs/1`, `sign/1`, `float_integer_part/1`,
`float_fractional_part/1`, `float/1`, `floor/1`, `truncate/1`, `round/1`,
`ceiling/1`, `(+)/1`, `(div)/2`.

### 9.3 Other Arithmetic Functors

`(**)/2`, `sin/1`, `cos/1`, `atan/1`, `exp/1`, `log/1`, `sqrt/1`,
`max/2`, `min/2`, `(^)/2`, `asin/1`, `acos/1`, `atan2/2`, `tan/1`, `pi/0`.

### 9.4 Bitwise Functors

`(>>)/2`, `(<<)/2`, `(/\\)/2`, `(\\/)/2`, `(\\)/1`, `xor/2`.

## ISO Prologue (TS 13211-3:2025)

`member/2`, `append/3`, `length/2`, `between/3`, `select/3`, `succ/2`,
`maplist/2..5`, `nth0/3`, `nth1/3`, `nth0/4`, `nth1/4`, `call_nth/2`,
`foldl/4..7`.

Local extension currently available as a built-in in this environment:
`crypto_data_hash/3`.

Prologue items proposed in standards discussions but not currently present as
such in this runtime:
`maplist/6..8`, `countall/2`.

---

## Web Prolog Extensions

### Actor Lifecycle

`self/1`, `spawn/1`, `spawn/2`, `spawn/3`, `actors/1`,
`exit/1`, `exit/2`, `cancel/1`.

### Actor Messaging

`send/2`, `send/3`, `!/2`, `receive/1`, `receive/2`,
`monitor/2`, `demonitor/1`, `demonitor/2`, `flush/0`.

### Actor Naming

`register/2`, `whereis/2`, `unregister/1`.

### Service Registry

`register_service/2`, `whereis_service/2`, `unregister_service/1`.

### Private Database Loading

`load_text/1`, `load_list/1`, `load_predicates/1`, `load_uri/1`, `listing/0`.

`load_uri/1` remains a broad source-loading option in unrestricted setups, but
the runtime now supports per-node exact-origin allowlists through
`load_uri_allowed_origins([...])`. When that allowlist is configured, bare
local paths, `file://` URIs, and arbitrary HTTP(S) origins are rejected, while
node-relative URIs continue to work only if they resolve to an allowed origin.

### Actor I/O

`output/1`, `output/2`, `input/2`, `input/3`, `respond/2`.

### Toplevel Sessions

`toplevel_spawn/1`, `toplevel_spawn/2`, `toplevel_call/2`,
`toplevel_call/3`, `toplevel_next/1`, `toplevel_next/2`,
`toplevel_stop/1`, `toplevel_abort/1`, `toplevel_halt/2`.

### Remote Queries

`rpc/2`, `rpc/3`, `promise/3`, `promise/4`, `yield/2`, `yield/3`.

### Generic Servers

`server_spawn/3`, `server_spawn/4`, `server_request/3`,
`server_request/4`, `server_promise/3`, `server_promise/4`,
`server_yield/2`, `server_yield/3`, `server_yield/4`,
`server_upgrade/2`, `server_halt/2`.

### Supervisors

`supervisor_spawn/2`, `supervisor_spawn/3`,
`supervisor_spawn_child/3`, `supervisor_terminate_child/3`,
`supervisor_delete_child/3`, `supervisor_respawn_child/3`,
`supervisor_which_children/2`, `supervisor_count_children/2`,
`supervisor_halt/1`.

### Statechart Actors

`statechart_spawn/1`, `statechart_spawn/2`,
`statechart_halt/2`, `statechart_halt/3`, `raise/1`.

### Parallel Goals

`parallel/1`.

### Node Control

`node/1`, `node/2`.

---

## Blacklisted (Not Available)

For reference, the following ISO predicates are denied by the blacklist. See
`policy/BLACKLIST_SANDBOX_NOTES.md` for rationale.

- **Stream and file I/O (8.11–8.14):** `open/3-4`, `close/1-2`,
  `current_input/1`, `current_output/1`, `set_input/1`, `set_output/1`,
  `at_end_of_stream/0-1`, `stream_property/2`, `set_stream_position/2`,
  `flush_output/0-1`, `get_byte/1-2`, `get_char/1-2`, `get_code/1-2`,
  `peek_byte/1-2`, `peek_char/1-2`, `peek_code/1-2`, `put_byte/1-2`,
  `put_char/1-2`, `put_code/1-2`, `read/1-2`, `read_term/2-3`, `nl/1`,
  `writeln/2`, `print/2`, `format/3`, `write/1-2`, `writeq/1-2`,
  `write_canonical/1-2`, `write_term/2-3`.
- **Runtime reflection (8.8, 8.17):** `current_predicate/1`,
  `predicate_property/2`, `current_prolog_flag/2`, `current_op/3`,
  `current_char_conversion/2`.
- **Runtime/parser mutation (8.14, 8.17):** `set_prolog_flag/2`,
  `char_conversion/2`, `op/3`, `halt/0-1`.
- **Runtime timing:** raw `time/1`.
- **Stateful term storage (SWI):** `nb_setval/2`, `b_setval/2`,
  `nb_getval/2`, `b_getval/2`.
- **Shell commands (SWI):** `shell/0-2`, `cd/0-1`, `pushd/0-1`, `popd/0`,
  `dirs/0`, `pwd/0`, `ls/0-1`, `mv/2`, `rm/1`, `file_style/2`.
- **Threads/synchronization (ISO threads):** `thread_create/3`,
  `thread_detach/1`, `thread_self/1`, `thread_property/2`,
  `thread_send_message/2`, `thread_get_message/1-3`,
  `thread_peek_message/1-2`, `thread_signal/2`, `mutex_create/2`,
  `mutex_destroy/1`, `mutex_lock/1`, `mutex_trylock/1`, `mutex_unlock/1`,
  `mutex_property/2`, `message_queue_create/2`, `message_queue_destroy/1`,
  `message_queue_property/2`, `with_mutex/2`.
- **Source directives:** `use_module/1-2`, `load_files/1-2`, `consult/1`,
  `reconsult/1`, `include/1`, `ensure_loaded/1`, `module/1-2`,
  `initialization/1-2`, `redefine_system_predicate/1`.
