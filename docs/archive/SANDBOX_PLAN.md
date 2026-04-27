# Sandbox Integration Plan

This document is archived. It is kept for historical context and has been superseded by a newer consolidated note.


This document turns the `library(sandbox)` idea into a concrete, staged
implementation plan for this node.

The goal is not merely to "use sandbox somewhere". The goal is to make every
public execution path enforce the same security policy for:

- untrusted goals
- untrusted source text
- untrusted spawn options

and to do so without breaking owner-controlled runtime code such as the shared
DB, built-in actor machinery, or the node controllers themselves.

Current contract note:

- sandboxing is now `off` or `on`
- `sandbox(on)` is intended to preserve the advertised node profile rather
  than narrow it
- both controller-owned and nested actor/toplevel source-loading paths now
  go through the same validated rewrite for `load_uri/1`

For the current node-profile matrix that the sandbox is expected to preserve,
see [PROFILE_MATRIX.md](PROFILE_MATRIX.md).


## Scope

Sandboxing must cover these user-controlled entry points:

- stateless HTTP `/call`
- ISOTOPE `/toplevel_spawn`
- ISOTOPE `/toplevel_call`
- WS `toplevel_spawn`
- WS `toplevel_call`
- WS bare `spawn`

It must also cover these user-controlled code-loading paths:

- `load_text/1`
- `load_list/1`
- `load_uri/1`
- `load_predicates/1`

Important limitation:

- `library(sandbox)` protects goal and clause safety.
- It does **not** solve resource exhaustion, queue flooding, or capability
  abuse through raw WS commands such as `send` and `exit`.


## Policy Model

Add a new module:

- `node_sandbox.pl`

Recommended public API:

- `sandbox_enabled/0`
- `sandbox_check_goal(+Profile, +QualifiedGoal)`
- `sandbox_check_spawn_options(+Profile, +Options)`
- `sandbox_check_source_text(+Profile, +Module, +SourceText)`
- `sandbox_check_source_options(+Profile, +GoalModule, +Options)`

Recommended profiles:

- `stateless`
- `session`
- `actor`

The point of profiles is to keep the public surface explicit. `/call` should
have the smallest allowed surface. Bare actor spawning should be the most
restricted, and may be disabled entirely in a public deployment.

Add one setting in `node.pl`:

- `setting(sandbox, atom, off, 'Sandbox policy: off or on')`

Suggested meanings:

- `off`: disable sandbox enforcement
- `on`: enforce the node sandbox without narrowing the advertised profile

Compatibility note:

- legacy values `demo` and `strict` are accepted as aliases for `on`


## Core Hooks

`library(sandbox)` should be used via:

- `sandbox:safe_goal/1`
- `sandbox:safe_primitive/1`
- `sandbox:safe_meta/2`
- `sandbox:safe_directive/1`

Do **not** rely on `sandbox:safe_clause/1` for this integration. It is too
weak to serve as the main policy gate here.


## File Checklist

### `node_sandbox.pl` (new)

Implement the policy here.

Checklist:

- Import `library(sandbox)`.
- Declare multifile hooks:
  - `sandbox:safe_primitive/1`
  - `sandbox:safe_meta/2`
  - `sandbox:safe_directive/1`
- Define the public checking predicates listed above.
- Add a small helper that maps node setting -> effective policy profile.
- Add explicit allowlists for Web Prolog wrappers that should remain usable:
  - actor output/input wrappers that are intentionally part of the public API
  - selected pure actor predicates only if they are meant to remain public
- Explicitly reject risky predicates by omission:
  - file IO
  - process creation
  - shell commands
  - network access
  - arbitrary module-qualified calls
  - unsafe dynamic DB operations unless deliberately allowed
- Define source validation by parsing terms and checking:
  - directives through `sandbox:safe_directive/1`
  - clause bodies through `sandbox:safe_goal/1`

Design rule:

- owner code is trusted
- client code is untrusted


### `node.pl`

This is the HTTP ingress layer.

Current hook points:

