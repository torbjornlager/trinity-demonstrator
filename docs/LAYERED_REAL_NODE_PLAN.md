# Plan: A Production Web Prolog Node, Layered with Hooks

Status: proposal (2026-06-10). This plans a **new project** — "the real
thing": an SWI-Prolog-only Web Prolog node good enough for serious use by
others. It forks the trinity-demonstrator implementation but reorganizes it
into independently loadable layers connected by multifile hooks, in the same
manner as Jan Wielemaker's layering in
<https://github.com/Web-Prolog/swi-web-prolog>.

Non-negotiable constraint: **Web Prolog syntax and semantics remain exactly
as in the trinity demonstrator** (not as in the 2018 swi-web-prolog, where
they differ). The demonstrator's test suite and the documents
`WEB_PROLOG_BUILTINS.md`, `PROFILE_MATRIX.md`, and
`CROSS_NODE_ARCHITECTURE.md` are the normative spec.

---

## 1. What the study of the two codebases showed

### 1.1 How swi-web-prolog does layering

Four hooks declared `multifile` in `actors.pl`, each with a single call
site inside the core:

| hook | call site | purpose |
|---|---|---|
| `hook_goal/3` | inside `spawn` (before thread creation) | rewrite/wrap the start goal |
| `hook_spawn/3` | head of `spawn` | a layer may take over spawning entirely (remote) |
| `hook_send/2` | head of `send` | a layer may take over delivery (`Id@Node`, sockets) |
| `hook_self/1` | head of `self` | a layer may globalize the self pid |

`isolation.pl` is fully freestanding (depends on `library(modules)`, not on
actors) and exposes `with_source/2` plus two hooks of its own:
`prepare_module/3` and `prepare_goal/3`.

**The decisive pattern:** neither `actors.pl` nor `isolation.pl` knows about
the other. The umbrella `web_prolog.pl` defines
`actors:hook_goal(G0, isolation:with_source(G0, Opts), Opts0)` — the
actors↔isolation coupling lives *only in the composition layer*
(`web_prolog.pl:113-126` in that repo). `distribution.pl` implements
`actors:hook_self/1`, `hook_spawn/3`, `hook_send/2` for `Id@Node` pids
(`distribution.pl:321-344`). `pengines2.pl` (the toplevel layer) builds on
actors alone.

### 1.2 Where the demonstrator is entangled

The demonstrator's `actor.pl` (1725 lines) hard-imports all three upper concerns:

- **distribution** — `node_controller` (22 call sites), `remote_protocol`,
  plus the entire outbound WS client (`spawn_remote/4`,
  `remote_request_spawn/3`, `remote_ws_read_loop/3`,
  `remote_ws_dispatch/3`) living physically inside `actor.pl`;
- **isolation** — `prepare_actor_module/3` (actor.pl:892),
  `load_source_text/3` (:944), `rewrite_source_options/3` (:387);
- **node policy & observability** — `rewrite_goal_if_needed/3`
  (public_goal_guard, :905), `builtin_family_enabled/2` (:1155),
  `log_event/1`, `node_execution_context`, `node_runtime_state`.

`toplevel_actor.pl` mirrors this on a small scale (remote toplevel spawn,
`public_goal_guard`, `source_loader`). `statechart_actor.pl` has one upward
edge into `node_session.pl` that must be broken.

The crucial observation: every entanglement is **point-like** — one or two
call sites at known places, matching Jan's hook sites almost one-to-one:

| concern | demonstrator call site | becomes |
|---|---|---|
| remote spawn | `spawn/3` → `option(node(N))` → `spawn_remote/4` (actor.pl:231-235) | `hook_spawn/3` (distribution) |
| remote send | `send/2` clauses for `Id@Node` (actor.pl:1450,1461) | `hook_send/2` (distribution) |
| global self | `self/1` (actor.pl:1179) | `hook_self/1` (distribution) |
| module prep + source load + policy guard | `spawn_local` body (actor.pl:892-944) | `hook_goal/3` (composed by umbrella) |
| cross-node monitor/link/exit | `monitor/2`, link & `exit/2` paths → `node_controller` | `hook_monitor/2`, `hook_link/2`, `hook_exit/2` — **new hooks the 2018 design never needed** |
| builtin-family policy | `builtin_family_enabled/2` | node-layer hook, identity default |
| interaction logging | `log_event/1` | `hook_event/1`, no-op default |

