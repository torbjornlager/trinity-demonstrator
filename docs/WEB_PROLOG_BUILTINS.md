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

## SWI-WASM correctness coverage

The browser worker and main-engine compatibility runtimes advance RPC paging
by the actual slice length. Their worker collectors select replies before
unifying caller outputs; `first_solution/2-3` cleans up its workers before an
output mismatch fails. Unexplained exits use `worker_exit(Pid, Reason)` and
`first_solution/3` applies its existing `on_error/1` policy. Worker exceptions
retain their original term. Once a parallel worker's answer is accepted, its
termination notification only confirms completion; later workers' normal
notifications can remain deferred while earlier results are collected.

Browser `yield/2-3` returns `timeout` on an elapsed wait unless its callback
binds the answer, keeps the promise available for retry, and reports callback
failure explicitly. Unknown, consumed, expired or disposed integer references raise
`existence_error(promise, Ref)`. Worker-side transport rejection becomes an
`error(rpc_error(Detail))` answer, as main-engine fetch failures already do.
Worker-scope cleanup is described under Parallel Goals below.
Native-style client ownership and transport parity with the native runtime
remain separate work.
The WASM tier tests these rules using the bundled engine under Node; it does
not replace interactive browser integration testing.

## Notes on Scope

- This is a predicate catalog, not a full catalog of flags, error classes,
  option terms, or every helper predicate exported by internal runtime
  modules.
- This document records the intended built-in surface of the `actor` profile.
  The acceptance matrix is the more precise companion when the question is what
  client-submitted code is actually accepted on a given route.
- Some predicates are context-specific as well as profile-specific. For
  example, conversational I/O requires an actor or session context, and
  `raise/1` and `in/1` are meaningful only inside statechart execution.
- Ambient stream and file I/O are blacklisted. Web Prolog instead supplies
  actor-local output predicates such as `write/1`, `writeln/1`, and `format/2`
  through the actor runtime prelude.
- `clause/2` remains available only in its narrowed blacklist-safe form: the
  head must name a local or shared application predicate. Runtime predicates
  and module-qualified heads are blocked; inspection does not grant mutation.

## 7.4.2 Directives

`dynamic/1`, `multifile/1`, `discontiguous/1`.

**Blacklisted:** `op/3`, `char_conversion/2`, `initialization/1`,
`include/1`, `ensure_loaded/1`, `set_prolog_flag/2`.

## 7.8 Control Constructs

`true/0`, `fail/0`, `call/1`, `!/0`, `(',')/2`, `(;)/2`,
`(->)/2`, `catch/3`, `throw/1`.

Web Prolog `catch/3` has ordinary ISO catcher-unification and recovery
semantics for application exceptions. Runtime control transfers are reserved:
actor termination (`unwind(abort)`), PTCP abort, and PTCP execution-time
expiry bypass application recovery. Cleanup installed by
`setup_call_cleanup/3`, `setup_call_catcher_cleanup/4`, or `call_cleanup/2`
still runs while the control transfer unwinds. The rule also applies to
catches in loaded source, dynamically constructed `call/1-8` goals, and
dynamically asserted clause bodies.

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

`clause/2` — read-only inspection of local and shared application predicates,
with local definitions taking precedence. Returns original source-level bodies
for meta-interpreters such as example 18. Runtime predicates, other imports and
module-qualified heads are blocked.

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
`time/1` emits a timing output event instead of printing to the host shell and
is available from the ISOBASE profile onward; its nested goal is checked
independently against the active profile and sandbox policy.

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

Native `spawn/3` validates every option before local setup or remote dispatch.
Options must be unary terms in a proper list. Unknown names, wrong arities,
and misplaced wrapper options (including plain `spawn/3`'s unsupported
`name/1`) raise `error(domain_error(spawn_option,Option),_)`. Invalid values
raise type, domain, or instantiation errors with `actors:spawn/3` in the
context. `link/1` and `monitor/1` require booleans; `node/1` takes an atom or
string. Isolation declares `src_text/1`, `src_list/1`, `src_uri/1`, and
`src_predicates/1` through a lower-layer validation hook: text retains the
native atom/string/codes/chars convention, source lists must be proper
lists, source URIs atoms/strings, and predicate indicators atom names with
nonnegative integer arities. Shape validation does not replace source-access,
sandbox, or ownership policies. The stand-alone actor core does not accept
source options unless an isolation provider has declared them.

Both SWI-WASM runtimes now validate plain `spawn/3` options before source
collection, pid reservation, worker startup, remote dispatch, or monitor setup.
The proper-list/unary-term rule applies to every occurrence, including later
duplicates. Errors have `spawn/3` in the context; unknown or misplaced options
raise `domain_error(spawn_option,Option)`. The browser vocabulary is:

- `node/1`: an atom or string; `link/1` and `monitor/1`: booleans.
- `name/1`: an atom, retaining the browser's existing local naming convenience
  (plain native `spawn/3` does not accept this option).
- `target/1` and `io_target/1`: nonvariable compatibility routing terms. Plain
  browser spawning continues to use its existing coordinator output routing;
  accepting these terms does not implement per-spawn output redirection.
- `src_text/1`: an atom or string; `src_list/1`: a proper list;
  `src_predicates/1`: a proper list of atom/nonnegative-integer indicators.
- `src_uri/1`: an atom or string in both browser runtimes. The creating
  engine asks the page coordinator to fetch Prolog source before child creation;
  remote spawning forwards the fetched text, rather than asking the remote node
  to fetch the URI. Server, supervisor and toplevel wrappers use the same path.

Worker source collection retains its groups: all `src_text/1` entries, then
`src_list/1`, then `src_predicates/1`, followed by `src_uri/1`. Entries within
each group retain their option order. Repeated URIs are fetched separately.
The compatibility main engine retains source-option list order. URI fetching
uses the existing explicit origin allowlist, `credentials: same-origin` and
browser CORS rules; this adds no arbitrary-origin, file or authentication support.
Fetch errors propagate without creating a child, and a failed or interrupted
creation releases its reserved name. A late fetch completion cannot resume an
abandoned creation. This does not add cancellation of an in-flight source fetch.

Validation does not bind or copy option terms. Existing first-occurrence
precedence, source collection order within each runtime, and goal/pid sharing
are unchanged. Browser remote spawning still forwards goal and source and
installs a caller-side monitor when requested. Names are browser-local aliases;
remote link forwarding and remote output routing are unchanged.
Both SWI-WASM runtimes reserve `name/1` creation in the page coordinator
before starting an actor. This covers plain spawn, servers, supervisors,
toplevels, and both statechart routes, preserving the main engine's fixed
`statechart` pid. The first name option wins, after validation of every duplicate.
An occupied or pending name raises
`error(permission_error(register,actor_name,Name),PI)`, with the creation predicate
in `PI`; no actor is created for that collision. Reservations occupy only the
ordinary actor namespace and remain hidden from `whereis/2`. Explicit register
cannot steal them, and unregister cannot release them. Publication and rollback
require the creating engine's matching token; late cleanup cannot erase a
committed binding or a different creator's reservation. The reservation stays
rollback-owned across the publication-approval wait; only Prolog's subsequent
commit makes the alias visible.

The name is published only after the complete creation call succeeds, including
monitor setup and a supervisor's initial child startup. Wrappers strip
`name/1` internally while they hold its reservation, avoiding a second,
independent registration. Startup failure, exception or unwinding releases the
reservation and reclaims the attempt's actors/monitors through the startup
journal, including detached and nested children. Caller termination releases its
pending reservations. Normal early actor termination still returns the pid and
its requested monitor notification, but publishes no stale alias. Main-thread
statechart halt/completion removes that chart's aliases; halt permits name reuse
within the same query. Names do not establish application-level readiness or
continued actor liveness after return.

The page's ordinary-name namespace is shared by browser actors, rather than
being separate for each supervisor. Child ids are still structurally validated
within each sibling list; forwarding them as names can therefore encounter a
runtime collision with another live child's name elsewhere in the page.
Actor/service namespaces, one-name-per-pid rules within each namespace, links,
monitor references, pid sharing, and successful reply formats are preserved.
The same reservation now covers existing supported remote creation paths,
including plain remote spawn and remote toplevels. The name is a browser-local
alias, not a registration or published service on the remote node. A collision
fails before connection or dispatch. Existing remote wrapper capabilities,
source-loading rules, monitor references and unnamed behavior are preserved.