- `node_controller_isobase/1`
- `node_controller_isotope_spawn/1`
- `node_controller_isotope_call/1`
- `isobase_event/9`

Checklist:

- Import `node_sandbox`.
- In `isobase_event/9`, after `parse_call_context/9`, call:
  - `sandbox_check_goal(stateless, actor:Goal)`
- Before passing `LoadText` into `compute_answer/8`, validate it:
  - either directly in `isobase_event/9`
  - or centrally inside `source_loader.pl`
- In `node_controller_isotope_spawn/1`, keep transport parsing where it is,
  but ensure spawned session options are checked before spawn.

Reasoning:

- `/call` is the simplest and safest place to start because all code passes
  through one parsed goal and optional `load_text`.


### `node_isotope_options.pl`

This file parses `/toplevel_spawn` options.

Checklist:

- After parsing spawn options, call:
  - `sandbox_check_spawn_options(session, SpawnOptions0)`
- In public/demo profiles, reject or strip:
  - `node(_)`
  - `load_uri(_)`
  - `load_predicates(_)`
- Decide whether `load_text/1` is allowed at spawn time in public mode.
  If yes, it must also be source-validated before the session is created.

Reasoning:

- spawn-time code injection is still untrusted code injection
- this path must not bypass the same source policy as `/toplevel_call`


### `node_isotope_controller.pl`

This is the main ISOTOPE execution path.

Current hook point:

- `isotope_call_event/10`

Checklist:

- After `rewrite_isotope_goal/2`, call:
  - `sandbox_check_goal(session, actor:RewrittenGoal)`
- Before `load_text_into_session/2`, ensure the load text is validated.
- If spawn-time `load_text` remains supported, validate that too.

Reasoning:

- this is the main path used by `/shell` and much of the workbench


### `node_session.pl`

This is the most important source-loading hook for session code.

Current hook points:

- `load_text_into_session/2`
- `rewrite_isotope_source_text/2`
- `read_rewritten_isotope_terms/2`

Checklist:

- After rewriting source terms, but before `load_source_text/3`, validate the
  rewritten source using `sandbox_check_source_text(session, Module, Text)`.
- Alternatively, change the implementation so validation works on parsed terms
  before the source is re-serialized.
- Keep the current rewrite pass first, then sandbox the rewritten form.

Reasoning:

- the sandbox must see the code that will actually run
- rewriting `read/1` to `actor:input/2` before sandboxing avoids false rejections


### `source_loader.pl`

This is the shared source normalization layer.

Checklist:

- Add one central validation hook so every `load_*` path can reuse it.
- Recommended additions:
  - `load_source_terms/2`
  - `validate_source_terms/3`
  - or a single `sandbox_source_option/4`
- Validate `load_text`, `load_list`, `load_uri`, and `load_predicates`
  after they have been normalized into source text.
- For `load_uri`, strongly consider disabling it for untrusted public mode
  rather than trying to sandbox arbitrary downloaded code.

Reasoning:

- this is the best place to keep the `load_*` rules consistent
- otherwise `/call`, ISOTOPE, WS, and local actor setup will drift


### `node_ws.pl`

This is the highest-risk public surface.

Current hook points:

- `ws_action_toplevel_call/2`
- `ws_action_spawn/2`
- `ws_action_toplevel_spawn/2`
- `ws_action_send/1`
- `ws_action_exit/1`

Checklist:

- In `ws_action_toplevel_call/2`, after `rewrite_isotope_goal/2`, call:
  - `sandbox_check_goal(session, actor:RewrittenGoal)`
- Validate `load_text` before `load_text_into_session/2`.
- In `ws_action_spawn/2`, after parsing and rewriting the goal, call:
  - `sandbox_check_goal(actor, actor:RewrittenGoal)`
- Validate spawn options with:
  - `sandbox_check_spawn_options(actor, UserOptions)`
- For public mode, consider disabling bare WS `spawn` entirely.

Important non-sandbox checks:

- Restrict `ws_action_send/1` so clients can only send to actors they own or
  to explicitly exposed public actors.