So the work is mostly *moving code along existing seams and replacing static
import edges with hook edges* — not redesigning the runtime. The demonstrator
has substantially richer cross-node semantics than 2018 swi-web-prolog
(controller tables, monitor/link lifecycle invariants, the recently fixed
races), and those semantics move **verbatim** into the distribution layer.

---

## 2. Target architecture

### 2.1 Layers

```
Layer 5  web_prolog.pl        umbrella: composes everything, owns ALL glue
                              hooks, exports full Web Prolog API
Layer 4  node/…               HTTP/WS server: ISOBASE /call, ISOTOPE
                              sessions, ACTOR /ws; auth, profiles, sandbox,
                              limits, admin, interaction log
Layer 3  distribution.pl      integer pids + Id@Node global addressing,
         remote_protocol.pl   routing, controller tables, wire protocol,
         rpc.pl               outbound WS client; implements actors'
                              remote hooks. rpc/promise/yield are
                              HTTP-client-only and need actors + http only.
Layer 2  toplevel_actors.pl   '$call'/'$next'/'$stop' query actors;
         dollar_expansion.pl  $Var shell support
Layer 2b behaviours           server_actor, supervisor_actor, statechart_*
                              (model/runtime/exec/actor), parallel
Layer 1  isolation.pl         temporary per-actor modules; load_text/1,
                              load_list/1, load_uri/1, load_predicates/1;
                              actor-I/O prelude; consult_load_list,
                              listing_private. Imports layer 0 (allowed:
                              imports only go downward) — unlike Jan's
                              fully freestanding isolation, because the
                              I/O prelude and private-listing builtins
                              are actor-coupled.
Layer 0  actors.pl            spawn/send/receive/self, links, monitors,
                              register/whereis, exit, delayed send, actor
                              I/O routing. Pids are OPAQUE local handles —
                              no integer pids at this level (§2.4).
                              Stand-alone: loads with ZERO project imports.
```

Rules:

1. A layer never imports upward. Enforced mechanically (§4.3).
2. `actors.pl` alone must be a useful Erlang-style actor library for any
   SWI-Prolog program — no isolation, no sandbox, full access to all of
   SWI's libraries.
3. Each layer is loadable without the ones above it:
   `actors` alone; `actors+isolation`; `…+toplevel_actors`;
   `…+behaviours`; everything `+distribution`; full node.

### 2.2 Hook inventory

Declared in **actors.pl** (multifile, one call site each, caller provides
the local fallback so a missing layer degrades to local-only behavior).
As built in Phase 1 (`prolog/web_prolog/actors.pl`):