Remote spawn commands carry the existing `request_id` field. A reply with an id
settles only that request, including reordered replies and errors. Unnamed
requests retain FIFO compatibility when a peer omits the id; named requests
reject an uncorrelated reply with a diagnostic containing
`remote_spawn_failed(uncorrelated_spawn_reply)`. Its ambiguous pid is not claimed
or terminated. The native reader preserves this existing field on command errors as well as
acknowledgements; no new wire fields or capability negotiation are added. Cleanup exit commands also carry request ids,
so their errors cannot be mistaken for later spawn replies from supporting peers.

Acknowledgements enter the exact startup journals before resolving the caller's
wait. Failure, output mismatch, interruption or creator termination releases the
reservation, withdraws startup-owned monitors, and requests termination of known
remote pids, preserving unrelated monitors and the original outcome. An abandoned
attempt retains its pending reply record until acknowledgement or connection
close; a correlated late acknowledgement receives a best-effort termination
request and cannot publish a name. Cancellation before connection readiness
prevents late dispatch. Publication approval remains rollback-owned until commit.
Observed termination or connection loss before commit prevents publication with
`error(remote_spawn_failed(terminated),PI)` or
`error(remote_spawn_failed(connection_closed),PI)`.

Startup guards end at commit. Published ordinary remote aliases are cleaned up
on observed events as described below. This does not add implicit ongoing
monitoring, remote activation handshakes or guaranteed cancellation. Remote application effects may occur before alias publication and
are not undone. Connection loss before a correlated acknowledgement can leave
an unknown remote outcome. Broader lifecycle work remains separate.

Both SWI-WASM runtimes withdraw ordinary remote aliases when their existing
transport observes a `down` for that exact pid, including notifications with no
matching local monitor. On connection loss, ordinary aliases for that node are
withdrawn. Removal precedes delivery of monitor notifications, allowing immediate
name reuse in their handlers. Cleanup checks each current binding: a delayed
termination event cannot erase a name reassigned to another pid. Local names,
other nodes, service registrations, application messages and unrelated monitors
are preserved. Pending startup guards continue to prevent late publication.

This uses existing observations only; no implicit monitors, probes or retirement
records are installed. Without an observed event, explicit `unregister/1` may
still be needed. Connection loss removes aliases without establishing remote
actor death. Explicit registration after the event can recreate an alias under
the existing remote registration rules; no new admission or ownership policy is
introduced.


The shared server/supervisor implementation removes its own unary fields
(`initial_state/1`, or `strategy/1`, `intensity/1`, and `period/1`) before
calling plain spawn. Child creation similarly separates `start/1`, `restart/1`,
`shutdown/1`, `type/1`, and `significant/1`, retaining the original specification
in supervisor state. All other options remain available to the spawn validator;
filtering neither copies terms nor discards unknown options. This is an
internal separation; wrapper entry validation is described below. Child-specification
validation remains separate, and no new semantics are introduced for previously
unused metadata.

Native local actor I/O accepts nonvariable `target/1` and `io_target/1`
routing terms, with `io_target/1` taking precedence. Bare WebSocket spawning
retains connection-owned routing: its reserved target/link settings are still
supplied by the endpoint. Ordinary options keep their first-occurrence
semantics; every occurrence is validated. Source options retain their order
and variable sharing. No value validation fetches source or inspects target
liveness. Effective local options are validated again after runtime rewriting
and before pid allocation.

The raw bare-actor WebSocket endpoint validates client options before source
preparation, capacity reservation, or server metadata injection. Internal
`source_module/1`, `inherit_goal_module/1`, `isolation_io/1`,
`monitor_target/1`, and `monitor_ref/1` remain recognized and shape-checked for
framework setup, but raw remote clients receive
`error(permission_error(option,internal_spawn_option,Option),_)` for these
fields. Existing native authority checks remain in force.

Runtime composition uses `actors:validate_spawn_options(Options, Scope)`
with `Scope` equal to `runtime` or `public`, and declares extension options
through `actors:hook_spawn_option(Name, Visibility, Validator)`. A declaration
specifies `public` or `internal` visibility and a module-qualified unary
validator that succeeds or throws without binding inputs or fetching source.
Recognition does not grant authority. Specialised creation wrappers validate
their complete option lists before consuming their own options and forwarding
spawn options:

- `toplevel_spawn/2`: atom `name/1`, boolean `session/1`, and positive numeric
  or `infinite` values for `time_limit/1` and `idle_limit/1`.
- `server_spawn/4`: atom `name/1`.
- `supervisor_spawn/3`: atom `name/1`; `strategy/1` is `one_for_one`,
  `one_for_all`, or `rest_for_one`; `intensity/1` is a nonnegative integer;
  `period/1` is a positive number of seconds (fractional values remain valid).
  Nested supervisors use the same checks for supervisor settings.
- `statechart_spawn/2`: atom `name/1` and boolean `trace/1`, preserving its
  duplicate-trace rejection and exactly-one-XML-source rule. Supplemental
  Prolog sources remain accepted.

All forwarded options are checked with the existing spawn schema. Unsupported
options raise `error(domain_error(spawn_option,Option),Context)`; malformed
values raise type, domain, or instantiation errors. The context identifies
the creation wrapper. Unbound values are rejected without binding them.
Every occurrence is validated; ordinary settings still use the first
occurrence and source options retain their order and sharing. No wrapper
schema extends the option vocabulary of plain `spawn/3`. Native metadata is
preserved; recognition still does not bypass authority checks. Composition
uses `actors:validate_spawn_wrapper_options/4` with a wrapper-local list of
`Name=UnaryValidator` entries alongside the existing spawn schema.

Both SWI-WASM runtimes validate `toplevel_spawn/2`, `server_spawn/4`,
`supervisor_spawn/3`, and `statechart_spawn/2` at entry, before option extraction,
source fetching/copying, pid reservation, startup, registration, or monitoring.
Lists must be proper and every element a recognised unary option. All forwarded
spawn settings use the browser schema above. Unknown/misplaced names and wrong
arities raise `domain_error(spawn_option,Option)`; malformed values raise type,
domain, or instantiation errors. The context identifies the public wrapper.
Every occurrence is validated, including later duplicates, without binding or
copying option values. Ordinary defaults, first-occurrence precedence, variable
sharing, and each runtime's source collection remain unchanged.

Browser wrapper additions are boolean `session/1` and positive numeric or
`infinite` lifecycle limits for toplevels; the three supervisor strategies,
nonnegative integer intensity and positive numeric period (fractional seconds
accepted); and boolean statechart `trace/1`. Server `initial_state/1` remains
arbitrary compatibility metadata: validation does not bind it or replace the
explicit state argument. Nested supervisor creation reaches the same wrapper
checks; browser child-specification validation is described under Supervisors.

Statechart wrappers accept atom/string `src_uri/1` in both runtimes, including
the worker. Prolog source loading for ordinary spawn and server/supervisor/toplevel
wrappers is supported in both runtimes as described above. Browser statecharts
retain first-text selection (even if a URI precedes it), otherwise first-URI
selection, and first-occurrence trace behavior. Unlike native statecharts, the
browser wrappers do not reject multiple well-typed XML sources or traces.
Supplemental Prolog source remains accepted; missing XML source still raises
the existing `statechart_source_option` error. Wrapper validation does not
change lifecycle or source-selection semantics.

The compatibility main engine's statechart routing now uses the intended
nonidentity test: `localhost` starts a chart in the main interpreter if none
is running, or creates a separate statechart worker if a chart is already
active. An explicit remote node always uses remote dispatch, whether or not
a local chart is running. Nested and remote creation preserve the active local
chart. Text/URI selection, first trace setting, supplemental source, names,
link handling and caller-side spawn monitoring retain their existing behavior
on each path. For URI XML, the main interpreter fetches its own local chart's
source, a nested worker receives the URI for its loading path, and the remote
node fetches its remote chart's XML. Regression tests execute the generated
Prolog with the real WASM parser/interpreter and mocked external transports;
they check both source kinds on all three paths.

Caller-side toplevel validation precedes local setup, source copying, and
remote dispatch. Receiving HTTP/WebSocket toplevel endpoints validate raw
client options before source preparation and metadata injection; internal
metadata cannot be supplied as raw client options. Existing HTTP session
defaults, reserved WebSocket routing, and owner ceilings are unchanged.
In addition to name-type validation, local named creation now uses a
reservation/publication protocol, described below. Supervisor
child-specification validation is described in its own section. Remote named
creation also reserves caller-side aliases, with the qualifications below.

### Actor Messaging

`send/2`, `send/3`, `!/2`, `receive/1`, `receive/2`,
`monitor/2`, `demonitor/1`, `demonitor/2`, `flush/0`.