- Restrict `ws_action_exit/1` similarly.

Reasoning:

- `library(sandbox)` cannot protect raw capability-style commands
- `/ws` needs ownership checks in addition to sandbox checks


### `node_call_context.pl`

This file is mostly fine as-is.

Checklist:

- Keep parsing here.
- Do not add policy here unless you want a single helper that returns a fully
  parsed and sandbox-checked call context.

Optional improvement:

- add a helper that returns `QualifiedGoal` so all callers sandbox the same
  term shape


### `actor_source.pl`

This is the actor module setup path.

Checklist:

- No first-phase changes required if ingress-layer sandboxing is complete.
- Optional second-phase defense in depth:
  - if options contain a sandbox profile, validate source options here too
  - this protects locally spawned untrusted actors outside the HTTP layer

Reasoning:

- useful later
- not required for the first public-node sandbox


### `actor.pl`

This file is not the first place to enforce public-node sandboxing.

Checklist:

- Keep ingress checks in node controllers first.
- Optional second-phase defense in depth:
  - propagate `sandbox_profile(Profile)` in local spawns
  - check source options before `prepare_actor_module/3`
  - check start goals before `execute_start_goal/3`

Reasoning:

- this is more invasive
- it is worth doing later if you want untrusted local callers inside the same
  SWI process to be contained too


### `toplevel_actor.pl`

Checklist:

- No first-phase changes required.
- Optional second-phase defense in depth:
  - preserve sandbox profile in the toplevel actor state
  - re-check goals on every `'$call'`

Reasoning:

- public-node security can be enforced at ingress first
- actor-local sandbox state is a harder but cleaner second step


### `tests/`

Add focused tests, not only happy-path tests.

Recommended files:

- extend `tests/node_tests.pl`
- optionally add `tests/node_sandbox_tests.pl`

Checklist:

- Allowed `/call` goal:
  - `member(X,[a,b])`
- Rejected `/call` goal:
  - `open('/tmp/x', write, S)`
- Rejected `/call` source:
  - `:- use_module(library(process)).`
- Allowed ISOTOPE session goal:
  - `format('hello')`
- Rejected ISOTOPE session source:
  - `p :- shell('id').`
- Allowed WS toplevel goal:
  - `between(1,3,X)`
- Rejected WS bare actor goal:
  - `process_create(path(sh), [], [])`
- Rejected WS send/exit to foreign pid:
  - verify ownership check

Also add regression tests for error reporting:

- sandbox rejection should come back as structured `error(...)`
- it must not crash the node


## Initial Public Policy

For a first public-facing profile, keep it narrow.

Allow:

- pure query predicates
- list processing
- arithmetic
- safe aggregation
- `write/1`, `writeln/1`, `format/1-2`, `nl/0`
- `output/1-2`, `input/2-3`, `respond/2` if you want interactive sessions

Deny in phase 1:

- `load_uri/1`
- `load_predicates/1`
- bare WS `spawn`
- remote `spawn(..., [node(...)])`
- `rpc/2-3`
- `promise/3-4`
- `yield/2-3`
- file IO
- network IO
- OS process access
- arbitrary module-qualified calls
- unrestricted dynamic DB mutation

This will make the public node far more like a safe query/demo server than a
fully open actor platform. That is the right first step.


## Rollout Order

1. Add `node_sandbox.pl` and the `node:sandbox` setting.
2. Enforce goal checks for `/call`.
3. Enforce source checks for `/call` load text.
4. Enforce goal and source checks for ISOTOPE.
5. Enforce goal/source checks and ownership rules for `/ws`.
6. Add defense-in-depth hooks in `actor.pl` and `toplevel_actor.pl`.


## Known Gaps Even After Sandboxing

These still need separate controls:

- CPU abuse
- memory abuse
- mailbox flooding
- actor explosion
- long-lived idle sessions
- outbound network abuse if the container/network allows egress

These should be handled separately through:

- owner timeout caps
- request-size limits
- actor/session count caps
- queue limits
- reverse-proxy rate limits
- container or VM network restrictions