| hook | implemented by | default when absent |
|---|---|---|
| `hook_spawn(Goal, Pid, Options)` | distribution | local spawn (`node(N)`, N≠localhost ⇒ existence error) |
| `hook_send(Pid, Msg)` | distribution | local delivery / name error / silent-if-dead |
| `hook_exit(Pid, Reason)` | distribution | local thread signal |
| `hook_self(Pid)` | distribution | canonicalized local pid |
| `hook_make_pid(Pid)` | distribution (mints integer) | `actor(N)`, monotonic counter |
| `hook_make_ref(Ref)` | distribution (mints integer) | `ref(N)`, monotonic counter |
| `hook_canonical_pid(Pid0, Pid)` | distribution (`Id@Node` globalization) | identity |
| `hook_local_pid(Pid0, Local)` | distribution (`Id@Node` localization) | identity |
| `hook_start_body(Pid, Goal, Opts, OnReady, OnPrepError, Runner)` | **composition layer only** (a pure forwarder to `isolation:spawn_body/6`) | notify parent, run goal in caller's module. The handshake protocol travels as closures the core constructs — implementations never import or name a layer-0 predicate |
| `hook_spawn_options(Goal, Opts0, Opts)` | node layer (sandbox prepare) | identity |
| `hook_spawn_context(Goal0, Goal)` | node layer (execution-context propagation) | identity |
| `hook_monitor(W, Pid, Ref)` / `hook_demonitor(Ref)` | distribution (mirror tables) | no-op |
| `hook_pid_activated(Pid)` / `hook_spawn_failed(Pid)` / `hook_stop(Pid)` | distribution (reservation + controller cleanup) | no-op |
| `hook_spawn_prepare/commit/abort` | node layer (WS-context inheritance triple) | no-op |
| `hook_namespace(NS)` | node layer (public execution namespace) | fail ⇒ namespace `global`, no filtering |

Deltas against the original sketch: `hook_goal/3` split into the
child-side `hook_start_body/4` (so the demonstrator's
initialized/start_error spawn handshake stays in the core, exactly
preserved) plus the caller-side `hook_spawn_options/3` and
`hook_spawn_context/2`; `hook_link/2` proved unnecessary (links mirror
through the spawn path and `hook_stop/1`); `hook_event/1` and
`hook_setting/2` are not needed in layer 0 at all — after extraction
the core neither logs nor reads node values (both reappear as
distribution/node concerns in Phases 5–6).

Declared in **isolation.pl** (as built in Phase 2; the shared-db import
got its own hook rather than riding `prepare_module`, and
`approve_source` materialized as the source-option/text rewriting
triple):