Native JSON `down` events serialize monitor references independently of actor
addresses. A reference is opaque: a pid-shaped reference retains its complete
node qualifier, including when that node is the sender itself, and its node
text is not normalized. Other compound references are quoted Prolog term text;
integer and atomic references retain their existing JSON forms. Integers outside
the JavaScript exact-integer range remain decimal strings. The event's `pid`
field keeps its existing address normalization and local-id abbreviation;
reference serialization uses neither pid normalization nor display formatting.
This preserves browser correlation for remote `monitor(true)` without a
pid-only matching fallback. Distinct references on the same actor, withdrawn
references, and connection boundaries continue to be matched independently.

### Actor Naming

`register/2`, `whereis/2`, `unregister/1`.

Native local named creation by `toplevel_spawn/2`, `server_spawn/4`,
`supervisor_spawn/3`, and `statechart_spawn/2` reserves the first `name/1`
in the caller's existing ordinary namespace before launching an actor.
Existing namespace isolation and the independent service registry are
unchanged. An occupied or reserved name raises `name_is_in_use(Name)` before
local launch. Ordinary `register/2` respects pending name/pid claims, using
its existing collision errors.

Pending reservations are invisible to `whereis/2` and message routing.
`unregister/1` removes published bindings; it does not cancel a pending
startup. After preparation succeeds and the pid is resolvable, the readiness
handshake publishes the name before the application goal runs. Preparation
failure or cancellation releases the pending claim; a cancelled preparation
cannot later publish it. Retirement and publication use the registry mutex,
so immediate termination cannot be followed by a stale wrapper registration.
After publication, explicit unregister/rename behavior remains available.
Returning a pid does not guarantee continued liveness or completed application
initialisation; effects after activation are not rolled back by this protocol.

Composition uses `actors:spawn_with_name/4`, with an internal
`name_reservation/1` option. Raw remote clients cannot supply that metadata.
The distribution hook recognises local node URL aliases; plain `spawn/3`
still rejects `name/1`. Remote named creation through the same four wrappers
reserves the caller's ordinary alias before sending the spawn request. This
does not register a name or publish a service on the remote node. Pending
reservations remain hidden and count as occupied; concurrent creators and
`register/2` cannot take them, and `unregister/1` does not cancel them.
Generic named wrappers retain ordinary spawn validation and admission checks
before remote dispatch.

After acknowledgement, routing, link and monitor setup and buffered-event
processing precede publication under the registry mutex. Observed remote
termination or connection loss during pending startup prevents publication,
as does namespace closure. These failures release the reservation and report
the original error; observed termination/loss uses
`error(remote_spawn_failed(terminated),_)` or
`error(remote_spawn_failed(connection_closed),_)`. An unexpected plain failure
during startup raises `error(remote_spawn_failed(startup_failed),_)` rather
than falling back to another creation path. Failure or interruption
requests termination of an acknowledged pid using the existing exit command,
withdraws the startup alias and creator's startup monitor/link state, and
flushes its spawn-monitor notification. Unrelated explicit monitors are
preserved. Reader-side acknowledgement recording allows cleanup even if the
creator is interrupted before consuming the spawn reply. Connection-loss
guards apply only during startup; ordinary late remote registration remains
unchanged.
Existing transport ownership/routing bookkeeping follows its normal
lifecycle; sending an exit does not establish remote death. A peer must echo
the existing spawn `request_id` for named
creation. A reply omitting it raises
`error(remote_spawn_failed(uncorrelated_spawn_reply),_)` without claiming its
ambiguous pid. Unnamed spawning retains its existing legacy-peer behaviour.
Cleanup exit commands also carry an existing `request_id`, so a rejection
cannot be mistaken for a later spawn reply.

The remote application may run before the caller's alias is published, and
its effects are not rolled back. Publication does not guarantee continued
liveness. If interruption or transport loss prevents acknowledgement, the
remote outcome can remain unknown. Termination is best effort and no new
activation handshake, cancellation guarantee, implicit ongoing monitor, or
wire fields are introduced.
Ordinary `register/2` checks local actor existence under the same registry
mutex as insertion and retirement. After the existing collision checks, a
missing local actor raises `error(existence_error(process, Pid), Context)`.
This includes local URL-qualified pids and their accepted textual forms;
`main` remains supported. Registration before retirement is removed by cleanup;
registration after retirement is rejected. Success does not guarantee continued
liveness. Remote registration remains unchecked and installs no implicit monitor.
When an existing transport observes a remote `down`, ordinary aliases for that
exact pid are withdrawn across local namespaces, including when the event is
buffered during startup. On observed connection loss, aliases for all pids on
that node are withdrawn, including unmonitored aliases. This withdraws local
names without establishing remote actor death. Cleanup shares the registry
mutex with registration and precedes monitor notifications, using registry
before monitor lifecycle lock order. Termination cleanup preserves other
pids; connection-loss cleanup preserves other nodes. A name reused for another
pid survives old termination events. Names for local actors are unaffected.
Within an open namespace, no remote retirement records prevent later
registration from recreating an alias. Without an observed event, clients must explicitly unregister aliases.

Managed client namespace teardown closes admission, removes ordinary names,
and cancels pending named-startup reservations under the registry mutex.
Late `register/2`, name reservation, and name publication raise
`error(permission_error(register, closed_namespace, Namespace), Context)`.
A surviving actor cannot repopulate a closed namespace. This operation does
not terminate running actors or change service registrations; existing
lifetime and ownership policies continue to apply. A pending named startup
whose publication is rejected follows normal startup failure handling.
Teardown also disposes of this node-scoped namespace's local promises, as
described under Remote Queries below.

A WebSocket connection owns its shared `ws_client/1` namespace, closed on
disconnect. Ending one toplevel leaves that namespace open. An HTTP interactive
session owns its `isotope_session/1` namespace, closed on actual session
cleanup or local session-actor retirement (including early exit). Replacing
session bookkeeping or returning from a request context leaves it open.
Delegated `ws_lineage/2` namespaces close on explicit lineage closure or
connection teardown; later commands cannot reopen a closed lineage. Other
lineages and namespaces are unaffected. The standalone global namespace
remains available.

Runtime composition uses `node_execution_context`'s namespace/connection
open and close helpers, with `actors:hook_registry_namespace_status/2`
checking admission and `actors:hook_registry_retire/1` running inside local
registry retirement. Only open namespace/connection records are retained;
closed lineage markers are discarded when their connection ends. Ordinary
request context entry never opens a namespace. These helpers are internal
runtime operations, not public client predicates.
Implicit monitoring, automatic expiry, distributed cancellation, and broader
lifecycle work remain separate.

### Owner Service Publication

An ACTOR implementation provides the owner-only administrative predicates
`register_service/2` and `unregister_service/1`. They are not part of the
ordinary client goal surface. The runtime also retains `whereis_service/2` as
an internal owner/bootstrap helper; it is not a standard client predicate.

Clients address a published service as `Name@Node`. Publication and
advertisement are distinct: `register_service/2` makes the address live, while
an owner-maintained relation such as `service/2` may advertise all published
services or only a selected subset. Sending to an absent qualified service is
a silent no-op, so the send operation cannot be used to enumerate a node's
published namespace. A local send to an absent ordinary registered name keeps
its documented `existence_error(actor_name, Name)` behavior.

### Private Database Loading

`src_text/1`, `src_list/1`, `src_predicates/1`, `src_uri/1`, `listing/0`.

`src_uri/1` remains a broad source-loading option in unrestricted setups, but
the runtime now supports per-node exact-origin allowlists through
`load_uri_allowed_origins([...])`. When that allowlist is configured, bare
local paths, `file://` URIs, and arbitrary HTTP(S) origins are rejected, while
node-relative URIs continue to work only if they resolve to an allowed origin.

Local browser server/supervisor startup marks the internally supplied behavior
block while loading it into a Worker. Only the resulting weak-import warnings
for actor-bridge definitions are suppressed. Genuine user overrides before or
after that block, redefinitions, syntax errors, and other diagnostics remain
visible. Suppression is scoped to the active load and cleared on every exit,
including incomplete or interrupted loads. Definitions, module placement,
source order, and remote source delivery are unchanged.

### Actor I/O

`output/1`, `output/2`, `input/2`, `input/3`, `respond/2`.

### Toplevel Sessions

`toplevel_spawn/1`, `toplevel_spawn/2`, `toplevel_call/2`,
`toplevel_call/3`, `toplevel_next/1`, `toplevel_next/2`,
`toplevel_stop/1`, `toplevel_abort/1`, `toplevel_halt/1-2`.

