# Blacklist Sandbox Notes

This file records the first-pass blacklist decisions for `sandbox(blacklist)`.

## Inventory Basis

The initial ISO inventory was assembled from the local runtime on March 24, 2026
using SWI-Prolog 10.1.3 and the built-in `iso` predicate property:

```sh
swipl -q -g "setof(Name/Arity, M^H^(current_predicate(M:Name/Arity), functor(H, Name, Arity), predicate_property(M:H, iso)), L), maplist(writeln, L), halt."
```

In SWI this inventory includes both the classic ISO core and the ISO
threads/draft-style predicates that SWI also marks as `iso`.

## First Blacklist Pass

The current blacklist mode denies these families by default:

- Ambient stream and file I/O:
  `open/3-4`, `close/1-2`, `current_input/1`, `current_output/1`,
  `set_input/1`, `set_output/1`, `at_end_of_stream/0-1`,
  `stream_property/2`, `set_stream_position/2`, `flush_output/0-1`,
  `get_byte/1-2`, `get_char/1-2`, `get_code/1-2`,
  `peek_byte/1-2`, `peek_char/1-2`, `peek_code/1-2`,
  `put_byte/1-2`, `put_char/1-2`, `put_code/1-2`,
  `read/1-2`, `read_term/2-3`, `nl/1`, `writeln/2`, `print/2`,
  `format/3`, `write/1-2`, `writeq/1-2`, `write_canonical/1-2`,
  `write_term/2-3`.

- Runtime reflection and environment inspection:
  `current_predicate/1`, `predicate_property/2`,
  `current_prolog_flag/2`, `current_op/3`, `current_char_conversion/2`.

- Runtime and parser mutation:
  `set_prolog_flag/2`, `char_conversion/2`, `op/3`, `halt/0-1`.

- Runtime timing output:
  raw `time/1`.

- Stateful term storage:
  `nb_setval/2`, `b_setval/2`, `nb_getval/2`, `b_getval/2`.

- SWI `library(shell)` operational predicates:
  `shell/0-2`, `cd/0-1`, `pushd/0-1`, `popd/0`, `dirs/0`, `pwd/0`,
  `ls/0-1`, `mv/2`, `rm/1`, `file_style/2`.

- ISO threads and synchronization primitives reported by SWI as `iso`:
  `message_queue_create/2`, `message_queue_destroy/1`,
  `message_queue_property/2`, `mutex_create/2`, `mutex_destroy/1`,
  `mutex_lock/1`, `mutex_property/2`, `mutex_trylock/1`,
  `mutex_unlock/1`, `thread_create/3`, `thread_detach/1`,
  `thread_get_message/1-3`, `thread_peek_message/1-2`,
  `thread_property/2`, `thread_self/1`, `thread_send_message/2`,
  `thread_signal/2`, `with_mutex/2`.

- Source directives that mutate global language/runtime state:
  `op/3`, `char_conversion/2`, `set_prolog_flag/2`,
  plus loader directives such as `use_module/1-2`, `load_files/1-2`,
  `consult/1`, `reconsult/1`, `include/1`, `ensure_loaded/1`,
  `module/1-2`, `initialization/1-2`, and `redefine_system_predicate/1`.
  Some entries intentionally appear in both lists because they are denied both
  as runtime goals and as source directives.

## Still Allowed or Special-Cased

These remain governed by the existing profile and builtin-family policy rather
than the blacklist itself:

- Dynamic private-database predicates:
  `assert/1-2`, `asserta/1-2`, `assertz/1-2`, `retract/1`,
  `retractall/1`, `abolish/1-2`.
  In blacklist mode, asserted facts and rules are now prechecked with the same
  source-term walker used for loaded source text, so `assertz((p :- open(...)))`
  is rejected before the clause ever reaches the actor's private DB.

- `clause/2` is conditionally allowed in blacklist mode only when the head
  names a local predicate defined by the client's own temporary module.
  Imported/shared/runtime predicates remain blocked.