| hook | implemented by | purpose |
|---|---|---|
| `prepare_module(Module, GoalModule, Options)` | behaviours (statechart API import), distribution (`@`/2 op), node layer | extend the fresh actor module; all solutions run |
| `prepare_goal(Module, Goal0, Goal)` | node layer | public-profile goal guard (today's `rewrite_goal_if_needed/3`) |
| `prepare_source_options(SourceModule, Opts0, Opts)` | node layer | sandbox vetting of load options (today's `sandbox_prepare_source_options/4`) |
| `extra_prelude_text(Options, Text)` | node layer | public runtime guard prelude; all solutions collected |
| `rewrite_source_text(Module, Src0, Src)` | node layer | blacklist source rewriting |
| `source_text_guard_active` | node layer | force load_uri through text (so rewriting applies) |
| `shared_database_module(M)` | node layer | shared-db import + post-load shadow repair |

And in **source_utils.pl**: `load_uri_allowed_origins(Origins)` (node
layer's fetch allowlist; absent = unrestricted) and `self_base_url(URL)`
(distribution/node; node-relative URI resolution).

Declared in **toplevel_actors.pl**:

| hook | implemented by | purpose |
|---|---|---|
| `hook_toplevel_spawn(Pid, Options)` | distribution | remote toplevel spawn (today's `remote_toplevel_spawn_options` + `remote_request_spawn` path) |

### 2.3 Hook composition rules (the part that keeps this sane)

- Every hook has **exactly one call site** in its owning library, wrapped as
  `( hook(...) -> true ; Default )`.
- Transformation hooks (`hook_start_body/4`, `prepare_goal/3`) must **never**
  be composed by multifile clause interleaving — load order would change
  semantics. Each lower layer exports its transformation as an ordinary,
  documented predicate; the **umbrella defines the single chain**, in a fixed
  order, exactly as Jan's `web_prolog.pl` does with its `hook_goal`:

  ```prolog
  %  The handshake closures are built by the core and travel through
  %  the hook; the composition clause is a pure forwarder.
  actors:hook_start_body(Pid, Goal, Options, OnReady, OnPrepError, Runner) :-
      isolation:spawn_body(Pid, Goal, Options, OnReady, OnPrepError, Runner).
  ```

- When only `actors.pl` is loaded, no `hook_start_body` clause exists → the
  core notifies the parent and runs the goal unwrapped in the calling
  module, full SWI available. This is precisely the "stand-alone library"
  behavior wanted.

### 2.4 Pid representation: integers arrive with distribution

Integer pids exist in the demonstrator for two reasons, and both are
distribution-shaped: stable serializable names that can cross the wire, and
`Id@Node` global addressing. Purely local actors need neither. Therefore:

- **Layer 0 pids are opaque local handles.** `actors.pl` mints, compares,
  registers, monitors, links, and resolves pids without ever assuming a
  shape. There is no `make_id` integer minting and no `@`/2 in the core.
  As built: the default pid is the compound `actor(N)` from a
  process-monotonic counter — never reused (so post-mortem monitor and
  exit-reason state keyed by pid cannot be confused by thread-id
  recycling) and structurally distinct from registered-name atoms in
  `send/2`. The pid↔thread tables remain, keyed by the opaque pid.
  Minting and resolution go through `hook_make_pid/1`,
  `hook_canonical_pid/2`, and `hook_local_pid/2`.
- **Distribution installs the demonstrator pid model.** `distribution.pl`
  implements the two hooks: allocate the integer, keep the integer↔handle
  table, canonicalize `Id@Node`, and own the `@`/2 operator export plus
  today's `pid_utils.pl` machinery (`canonical_pid/2`, `localhost_node/1`,
  `register_node_self/1`, …). With distribution loaded, `self/1`, message
  terms, and printed pids are byte-identical to the demonstrator.
- **Precedent:** this is exactly Jan's design — in swi-web-prolog the engine
  handle *is* the pid in `actors.pl` (`hook_send` even accepts `thread(Tid)`
  forms), and `Id@Node` appears only in `distribution.pl`.
- **Phase 1 decision, with constraints:** the concrete opaque handle is
  either the anonymous thread/queue reference or a per-actor generated alias
  atom. The constraints that decide it: the handle must stay valid and
  un-recycled while monitors, links, or `exit_reason` bookkeeping for the
  actor are still outstanding (SWI recycles numeric thread ids after join —
  the demonstrator's stable integers currently paper over this, so the
  chosen handle must not reintroduce the problem).
- **Externalization audit:** anything that needs a *printable, stable,
  copyable* pid — wire messages, `/call` continuations, ISOTOPE session
  keys, `/ws` JSON events, `dollar_expansion` bindings — must sit at or
  above layer 3, where integer pids exist. Layers 0–2b may embed pids in
  messages and tables but never serialize them.

### 2.5 Module mapping (demonstrator → new home)

| demonstrator module | new home |
|---|---|
| `actor.pl` (local core) | layer 0 `actors.pl` |
| `actor.pl` (WS client, `spawn_remote`, `remote_ws_*`) | layer 3 `distribution.pl` |
| `pid_utils.pl` | layer 3 (pid shape is a distribution concern, §2.4; its `node_runtime_state` import replaced by `hook_setting`) |
| `actor_source.pl`, `source_loader.pl`, `source_utils.pl`, `actor_io_support.pl` | layer 1 `isolation.pl` (+helpers) |
| `toplevel_actor.pl` (local) | layer 2 `toplevel_actors.pl` |
| `toplevel_actor.pl` (remote spawn part) | layer 3 |
| `dollar_expansion.pl`, `term_display.pl` | layer 2 |
| `server.pl`, `server_actor.pl`, `supervisor_actor.pl`, `parallel.pl` | layer 2b (near-verbatim) |
| `statechart_model/runtime/exec/actor.pl` | layer 2b — **break the `statechart_actor → node_session` upward edge** (inject the session-notify target via an option or io-target instead) |
| `node_controller.pl`, `remote_protocol.pl` | layer 3 |
| `node_client.pl` | split: `rpc/promise/yield` → layer 3 `rpc.pl`; request-normalization helpers → layer 4 |
| `node.pl`, `node_ws.pl`, `node_session.pl`, `node_isotope_*`, `node_engine.pl`, `node_call_context.pl`, `node_response.pl`, `node_startup_options.pl` | layer 4 |
| `node_admin.pl`, `node_auth.pl`, `node_capabilities.pl`, `node_*_policy.pl`, `node_sandbox.pl`, `public_goal_guard.pl`, `goal_walker.pl`, `node_*limit*.pl`, `node_rate_limits.pl`, `node_log*.pl`, `node_interaction_log.pl`, `node_owner_tag.pl`, `shared_db.pl` | layer 4 (policy/ops sub-package) |
| `node_runtime_state.pl`, `node_execution_context.pl` | split: the few keys the core/toplevel read move behind `hook_setting/2` with compiled defaults; the rest stays layer 4 |
| Browser-runtime ports (`test_statechart_wasm`, `examples/swi-wasm-*`, dual-runtime conditionals) | **dropped** |
| `web/demonstrator.html` shell | ships as optional `web/` app served by the node (decision point §6) |

### 2.6 Repository / packaging

New repository, created as a fork of trinity-demonstrator (history
preserved — the recent cross-node race fixes are documentation). Packaged as
an SWI-Prolog **pack** so "serious use by others" is one command away:

```
<new-repo>/
├── pack.pl                       % pack metadata, version, requires
├── prolog/
│   ├── web_prolog.pl             % layer 5 umbrella
│   └── web_prolog/
│       ├── actors.pl             % layer 0
│       ├── isolation.pl          % layer 1 (+ source_loader.pl, …)
│       ├── toplevel_actors.pl    % layer 2 (+ dollar_expansion.pl)
│       ├── server_actor.pl  supervisor_actor.pl  parallel.pl
│       ├── statechart/…          % layer 2b
│       ├── distribution.pl  remote_protocol.pl  rpc.pl   % layer 3
│       └── node/…                % layer 4
├── web/                          % optional shell UI
├── tests/                        % tiered, see §4
├── examples/
└── docs/
```

Usage modes this enables:

```prolog
:- use_module(library(web_prolog/actors)).        % just actors, full SWI
:- use_module(library(web_prolog/rpc)).           % rpc/promise/yield client
:- use_module(library(web_prolog)).               % the whole language
?- node(3060).                                    % run a node
```

---

## 3. Semantics freeze — how "exactly the same" is guaranteed

1. **The spec is the demonstrator.** `WEB_PROLOG_BUILTINS.md` +
   acceptance matrix (language surface, error terms),
   `PROFILE_MATRIX.md` (ISOBASE/ISOTOPE/ACTOR behavior),
   `CROSS_NODE_ARCHITECTURE.md` (wire protocol + lifecycle invariants).
   These documents are copied into the new repo as normative.
2. **Port the test suite before porting the code** (Phase 0). The suite
   (`actor_tests`, `toplevel_actor_tests`, `node_tests`,
   `statechart_*_tests`, `server/supervisor/parallel` tests,
   `multi_node_harness`, conformance tests) becomes the acceptance gate for
   every phase.
3. **Wire-level interop test**: the strongest "exactly" check — a
   multi-node test where one node is the unmodified demonstrator and the
   other is the new implementation, exercising remote spawn, send, monitor,
   link, exit, remote toplevels, and rpc in both directions. The JSON-over-WS
   protocol is kept bit-compatible (and gets a version field for the future).
4. **Golden response tests** for `/call` and ISOTOPE JSON/Prolog-text
   answers, pinned from demonstrator output (error-message simplification in
   `node_response.pl` is part of observable semantics).
5. **Pid shape is pinned at the composed level.** With distribution loaded
   (T4/T5), `self/1`, printed pids, wire pids, and `Id@Node` forms must be
   exactly the demonstrator's. Below distribution (T0–T3) pids are opaque
   (§2.4), so ported tests for those tiers must be made pid-shape-agnostic —
   any demonstrator test asserting `integer(Pid)` or `_@_` either moves to
   T4 or has the assertion relativized.

### On "more libraries can be employed by users"

The freeze applies to the **language**: syntax, control constructs, actor and
pengine protocols, pid syntax, error terms, profile behavior. It does not
force the library *blacklist* on trusted code: a stand-alone `actors.pl` user
gets all of SWI-Prolog (there is no sandbox below layer 4 at all), and the
node's policy layer keeps profiles, where the **default public profile is
configured identically to the demonstrator** while node owners may open up
more libraries for authenticated/trusted principals. That is a configuration
delta, not a semantic one.

---

## 4. Test matrix and layering enforcement

### 4.1 Tiers (each tier = a separate `swipl` process in CI)

| tier | loads | runs | also asserts |
|---|---|---|---|
| T0 | `actors` only | actor tests not needing source options | `\+ current_module(isolation)`, `\+ current_module(distribution)`, … |
| T1 | + `isolation` + glue | module-prep / `load_*` tests | no toplevel/distribution/node modules |
| T2 | + `toplevel_actors` | toplevel actor tests | no distribution/node |
| T3 | + behaviours | server/supervisor/statechart/parallel tests | no distribution/node |
| T4 | + `distribution` + `node` | node_tests, multi_node_harness, WS/ISOTOPE/ISOBASE | — |
| T5 | new node ↔ demonstrator node | cross-implementation interop (§3.3) | — |

The "also asserts" column is the **layer-honesty check**: it catches any
accidental re-entanglement the moment it happens.

### 4.2 Hook-default tests

For every hook: a test that the owning layer behaves correctly when **no**
clause is defined (the fallback path), and one with a trivial test clause
(the hook path). This pins the hook contracts themselves.

### 4.3 Layering lint

Reuse/extend `tools/generate_dependency_graph.py`: add an *allowed-edges*
matrix (layer N may import layers ≤ N) and fail CI on violations. The tool
already extracts exactly the right edges.

---

## 5. Phased migration

Each phase ends with a gate; no phase starts until the previous gate is
green. Code moves **verbatim wherever possible** (same predicate names, same
logic) — the diff per phase should be dominated by *relocation* plus the
small hook indirections.

- **Phase 0 — bootstrap.** Fork repo; prune browser-runtime and demonstrator-only
  deployment files; set up pack skeleton, CI, tiered test runner; port the
  test suite (mostly red); copy normative docs.
- **Phase 1 — core `actors.pl`.** Excise the WS client and
  `node_controller` calls (parked in a private staging module until Phase 5);
  replace isolation/policy call sites with `hook_goal` and `hook_setting`;
  replace `log_event` with `hook_event`; replace integer pid minting and
  lookup with opaque handles behind `hook_make_pid`/`hook_resolve_pid`,
  choosing the handle representation per the §2.4 constraints. *Gate:*
  `actors.pl` loads in a bare SWI with zero project imports; no integer pid
  machinery below layer 3; T0 green.
  *(N.B. the hook names in this bullet are the original sketch; the
  as-built inventory in §2.2 supersedes them — `hook_goal` became
  `hook_start_body/6` (handshake closures as arguments) +
  `hook_spawn_options`/`hook_spawn_context`, and
  `hook_setting`/`hook_event` turned out not to be needed in layer 0.
  The hooks live in `prolog/web_prolog/actors.pl`, module `actors`;
  the demonstrator's `actor.pl` (upstream / git history) is the
  pre-layering reference.)*
- **Phase 2 — `isolation.pl`.** From `actor_source` + `source_loader` +
  `source_utils` + `actor_io_support`, with `prepare_module/3`,
  `prepare_goal/3`, `approve_source/2` hooks; minimal umbrella glue defined
  for tests. *Gate:* T1 green.
- **Phase 3 — `toplevel_actors.pl`.** Local toplevel protocol only; remote
  path behind `hook_toplevel_spawn`; `dollar_expansion` moves here.
  *Gate:* T2 green.
- **Phase 4 — behaviours.** `server*`, `supervisor_actor`, `statechart_*`
  (breaking the `node_session` upward edge), `parallel`. *Gate:* T3 green.
- **Phase 5 — `distribution.pl` + `rpc.pl`.** Controller tables,
  `remote_protocol`, the parked WS client, remote toplevel spawn — all as
  implementations of the layer-0/2 hooks. `rpc/promise/yield` extracted to
  `rpc.pl` (needs only actors + HTTP client). *Gate:* multi_node_harness
  green; T5 interop against a running demonstrator node green.
- **Phase 6 — node layer.** The full server: ISOBASE/ISOTOPE/ACTOR
  endpoints, sessions, auth, profiles, sandbox/guard (now installed as
  isolation hooks), limits, admin, interaction log (installed as
  `hook_event`). *Gate:* T4 green; golden response tests green; profile
  matrix verified.
- **Phase 7 — umbrella + release.** `web_prolog.pl` with the single
  `hook_goal` chain; pack metadata; PlDoc throughout; per-layer README;
  examples ported. *Gate:* `pack_install` from git works on a clean machine;
  all tiers green in CI.
- **Phase 8 — turn-key production node.** The goal sharpened from "hardening"
  to **a pack anyone can install and run as a production node on the open
  Web** — secure by default, administrable without editing source, resilient
  to hostile traffic. The full gap analysis (✅/🟡/❌ against today's surface,
  administration-focused) is in
  [`TURNKEY_NODE_REQUIREMENTS.md`](TURNKEY_NODE_REQUIREMENTS.md). Realistic
  bar for a **public v1** (that doc's items 1–5):
  - [x] deploy bundle (systemd/Docker/Caddy/compose) + TLS/ACME; `/healthz`,
        `/readyz`, `/version`
  - [x] secure-by-default first run (auth=private, open refused without
        WP_ACK_PUBLIC; sandbox defaults to blacklist — the playground
        default, with whitelist available for a hardened node); config
        validation (WP_CHECK=1);
        single declarative web-prolog.conf with env overrides
  - [x] per-actor inference/memory/stack ceilings + global concurrency cap
        (max_call_inferences, max_actor_stack_bytes, max_actors; default
        unlimited in the library, bounded in the deploy bundle) — the
        503-at-edge + table-space/output caps remain
  - [x] `/metrics` (aggregate gauges: activity + limits + process) +
        interaction-log rotation (max_interaction_log_bytes/backups) —
        cumulative request/rejection-by-reason counters remain
  - [x] graceful drain (SIGTERM in start_node.pl) + maintenance mode
        (POST /admin/maintenance, surfaced via /readyz) — headless admin
        is the existing curl-able HTTP API; a wp-admin CLI wrapper remains
  - [x] protocol version field — remote_protocol:protocol_version/1 (=1),
        surfaced at /version and announced via the X-Web-Prolog-Protocol
        header on outbound cross-node /ws; additive (demonstrator ignores
        it), interop pinned by T5
  - [ ] tagged v1 release
  Then hardening for multi-tenant/federated use (doc items 6–7): IP/CIDR
  controls, config-change audit, abuse-contact surface, and federation trust
  that does not rely on network position (mTLS/signed node identity).

### Status (as built, 2026-06-11)

Phases 0–7 are complete in /Users/lager/web-prolog; all gates green
(tiers LINT + LEGACY 514 / T0 31 / T1 11 / T2 24 / T3 73 / T4 352 /
T5 21 ≈ 1030 tests). Gate items that were initially skipped and have
since been delivered:

  - **Golden response tests** (Phase 6 gate): built in their stronger
    differential form — tier T5 runs the unmodified demonstrator and
    the new node side by side and byte-compares `/call` responses
    (pids masked). One legitimate divergence found and ledgered in
    DEVIATIONS.md: raw `prolog_stack` contexts in `format=prolog`
    error responses reflect the new module names; the error formals
    and simplified JSON messages are identical.
  - **Profile matrix verified** (Phase 6 gate): the Route Matrix from
    PROFILE_MATRIX.md transcribed as data and checked exhaustively
    against `profile_allows_route/2` (suite `t4_profile_matrix`).
  - **§4.3 layering lint**: `tools/generate_dependency_graph.py
    --check` enforces the allowed-edges matrix (layer map for every
    module under prolog/; unassigned files fail); wired into
    tools/test.sh as the LINT tier and run by CI.
  - **`pack_install` verification** (Phase 7 gate): verified against a
    clean pack directory from a release archive —
    `web_prolog-<V>.tgz` (git archive), installed via
    `pack_install(web_prolog, [url('file://…tgz')])`, then
    `library(web_prolog)` loads from the installed pack.

Known remaining deltas from the letter of the plan:

  - **§4.2 per-hook default tests**: explicit default/takeover pairs
    exist for the central hooks (spawn/send/make_pid/start_body,
    prepare_module/prepare_goal, toplevel + service-registry); the
    rest are covered behaviorally by the tier suites rather than by a
    labeled per-hook suite.
  - **multi_node_harness** went green in Phase 6 (with the node
    layer), not Phase 5 — the harness needs a node server on both
    sides, which the original gate text overlooked.
  - **PlDoc sweep + per-layer READMEs** and **CI actually running**
    (needs the GitHub repo decision) remain open, folded into Phase 8
    alongside the deployment docs that must replace the pruned
    Deployment/ tree.

---

## 6. Decision points (recommendations included)

1. **Name / repo home.** Recommend a fresh repo under the Web-Prolog org,
   pack name `web_prolog`, created as a fork of trinity-demonstrator so
   history survives.
2. **Web shell UI.** Recommend shipping the (ported) shell in-pack under
   `web/`, served by the node but cleanly optional — it is the best demo of
   the node and costs little.
3. **Library policy for trusted users.** Recommend: public profile identical
   to the demonstrator; per-principal/profile opt-in for additional SWI
   libraries (the policy machinery already supports profiles).
4. **Admin/auth/limits subsystem.** Recommend porting as-is in Phase 6 (it
   is the "serious use" substance), simplifying only after v1.
5. **Hook naming.** Recommend Jan's names (`hook_spawn/3`, `hook_send/2`,
   `hook_self/1`, `hook_goal/3`, `prepare_module/3`, `prepare_goal/3`) for
   continuity, with the new lifecycle hooks following the same convention.

---

## 7. Risks and mitigations

| risk | mitigation |
|---|---|
| Cross-node lifecycle races (only recently fixed) regress when code relocates | move verbatim, keep predicate names; multi_node_harness + T5 interop as hard gates; relocation and behavior changes never share a commit |
| Hook/load-order coupling (layer loaded vs not changes behavior unpredictably) | one call site per hook with explicit fallback; single umbrella-owned chain for transformation hooks; tier tests run every layer combination |
| Hidden upward deps re-appear over time | layer-honesty assertions in T0–T3 + allowed-edges lint in CI |
| Thread-local context (`node_runtime_state`, `node_execution_context`) is read below layer 4 | `hook_setting/2` with compiled defaults in layer 0; node layer overrides at startup — formalizes the existing `node_setting/2` |
| Observable error/response drift | golden tests pinned from demonstrator output before porting starts |
| Opaque-handle pids: SWI recycles thread ids, and the demonstrator's stable integers currently mask that for post-mortem state (monitors, `exit_reason`) | choose the layer-0 handle against the §2.4 validity constraints in Phase 1; add T0 tests for monitor/exit delivery after actor death; audit every pid externalization point and keep serialization at/above layer 3 |
| Scope creep ("while we're at it" improvements) | semantics freeze: any intentional deviation needs an entry in a `DEVIATIONS.md`, which should stay empty through v1 |