Native synchronous wrappers are exported by `toplevel_actors` (and the
`web_prolog` umbrella): `toplevel_call_synch/3-4` and
`toplevel_next_synch/2-3`. They send one command and collect one protocol answer
from the caller's mailbox. Pass the toplevel's concrete pid. Logical failure
and query exceptions return `failure(Pid)` and `error(Pid,Error)` terms.
Goal variables remain independent in the caller. I/O and unrelated messages
are not selected.

Every synchronous command supplies `target(Self)`, where `self(Self)` names
the waiting caller, overriding creation-time or retained query targets.
Every explicit `target(Target)` must satisfy `Target == Self`: an unbound
target raises an instantiation error and a conflicting target (including an
alias) raises `error(domain_error(synchronous_toplevel_target,Target),_)`.
All routing and option checks run before a query starts or advances.
Asynchronous routing semantics are unchanged.

Call query options are `template/1`, `offset/1` (nonnegative integer),
`limit/1` (positive integer), `once/1` (boolean), and native `io_target/1`
(a separate I/O destination). Next query options are `limit/1`.
Both wrappers accept local receive options `timeout(Number)` and
`on_timeout(Callable)`. Query options are sent only to the toplevel;
receive options stay in the local wait. Unknown names/arities and misplaced
options raise `domain_error(toplevel_call_synch_option,Option)` or
`domain_error(toplevel_next_synch_option,Option)` inside `error/2`.
Malformed lists/values raise type, domain, or instantiation errors with the
public predicate in the context. Repeated query/receive settings use their
first occurrence; templates and callbacks retain variable sharing.

The short forms supply `[]`; the default wait has no timeout. A timeout
callback runs once in its caller's context with bindings retained; callback
failure makes the wrapper fail and exceptions propagate. Without a callback,
a timeout succeeds leaving `Answer` unbound, matching `receive/2` rather than
`yield/3`'s default `timeout` result. A timeout does not stop the query. Each call or next has a fresh private
request reference, carried by its answer. A later synchronous wait on the
same pid discards obsolete tagged replies it encounters and accepts only
its own reference; skipping stale replies does not restart the wait deadline.
Ordinary asynchronous answers and I/O remain available. A pre-instantiated answer mismatch consumes the
selected answer and fails. Each wrapper installs a private monitor before
sending and throws `toplevel_down(Reason)` if it observes termination instead
of an answer. The monitor is removed with `demonitor(Ref, [flush])` on every
exit path, including send exceptions, timeout callbacks, and answer mismatch.
Existing monitors and unrelated messages are preserved. Remote reasons may
include `connection_closed`, which reports lost observation rather than proven
death. Query exceptions still return `error(Pid, Error)` answer terms.
Public-node callbacks cross the usual sandbox boundary. These wrappers remain single-client operations; request correlation does
not coordinate concurrent callers or change the PTCP rules for advancing
or replacing a query.

Remote synchronous requests require the WebSocket subprotocol
`web-prolog-sync-v1` on the actual connection. An unsupported peer raises
`error(permission_error(use,toplevel_correlation,Node),_)` before the query
is sent, even with `timeout(0)`. The receive timeout still starts after
sending; it does not bound connection setup. Older peers remain usable for
asynchronous operations. Synchronous return terms are unchanged; the private
reply envelope is removed by the wrapper.

Both SWI-WASM runtimes also export `toplevel_call_synch/3-4` and
`toplevel_next_synch/2-3` for concrete local toplevel pids (an integer or
`Integer@localhost`) and concrete remote `Integer@Node` pids with an atom node
URI. Aliases and experimental legacy pid forms remain outside this interface.
Remote waits require `web-prolog-sync-v1` on the actual WebSocket. Unsupported
peers raise `error(permission_error(use,toplevel_correlation,Node),_)` before
starting or advancing a query, including with `timeout(0)`. The capability is
checked before monitoring and again on the socket used to send the command.
Connection setup is outside the receive timeout.

The browser offers the existing native subprotocol when connecting. If that
upgrade fails before opening, it retries the legacy connection without a
subprotocol for asynchronous compatibility; such a connection cannot execute
synchronous requests. Asynchronous routing and paging are unchanged; negotiated answer fidelity is described below.
Synchronous commands use the actor-term transport with the waiting engine as
answer target. The complete tagged Prolog answer returns to that same engine,
preserving nonground sharing and exception terms without display-text reconstruction.
Timeout does not cancel remote computation; a later synchronous wait for the same
pid discards stale tagged answers while preserving asynchronous answers and I/O.
Cancellation, concurrent-client coordination, aliases and browser `io_target/1`
support remain separate work.

Both SWI-WASM runtimes request `answer_terms:true` in the existing browser
transport hello. Supporting nodes acknowledge `answer_terms:true` and enable the
existing canonical `term` field for queue-targeted successes and query errors.
For negotiated peers, main-engine asynchronous calls request the existing
`format(prolog)` so the supplied template is retained rather than replaced by
a display bindings dictionary. Worker actor-term calls already retain it.
The receiving engine parses the whole solution list or exception term once,
preserving shared and distinct variables, quoted atoms, strings and literal
`'$VAR'/1` terms. Public asynchronous answers remain `success(Pid,Slice,More)`,
`failure(Pid)` and `error(Pid,Error)`. Actor-message replies already carry complete
terms and are unchanged. I/O, monitor delivery, synchronous correlation and
connection ownership are unchanged; no new waits or cancellation are added.

Without an acknowledgement, the browser retains its legacy display-field
reconstruction and `remote_error(Text)` exception fallback, with their existing
fidelity limitations. Once canonical answers are negotiated, a missing/nontext
payload returns `error(Pid,remote_answer_protocol_error(missing_term))`; an
unparseable payload or a non-list success payload returns
`error(Pid,remote_answer_protocol_error(invalid_term))`. These are ordinary
mailbox answers, rather than silent fallback or an indefinitely pending reply.
The existing portable wire-term subset still applies.

Browser call query options are `template/1`, `offset/1`, `limit/1` and `once/1`;
next accepts `limit/1`. Both accept `timeout/1`, `on_timeout/1` and a `target/1`
identical to the waiting caller. Every option occurrence is validated before
sending; first occurrence wins, and templates/callbacks retain variable sharing.
Lists, values and conflicting targets follow the native validation rules above.
Browser `io_target/1` is not supported by these wrappers and raises the appropriate
synchronous option domain error. Goal variables remain independent in the caller.

Each command supplies the caller as answer target and a fresh private request
reference. Replies, including partial-page deferred errors and execution-time-limit
errors, retain correlation until the wrapper removes the private envelope.
A synchronous wait discards obsolete tagged answers for that same concrete pid;
it preserves ordinary asynchronous answers, I/O and other actors' messages.
Discarding stale answers does not restart a positive wait deadline. An ordinary
asynchronous call or next clears correlation for its own answer.

The default wait is unbounded. A receive timeout without callback succeeds with
`Answer` unbound; a callback runs once in its caller's context, preserving its
bindings, failure and exception. Timeout does not stop the query. Query failure
and exceptions remain `failure(Pid)` and `error(Pid,Error)` answer terms, while
observed termination throws `toplevel_down(Reason)`. Payload selection precedes
output unification, so a mismatch consumes its answer and fails. A fresh private
monitor is installed before sending and is withdrawn and flushed on success,
failure, mismatch, exception, interruption or cut, using non-awaiting browser
cleanup. Existing explicit monitors remain available. These wrappers add no
multi-client coordination, automatic cancellation or ownership transfer.

### Remote Queries

`rpc/2`, `rpc/3`, `promise/3`, `promise/4`, `yield/2`, `yield/3`,
`runtime_property/1`.

All runtimes accept the same `rpc/3` transport options: `limit/1`, `once/1`,
`timeout/1`, and `http_timeout/1`, together with the `src_*` source options.
`promise/4` accepts these plus `template/1` and `offset/1`; offset selects the
single slice collected by the promise and is not a public `rpc/3` option.

Paging offsets count answers actually returned, rather than requested page
capacity. After `success(Slice,true)`, the native RPC client requests
`Offset + length(Slice)`, and the native node stores its continuation at that
same offset. A partial page can retain a continuation: for example, answers
found before an exception are returned first, and the pending exception is
collected on the next request. Correct offsets let that request resume the
cached actor without re-executing the query. This rule applies to nonzero
offsets and when the next request changes its limit. Full pages, final pages,
and `once(true)` retain their existing behaviour. Client and server must both
follow the actual-count rule for partial-page cache reuse; no wire fields
change.