- Pure control, term, arithmetic, and collection predicates such as
  `call/N`, `catch/3`, `bagof/3`, `setof/3`, `findall/3`, `sort/2`,
  `sub_atom/5`, `copy_term/2`, `term_variables/2`, `arg/3`, `functor/3`,
  and the comparison predicates.

- Local actor I/O overrides supplied by the runtime prelude, such as
  `write/1`, `writeq/1`, `write_term/2`, `nl/0`, and `time/1`.
  The local `time/1` reports through a tagged timing output event instead of
  printing directly to the host Prolog shell.

- Stream-target forms that are not shadowed by that prelude, such as
  `nl/1`, `writeln/2`, `print/2`, and `format/3`.

## Qualified Goals

- Public top-level module-qualified goals are rejected in blacklist mode except
  for the explicitly supported `actor:Goal` and `node:Goal` entry points.

- Internal validation still needs to check goals as code running inside a
  temporary client module. That uses a separate in-module entry point rather
  than reopening public `m:Goal` access.

- This distinction matters for dynamic DB mutation too:
  `m:assert(p(a))` is rejected as a foreign top-level qualified goal, and
  `assert(m:p(a))` is rejected because qualified clause heads are not allowed
  during dynamic clause precheck.

## Goal Walker Coverage

Blacklist mode relies on `goal_walker:walk_goal/2` to recurse through common
structural forms before checking leaves and special cases. Today that includes:

- conjunction, disjunction, if-then, soft-cut, negation, `once/1`, `ignore/1`
- `catch/3` (walks the protected goal and recovery goal; the catcher term is a
  pattern, not an executed goal)
- `setup_call_cleanup/3`, `setup_call_catcher_cleanup/4`, `call_cleanup/2`
- `call/1-8`, `forall/2`, `findall/3`, `findnsols/4-5`, `bagof/3`, `setof/3`
- `aggregate/3-4` and `aggregate_all/3-4`

`time/1` is not part of the generic walker list above. Blacklist mode handles
it as a separate local-override special case so the raw system
`prolog_statistics:time/1` remains blocked while the actor-local prelude
variant can still recurse into its inner goal.

## Runtime Guard Rewriting

Static walking is not enough for goals that are still opaque at walk time, so
blacklist mode now also rewrites public code before execution:

- public `/call` entry goals and session/toplevel goals
- loaded source text in public blacklist execution
- asserted rule bodies in blacklist mode

The rewrite inserts runtime guard wrappers around:

- direct variable goals such as `saved(G), G`
- `call/1-8`
- `time/1`
- `assert/1-2`, `asserta/1-2`, and `assertz/1-2`
- the executed-goal positions inside the same structural forms the walker
  already understands

This closes the earlier `saved(G), call(G)` and `saved(G), G` bypass class for
the rewritten public execution paths. At runtime the wrapper re-checks the
concrete goal term with the blacklist policy before executing it.

## Open Risks

- Blacklisting is still weaker than the whitelist path against execution forms
  that fall outside the current rewrite coverage.
- The previously documented `saved(G), call(G)` and `saved(G), G` cases are now
  blocked on public rewritten paths, but any future meta-execution primitive
  must be added both to the walker coverage and to the runtime rewrite pass.
- For example, if the runtime later exposes additional higher-order predicates
  that can execute goal terms indirectly, they would need the same treatment.
- Module-qualified calls are therefore restricted much more aggressively in
  blacklist mode than in whitelist mode.
- The blacklist is still runtime-specific. If the target Prolog system changes,
  the ISO inventory should be regenerated and reviewed again.
- Some blacklist entries are intentionally SWI-specific additions beyond the ISO
  inventory, notably `library(shell)`, because they expose filesystem and
  process-adjacent operational authority that is out of scope for untrusted
  actor code.

## Error Serialization

Public stateless and session calls can carry exception terms out of temporary
actor modules that are torn down immediately after the answer is produced.
When those exceptions include `prolog_stack(...)` clause references,
`message_to_string/2` may try to decompile stale frames. JSON error formatting
therefore strips `prolog_stack(...)` context before converting the exception to
a client-facing message.