Each native `/call` request owns its newly created or checked-out toplevel
until it publishes a continuation back to the cache. Failure, exceptions,
and interruption reclaim an actor still owned by the request and destroy its
reply queue. Acquisition and cache publication (including expiry setup) are
protected against interruption; the query wait remains interruptible. A
completed publication transfers ownership to the cache, so interruption
before sending the HTTP response does not destroy that continuation.
Terminal replies retain the one-shot actor's normal exit; `once(true)` still
stops further enumeration. Timeouts still return
`error(error(resource_error(time),_))` and terminate the active computation.
As on timeout, termination is requested asynchronously; cleanup does not wait
for an actor shutdown acknowledgement. It installs no monitors and leaves
unrelated monitor messages untouched.

This cleanup applies when the server request exits; it does not add immediate
client-disconnect detection or remote cancellation. Cutting an RPC enumeration
after receiving a page still leaves a published continuation subject to the
existing cache expiry and eviction policy.

The native client validates the complete option list at entry, before URI
resolution/source fetching in `rpc/3` and `promise/4`, or waiting/collection
in `yield/3`. Options must be unary terms in a proper list. Unknown names,
wrong arities, and options belonging to another operation raise
`error(domain_error(rpc_option, Option), _)`, `promise_option`, or
`yield_option`, respectively. Invalid values raise type, domain, or
instantiation errors with the public predicate in the context. Every supplied
option is validated, even if a later duplicate would otherwise be ignored.

Both SWI-WASM clients now perform the same entry checks for their supported
subset. `rpc/3` accepts `limit/1`, `once/1`, `timeout/1`, `http_timeout/1`, and
`src_text/1`, `src_list/1`, `src_uri/1`, `src_predicates/1`; `promise/4` adds
`template/1` and `offset/1`. `yield/3` accepts only `timeout/1` and
`on_timeout/1`. Unknown names, wrong arities and cross-operation options raise
the corresponding `rpc_option`, `promise_option`, or `yield_option` domain
error. Values are checked without copying or binding template/callback
variables. Offset is nonnegative, limit is positive, source text/URIs are
atoms or strings, and predicate indicators have atom names and nonnegative
integer arities. This enforces the documented browser text forms; it does not
migrate experimental character-list representations or change source conversion.

Every duplicate is validated before any work begins; first-occurrence
precedence and repeated source loading remain unchanged. Numeric execution
and HTTP timeouts retain their existing clamping of negative values to zero.
The worker's explicit `none` sentinel remains accepted for those two timeouts;
the main-engine compatibility runtime still requires explicit numbers.
Negative yield timeouts retain their existing wait behavior. Invalid yield
options neither start a wait nor consume a pending/ready promise or execute
a timeout callback. An explicitly module-qualified callback retains its
caller and sharing with the answer variable.

Browser `rpc/3` and `promise/4` reject `request_header/1`, `authorization/1`,
and `user_agent/1`; those native options are outside the current browser
transport subset. No transport, wrapper or ownership extension is implied.

Native `rpc/3` and `promise/4` support this HTTP subset in addition to
`http_timeout/1`:

- `request_header(Name=Value)`: atom name and atom/string value; may be repeated.
- `authorization(basic(User,Password))` or `authorization(bearer(Token))`:
  atom/string arguments.
- `user_agent(Agent)`: atom/string value.

These options apply to requests to the execution node, including later RPC
slices; they do not configure `src_uri/1` fetching. Other SWI HTTP options are
rejected rather than forwarded. Query/source options never reach `http_open/3`;
`http_timeout/1` is translated to the host transport's `timeout/1`.
Repeated source options retain their order. Query settings use the first
occurrence; templates retain variable sharing with the goal and offsets must
be nonnegative integers. Existing timeout conventions remain: negative
execution/HTTP timeouts become zero; an execution timeout of `none` or an
unbound value is unspecified. Native source text continues to accept
atom/string/codes/chars representations; this does not settle the portable
text contract.

Native `yield/3` accepts only `timeout(Number)` and `on_timeout(Callable)`;
the first occurrence of each takes effect. A negative wait timeout returns
immediately if no answer is available. Validation never runs the callback
or consumes the promise. Actor spawning and the specialised creation wrappers
also validate options; native synchronous toplevel wrappers enforce caller
routing as described above. Validation of other option-bearing APIs remains
separate work.

Promise references are opaque ten-digit integers, minted securely and never reused.
Native `yield/3` returns `timeout` when its wait expires and retains the promise
for retry. An `on_timeout/1` callback runs once in the caller's context; its
binding of the answer is retained, or `timeout` is supplied if the answer is
still unbound. A failing callback throws `error(timeout_callback_failed(Ref), _)`.
Both yield variants throw `error(existence_error(promise, Ref), _)` for an
unknown, consumed, or expired reference. Native promise workers deliver request,
transport, parsing, and invalid-response failures as `error(Error)` answers.
Native promises retain an unconsumed answer for 300 seconds from creation.
One active collector is allowed per reference; a competing yield raises
`error(permission_error(collect, promise, Ref), Context)`. This claim is released
on timeout or interruption, before running the timeout callback. Callback
failure/exception does not consume the promise; a retry remains possible
unless another collector or disposal has since won.

Completion, collection, expiry and explicit `promise_cleanup/1` serialize under
a lifecycle mutex. Answers stay in the record until collection commits, so
interrupting a collector after wakeup does not lose the answer. Successful
collection consumes the reference and destroys its wake queue. Expiry or
explicit cleanup invalidates it and wakes an already waiting collector with
`existence_error(promise, Ref)`; an unavailable promise does not invoke its
timeout callback. The mutex determines whether collection or disposal wins.

Disposal also stops the local expiry task and interrupts an unfinished local
HTTP worker, whose stream cleanup runs as it unwinds. A thread not yet activated
observes disposal and exits without starting the request. Detached threads
release their resources as they exit; disposal does not wait for the remote
node. Late worker completion is ignored without writing to a destroyed queue.
Failed initialisation rolls back allocated local resources. Explicit cleanup
remains idempotent. This is local disposal, not guaranteed remote cancellation.

Native node composition records a ground owner key with each promise and
checks it under the lifecycle mutex before a collector claims the promise:

- WebSocket, HTTP interactive-session and delegated transport calls use their
  existing client namespace, scoped to the node. Sharing a principal does not
  merge separate session namespaces.
- Authenticated stateless HTTP calls use principal identity scoped to the node,
  allowing collection in a later request by that principal.
- Anonymous stateless HTTP calls use the existing distinct request identity,
  including when an anonymous per-IP identity is configured. A later anonymous
  request cannot collect; use a session or authentication across requests.
- Trusted local/standalone code retains sharing across threads and actors.
  It has no implicit override for public clients' promises, and public clients
  cannot collect trusted local promises.

A foreign yield raises the same `existence_error(promise, Ref)` as an unknown
reference, without invoking its callback or exposing an active collector.
Foreign `promise_cleanup/1` is an idempotent no-op, just as for an absent
reference. Authorised cleanup works normally; internal expiry can dispose of
any expired promise independently of client identity. Public execution without
a usable client identity fails closed at promise creation.

Composition uses `rpc:hook_promise_owner/1`; the independent RPC library defaults
to trusted local sharing. Ownership is unchanged by timeout, interruption or
retry. Definitive teardown of a WebSocket, HTTP interactive-session, or
delegated-lineage namespace now disposes of its promises on that node. Closing
a connection also sweeps every delegated namespace belonging to it. Ordinary
request completion, bookkeeping replacement, and termination of one toplevel
in an open shared WebSocket namespace do not trigger this disposal.

Surviving actors remain alive, but their old references become unavailable,
and creation under the closed namespace raises
`error(permission_error(create,promise,closed_namespace(Namespace)), Context)`.
Waiting collectors receive `existence_error(promise, Ref)` without running
their timeout callback. Collection and teardown serialize: a collection that
commits first returns its answer; disposal that wins invalidates the reference.
Creation checks admission under the promise lifecycle mutex; teardown closes
admission before acquiring that mutex to sweep, so an already admitted
creation cannot escape disposal. The lock order is registry before promise;
promise creation does not acquire the registry mutex. Repeated teardown is
idempotent. Local workers and expiry tasks are stopped using the existing
disposal path, without waiting for remote execution to finish.

Authenticated and anonymous stateless HTTP owners and trusted local sharing
retain their existing lifetimes; other namespaces and node scopes are
unaffected. Runtime composition uses `rpc:hook_check_promise_owner/1` and the
namespace/connection close hooks; `rpc:dispose_promises_for_owner/1` is an
internal teardown helper, not a public client predicate. Ownership transfer,
remote cancellation, and a portable ownership contract remain separate work.

In SWI-WASM, a promise belongs to the engine that created it. Each Worker has
its own store; the compatibility main engine has one store shared across its
successive queries. Spawned actors have separate Worker stores, including actors
spawned from the main engine. Later queries in the same surviving engine may
collect or dispose of its promises, subject to collection and expiry rules.

A numeric reference is meaningful only in that engine. Sending it to another
actor does not transfer access: yield and cleanup consult the receiving engine's
store. If no local record exists, yield raises `existence_error(promise,Ref)` and
cleanup is a no-op. Reference numbers are not globally unique; a coincident
number denotes only the receiving engine's own record. Collection or disposal
cannot affect the other engine's record or transport resources. These store
boundaries do not constitute a security sandbox against trusted JavaScript with
access to the main engine's page. Native client-owner identities are not imposed
on browser engines. Isolation regressions exercise the real main and Worker
bridges in separate JavaScript contexts, including forced equal references.

Both SWI-WASM runtimes use the same local promise lifecycle store implementation.
A reference expires 300 seconds after creation, whether its request is pending or
its answer is ready. A timer performs expiry, and every collection operation
also checks the deadline so delayed background timers do not extend validity.
Only one collector may claim a reference; another yield raises
`permission_error(collect,promise,Ref)`. The answer remains stored until the
waiting Prolog computation resumes and commits collection. Timeout, interruption
or an exception before commit releases the claim without consuming the answer.
The timeout callback runs after release, preserving retry, callback bindings,
and callback failure/exception behavior. An output mismatch after collection
still consumes the selected answer, as before.

Browser `promise_cleanup/1` requires an integer reference and is idempotent,
including for unknown, consumed or expired references. Collection and disposal
remove records and expiry timers. Disposal wakes an existing collector with
`existence_error(promise,Ref)`, without invoking its timeout callback; it also
clears wait timers and interrupts pending local fetch/request resources. Worker
fetch handles are scoped to their existing Worker entry, and reaping that Worker
releases those handles. Completion after disposal cannot recreate a record.
Uncollected large answers and timed-out wait callbacks are not retained beyond
their necessary lifetime. Small reference non-reuse bookkeeping remains.

These are local resource rules: aborting an HTTP fetch does not establish that
remote execution stopped. Engine ownership preserves existing reference
visibility/sharing boundaries. Ownership transfer, native-style client namespace
teardown and guaranteed remote cancellation remain separate work. A cooperative
wait interruption keeps the promise available in its existing engine; destroying/replacing a Worker also
destroys that engine's local references. Lifecycle regressions use shortened,
controlled deadlines; UI checks exercise public retry/callback/disposal behavior.

`runtime_property/1` reports host capabilities rather than changing language
semantics. Its properties are `implementation/1`, `persistent/1`,
`inbound_addressable/1`, `dom/1`, `actor_isolation/1`, and
`hard_termination/1`.

Actor application messages use the portable wire-term subset: acyclic ordinary
Prolog terms without attributed variables, streams, or other non-text blob
values. Plain variables are copied as fresh variables. Serialization boundaries
enforce the subset; accepting extra host terms on a native local-only path is
an implementation extension and is not placement-independent.

### Generic Servers

`server_spawn/3`, `server_spawn/4`, `server_request/3`,
`server_request/4`, `server_promise/3`, `server_promise/4`,
`server_yield/2`, `server_yield/3`, `server_yield/4`,
`server_upgrade/2`, `server_halt/2`.

`server_promise/4` installs its monitor before request setup and sending.
If reference creation or sending raises an exception, it removes that monitor
with `demonitor(MonRef, [flush])` and rethrows the original exception. Unrelated
monitors and mailbox messages are preserved. On success, the returned monitor
remains available for `server_yield/4`, which performs the normal cleanup.
Abandonment after a successful send and a live server that never replies remain
separate lifecycle concerns.

`server_yield/2-3` selects the reply for `Ref` using a fresh payload variable,
then unifies that payload with `Response`. Compatible instantiated outputs
and nonground replies use ordinary unification, preserving payload variable
sharing. A conflicting output consumes the reply and fails immediately; it
does not leave the reply deferred or invoke the timeout callback. Unrelated
references and messages remain available. The monitored `server_yield/4`
already uses this selection-before-unification rule. Existing reference
handling and timeout/callback behaviour are unchanged.

In both SWI-WASM runtimes, monitored server setup and waits use an internal
cleanup path that does not await JavaScript promises during Prolog unwinding.
`server_promise/4` allocates its monitor reference before the protected
installation/setup/send operation, so failure or an exception can still
withdraw it after bindings in that operation unwind. The original outcome is
preserved, including when remote cleanup fails. Successful setup retains the
monitor for `server_yield/4`.

The monitored wait removes its monitor on success, output mismatch, failure,
exception, interruption, and cut. Timeout callbacks retain their alternatives;
cleanup runs when those alternatives finish or are discarded. Cleanup flushes
matching deferred notifications and filters queued notifications until an
internal coordinator barrier confirms local removal. Unrelated references and
messages remain available. A pending remote installation cannot recreate a
withdrawn monitor; a late remote down with an explicit reference cannot consume
a different monitor on the same actor. Remote withdrawal remains best effort.
This work does not cancel server computations, correlate late server replies,
or change the lifecycle of an abandoned successful `server_promise/4`.

### Supervisors

`supervisor_spawn/2`, `supervisor_spawn/3`,
`supervisor_spawn_child/3`, `supervisor_terminate_child/3`,
`supervisor_delete_child/3`, `supervisor_respawn_child/3`,
`supervisor_which_children/2`, `supervisor_count_children/2`,
`supervisor_halt/1`.

Native supervisors validate the complete initial child list before creating
the supervisor or starting children. `supervisor_spawn_child/3` reuses the
single-child validator before contacting the supervisor. Nested supervisors
use the same list validator.

- Child and option lists must be proper, and each specification an acyclic
  `child(Id,Options)` term. Ids must be ground; ordinary children retain
  support for compound ids. Server-child ids must be atoms because they
  also become registered names.
- Duplicate initial ids raise
  `error(permission_error(duplicate,supervisor_child_id,Id),_)`, within each
  supervisor's own list. A valid dynamic addition whose id is already present
  still returns `error(already_present)`.
- Only unary `start/1`, `restart/1`, `shutdown/1`, and `type/1` options are
  accepted. Unknown names/arities raise
  `error(domain_error(supervisor_child_option,Option),_)`. Missing `start/1`
  retains `error(missing_start_option(Id),supervisor)`.
- Restart policies are `permanent`, `transient`, or `temporary`; types are
  `worker` or `supervisor`. Shutdown is `brutal_kill`, `infinity`, or a
  nonnegative numeric timeout, including zero and fractional seconds.
- Start goals must be callable and supplied module qualifiers atoms. For
  the recognised `server(Pred,ServerOptions)` form, the callback must also
  be callable; server/spawn options are validated, with `initial_state/1`
  accepted as arbitrary state data. Direct `start_sub_supervisor/2` forms,
  unqualified or explicitly qualified by `supervisor_actor`, recursively
  validate their child lists and supervisor options. Module-qualified child
  lists retain their source-module semantics.

Malformed structures/values raise type, domain, or instantiation errors;
cyclic specifications raise `error(representation_error(cyclic_term),_)`.
Every option occurrence is checked, but the first still determines its
effective value. Defaults and variable sharing within goals/states are
preserved, and validation does not bind input variables. Other callable start
goals remain runtime code: validation does not execute them, fetch source,
check predicate availability, reserve names, or guarantee startup success.
Monitor installation, shutdown, and other lifecycle behavior are unchanged.

Both SWI-WASM runtimes also validate the complete initial child list before
source preparation or supervisor creation, including recognised nested server
and supervisor starts. `supervisor_spawn_child/3` validates before sending;
its validation errors identify that predicate (initial errors identify
`supervisor_spawn/3`). The receiver rechecks dynamic additions: malformed
requests return `error(Error)` without changing supervisor state, and an
already-present id returns `error(already_present)` without starting a child.

Browser child lists and option lists must be proper and specifications acyclic
`child(Id,Options)` terms. All browser child ids must be atoms, since each is
passed as a name. Initial sibling ids must be unique (the same id can occur
under a different nested supervisor); duplicates raise
`permission_error(duplicate,supervisor_child_id,Id)`. A missing `start/1` raises
`missing_start_option(Id)`. Every option occurrence is checked, including
unused duplicates. Start goals and server callbacks must be callable, with
atom module qualifiers; goal arguments and arbitrary server states can retain
shared variables. Recognised `server(Pred,ServerOptions)` and
`start_sub_supervisor(Specs,SupOptions)` forms validate their nested options and
specifications before any startup. Other goals are not executed or checked for
predicate availability during validation.

Browser child options accept the same restart policies, types and shutdown
values listed above, plus boolean `significant/1` compatibility metadata and
forwarded browser spawn settings. Nested server/supervisor settings use their
existing wrapper schemas, including URI source loading in both runtimes.
Unknown names and wrong arities raise `domain_error(spawn_option,Option)`.
Defaults, first-occurrence precedence, option order, source sharing and the
original specifications saved for restarts are preserved without copying or
binding input variables. Nested server/supervisor options still precede the
generated child name and child-level spawn settings.

In both SWI-WASM runtimes, `transient` children restart only when their exit
reason differs from `true`: failure (`false`), exceptions, and explicit abnormal
exit reasons trigger a restart, subject to the existing intensity limit.
Successful completion (`true`) does not. `permanent` children restart for any
reason; `temporary` children never restart. Regression tests exercise the shared
supervisor down handler and replacement startup in each bundled WASM engine.
Browser ordering, bookkeeping and shutdown are described below.

Both browser runtimes retain children in their original start order. Automatic
`one_for_one` restart replaces a record in place; `one_for_all` restarts the
whole list in that order; `rest_for_one` restarts only the failed child and
later siblings, preserving earlier records and pids. The failed child's old
pid is marked inactive before the strategy runs; later notifications for
replaced pids are ignored. New dynamic children append to the list.

A normally completed transient child retains its original specification with
`Pid = undefined`; temporary children are removed on termination. Explicit
termination retains a stopped record in place and succeeds without another
exit signal if already stopped. Deletion and explicit respawn reject a running
child with `error(running)`; deletion removes an inactive record, and respawn
replaces it in place. Missing ids retain `error(not_found)`. Stopping children
skips inactive pids. Automatic restart failure handling is described below.

In both browser runtimes, exhausting the restart intensity budget marks the
triggering child inactive, starts no replacements, and shuts down the remaining
recorded children in reverse start order before exiting with reason `shutdown`.
This applies to all three strategies and includes detached children
(`link(false)`). Existing period pruning, counting and threshold rules are
unchanged: zero intensity permits no restart, and only qualifying restart events
count. Cleanup uses the existing child shutdown policies and private monitor
cleanup. An exception or failure during one child's cleanup does not replace the
intended exit reason or prevent attempts for other children; termination of that
child is then not guaranteed. Unrelated actors, messages and explicit monitors
are preserved. `infinity` can delay the supervisor's exit; forced Worker and
remote-observation qualifications still apply. This does not add cleanup for
arbitrary supervisor exits or recursive cooperative shutdown.

Browser reply formats are unchanged: successful dynamic start, termination,
deletion and respawn return `ok` (browser respawn does not return `ok(NewPid)`).
`supervisor_which_children/2` returns ordered `child(Id,Pid,OriginalSpec)` terms,
including inactive records. `supervisor_count_children/2` returns
`counts(Total,Active)`, counting stored specifications and records whose pid is
not `undefined`, respectively. These reflect the supervisor's processed state,
not an independent instantaneous liveness check. The native inspection formats
remain `info(Id,Pid,Type,Restart)` and the keyed counts list.

Both SWI-WASM runtimes use one child-shutdown helper for explicit termination,
normal supervisor halt and the stopping phases of `one_for_all`/`rest_for_one`.
It installs a fresh private monitor before sending a stop or exit request, and
waits for that monitor's down notification before recording the child inactive
or starting replacements. Already inactive records need no shutdown action.
Normal supervisor halt stops children in reverse start order; group restart
stopping order and replacement start order are preserved.

`shutdown(brutal_kill)` terminates immediately with reason `kill`. For a
recognised `start(server(Pred,Options))`, numeric shutdown sends a private tagged
server-stop request, waits up to that many seconds for termination, then forces
termination with reason `shutdown` if necessary. Zero and fractional timeouts
are supported. `infinity` sends the same stop request and waits without an
internal deadline. Omitted shutdown defaults to 5 seconds for `type(worker)`
(the default type), or `infinity` for `type(supervisor)`. Ordinary actors and
nested supervisors retain direct termination with reason `shutdown`, followed
by the private wait; this does not add recursive cooperative supervisor stop.
The existing public untagged server-stop protocol and all public reply formats
are unchanged. Only the private monitor notification establishes completion;
the tagged acknowledgement alone does not.

Cleanup withdraws and flushes the private monitor and its tagged stop reply on
success, exception, interruption or cut. Existing monitors, application messages,
public stop replies and pending request replies remain available. Cleanup uses
the existing local monitor barrier without awaiting transport. An interrupted
wait does not introduce a new forced-termination policy for the child.

Browser supervisor requests for addition, termination, deletion, respawn,
inspection and halt install a fresh private monitor before sending. They select a reply
into a fresh variable before unifying the caller's output: a mismatch consumes
the selected reply and fails. Successful reply formats are unchanged. Observed
termination raises `supervisor_down(Reason)`; expiration of the existing
10-second reply wait raises `supervisor_call_timeout(Sup,Request)`. That wait
starts after sending and does not bound connection setup or cancel the requested
operation. A late reply is not cancelled or collected by this repair.

Cleanup removes and flushes only the private monitor on success, mismatch,
failure, exception, interruption or cut, using the existing non-awaiting browser
cleanup path. Application messages and unrelated explicit monitors remain
available. Remote `connection_closed` reports loss of observation, not proven
remote death. These request waits are separate from internal child shutdown
deadlines; a caller's timed-out wait does not cancel shutdown in the supervisor.
`supervisor_halt/1` (and `supervisor_stop/1`) uses a tagged stop request and
succeeds after child shutdown. Its ten-second wait can raise
`supervisor_call_timeout(Sup,stop)` without cancelling shutdown; several child
deadlines or `shutdown(infinity)` can exceed that caller wait. Observing the
supervisor's own termination still requires a separate monitor. Legacy direct
`'$sup_stop'(From)` requests retain their `reply(true)` acknowledgement.
Forced Worker termination does not promise
execution of Prolog cleanup handlers. Remote down reasons can report connection
loss rather than proven death. Automatic supervisor-exit cleanup, recursive
graceful shutdown and stronger remote guarantees remain separate. `significant/1` remains compatibility metadata; `type/1` selects the
shutdown default without adding other type-specific lifecycle behaviour.

Browser explicit respawn also uses a startup journal: a failed replacement is
rolled back, its inactive specification stays in place, and the supervisor
returns `error(start_failed)` for failure or `error(Error)` for an exception.
Success retains the browser `ok` reply. The caller can retry the inactive child.

Automatic replacement starts for one restart event share a startup journal.
If a replacement fails, newly created actors and monitors are rolled back,
then the remaining recorded children are shut down in reverse order using their
shutdown policies. The supervisor exits with `restart_failed(Id,Reason)`, naming
the replacement whose startup failed; no partial group is kept running and no
additional retry loop is introduced. Cleanup errors must not replace that
original reason. Unrelated actors and explicit monitors remain untouched.
An `infinity` shutdown policy can delay this failure exit, and existing remote
termination qualifications still apply. Initial readiness reporting ends before
the running loop begins, so a restart error does not send a second startup-failure
notification to the original creator. General supervisor exit handling remains separate.

Initial browser supervisor startup and dynamic child additions now use temporary
startup journals. Local reservations and actors are recorded before Worker
construction/readiness and monitor setup. An outer attempt also tracks actors
created by nested supervisors while that attempt is open, including detached
children (`link(false)`). Success commits the attempt without changing links or
actor lifetimes. On failure, exception or unwinding, rollback rejects late local
startup of retired reservations, stops the attempt's actors in reverse creation
order, and withdraws its monitors. Existing actors and unrelated explicit monitors
are preserved. Cleanup runs without awaiting transport and must not replace the
original startup error. Small retired-reservation markers prevent late reuse.

Initial child errors still reach the caller as
`error(supervisor_start_failed(Pid,Reason),supervisor_spawn/3)`; the existing
readiness timeout is unchanged and also rolls back the caller's attempt.
Dynamic startup failure returns `error(start_failed)`, and an exception returns
`error(Error)`, keeping the previous supervisor state and allowing that id to be
tried again. Existing more specific child-start errors are preserved. Prolog
exception terms are retained; JavaScript exception objects, which cannot cross
mailboxes as blobs, are reported as
`error(supervisor_startup_error(Message),supervisor_spawn/3)` with the original
message. Successful additions still append and return `ok`.

This rollback covers startup, not later failure of a successfully running child;
it does not establish application-level readiness. Known remote pids receive
best-effort exit requests. A connection failure before a remote pid is returned
can leave the remote outcome unknown. Startup rollback remains a separate,
immediate cleanup path from the orderly child shutdown described above.
Broader lifecycle work remains separate.
Regression tests exercise both bundled runtimes with real Worker/coordinator
paths and controlled startup faults; UI checks exercise initial and dynamic
publication failures and subsequent successful additions.

### Statechart Actors

`statechart_spawn/2`,
`statechart_halt/2`, `statechart_halt/3`, `raise/1`, `in/1`.

Within SXML, `<defer on="Pattern" if="Guard"/>` postpones a matching event
only when no transition is enabled for that event. Postponed events are
re-offered oldest first on the internal event queue after a macrostep changes
the active configuration. Enabled transitions take precedence; a re-offered
event may be postponed again.

Before a statechart model is constructed, its XML is validated against the
SXML 0.2 DTD in `prolog/web_prolog/sxml-0.2.dtd`. The parser supplies the DTD,
so documents do not need a `DOCTYPE` declaration; a running node also serves
the distributable grammar at `/sxml-0.2.dtd`. A following semantic pass
checks identifier uniqueness, reference existence, and direct-child initial
states; Prolog terms, transition combinations, delays, and `<spawn>` contracts
are checked by the model parser.

### Parallel Goals

`parallel/1`, `first_solution/2`, `first_solution/3`.

`parallel/1` has the value semantics of deterministic independent
conjunction when every worker succeeds: compatible bindings are combined and
incompatible bindings make the conjunction fail. Ordinary worker failure
fails the call; an exception is rethrown with its original term. Other exits
without a result, including `true`, throw `worker_exit(Pid,Reason)`.
If several workers have abnormal outcomes, the first abnormal `down/3`
observed by the caller determines the outcome; multiple-fault selection is
therefore scheduling-dependent rather than left-to-right.

Results are collected in goal order. A later worker's normal termination is
left pending until its result is collected, preserving out-of-order worker
completion. After a result is accepted, that worker's termination notification
only confirms that it has stopped, regardless of the reason. Remaining
workers are terminated and worker result/monitor messages are removed before
the call returns, fails, or throws through these outcome paths.

`first_solution/2-3` returns the first successful solver's result and cleans
up the other workers. `on_fail(stop|continue)` governs ordinary failure
(default `continue`); `on_error(stop|continue)` governs both exceptions and
unexplained exits (default `stop`). With `stop`, exceptions keep their
original terms and other exits throw `worker_exit(Pid,Reason)`, including
`true` when no result was delivered. With `continue`, the terminated solver
is removed and the call keeps waiting while alternatives remain. If all
alternatives are removed, the call fails. No new options are introduced.
Notifications from unrelated actors remain in the caller's mailbox.

The winning reply is selected independently of the caller's output pattern.
All workers are cleaned up before the selected payload is unified with
`Solution`. Compatible outputs and nonground payloads retain ordinary
unification and variable sharing. A mismatch consumes the winning reply and
fails after cleanup; it does not try another solver or apply `on_error`.

Both native operations now own their workers through an enclosing cleanup
scope. Every successful spawn is recorded in a private ownership record;
creation and recording are protected together against interruption, one
worker at a time. A later startup failure cleans up workers already created
and propagates the original error. Exceptions and caller interruption during
the wait also terminate owned workers and remove their result and monitor
messages before propagating the exception. The caller can catch that error
and continue without relying on parent-exit containment to reclaim workers.
If the caller has committed to actor termination, cleanup requests worker
stops and removes its worker monitors without waiting for replies to the
dying mailbox. Existing parent-to-child containment completes that teardown;
this does not add a guarantee that every child has stopped before the parent's
termination notification is delivered.

Consuming a worker's termination notification releases that worker from the
ownership record. Existing early cleanup clears the remaining record, so the
enclosing finalizer does not repeat termination or create new cleanup monitors
for already-settled workers. Normal `parallel/1` completion releases the record
after collecting every result and termination notification.
Result bindings, out-of-order completion, first-solution selection, and
`on_fail`/`on_error` policies are unchanged. Unrelated actors, monitors and
messages are preserved. This scope applies to the native worker generics;
it adds no paging cleanup or remote-cancellation mechanism.

Both SWI-WASM runtimes also scope `parallel/1` and `first_solution/2-3` workers.
The coordinator records a reserved pid before launch; the caller records that
pid before dispatching startup. Consequently, interruption while a reservation
or readiness reply is pending cannot leave an unowned local worker. Closing a
scope removes admission, reclaims outstanding reservations, stops remaining
workers, and removes only its own spawn monitors. Late readiness cannot install
a monitor after closure. Settled workers are released promptly.

Normal early-result/error paths await coordinator cleanup before returning or
unifying the selected output. The enclosing Prolog finalizer initiates closure
without awaiting, so startup errors, interruption and cuts can unwind safely.
Temporary receive filters and a coordinator barrier remove scoped worker
results and monitor notifications already queued across the browser bridge;
unrelated messages and explicit monitor references remain available. The main
engine's Stop handler also closes its scopes to unblock suspended startup.
The worker-based UI's hard Abort closes the discarded shell's scopes in the
coordinator before terminating and replacing that shell. It detaches the old
shell's event handlers so queued events cannot reopen scopes or affect the
replacement. Ordinary actors outside combinator scopes remain alive, and the
survivor notice counts those actors after scoped cleanup.
A terminating worker owner closes its scopes through existing containment.
The ownership records are private to these combinators; public spawn options
and ordinary spawning are unchanged. This adds no remote cancellation.

### Node Control

`node/1`, `node/2`.

### Operational Semantics

`receive/1-2` scans mailbox messages in arrival order. For each message it
tries receive clauses in textual order and commits to the first matching
clause; a failing guard defers the message rather than consuming it. When a
`timeout(Seconds)` expires, `receive/2` calls the `on_timeout(Goal)` option.
The default timeout goal is `true`, so timeout expiry succeeds unless
`on_timeout(fail)` (or another failing goal) is supplied explicitly.

`monitor(Pid, Ref)` returns a fresh opaque reference. If `Pid` has already
terminated, the caller immediately receives `down(Pid, Ref, no_process)`.
Monitor installation, actor termination and `demonitor(Ref, [flush])` are
serialized: either termination delivers one `down/3`, or demonitoring removes
the monitor before delivery. The `[flush]` option removes any already-delivered
`down/3` for `Ref`. Termination reasons use this vocabulary:

- `true` — normal successful completion;
- `false` — goal failure;
- `exception(Error)` — uncaught exception;
- `no_process` — the monitored pid was already gone;
- any other term — an explicit `exit/1-2` reason.

Omitting `limit` from a call collects all solutions with `findall/3`, subject
to resource bounds. Explicit limits must be positive integers. Neither
`infinity` nor a large default count is used. Finite toplevel paging uses
SWI-Prolog's `findnsols/4`, a mutable
`count(N)` limit cell and `nb_setarg/3`. Exact-multiple chunks are detected as
final (`success(Pid, Slice, false)`). Both the limit and target cells are
created before query execution so `$next` updates remain in force across
backtracking. These are SWI-Prolog implementation techniques, not portable ISO
Prolog guarantees.

`server_upgrade/2` replaces a generic server's callback while preserving its
current state term unchanged. An upgrade that changes the state representation
therefore requires an explicit migration protocol; `server_upgrade/2` alone
does not perform state conversion.

`toplevel_abort/1` is deliberately host-specific: it maps the actor pid to its
SWI-Prolog thread and uses `thread_signal/2` to throw the internal abort signal.
The protected catch boundary lets cleanup run but prevents application
recovery from consuming that signal. The PTCP loop then consumes it outside
the running goal and returns the same session actor to state **s1**. Actor
termination follows a different path: `exit/1-2` records the exit reason and
raises SWI-Prolog's fatal `unwind(abort)`, which is never consumed by PTCP.
Thus abort is a recoverable protocol interruption, while termination ends the
actor. Neither operation is an ordinary mailbox message.

Protection is applied to parsed goals and source and again at runtime-created
call boundaries. This includes `call/1-8`, dynamic assertion, receive bodies,
framework callbacks, and closures passed through loaded predicates declared
with `meta_predicate/1`; indirect invocation does not expose native unfiltered
`catch/3` semantics.

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
- **Runtime timing:** explicitly module-qualified access to raw timing
  implementations; use the checked local `time/1` wrapper instead.
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

Remote execution-time exhaustion raises `error(resource_error(time), _)`;
memory exhaustion raises `error(resource_error(space), _)`. Native and
SWI-WASM RPC clients propagate the remote exception directly. The public
resource exceptions elide backend context. Client transport timeouts remain
distinct and do not imply remote cancellation.
