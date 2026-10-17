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

Caller-side toplevel validation precedes local setup, source copying, and
remote dispatch. Receiving HTTP/WebSocket toplevel endpoints validate raw
client options before source preparation and metadata injection; internal
metadata cannot be supplied as raw client options. Existing HTTP session
defaults, reserved WebSocket routing, and owner ceilings are unchanged.
In addition to name-type validation, local named creation now uses a
reservation/publication protocol, described below. Supervisor
child-specification validation is described in its own section. Remote
naming and broader lifecycle changes remain separate work.

### Actor Messaging

`send/2`, `send/3`, `!/2`, `receive/1`, `receive/2`,
`monitor/2`, `demonitor/1`, `demonitor/2`, `flush/0`.

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
still rejects `name/1`. Requests that actually create remote actors retain
post-spawn alias registration, without a cross-node atomicity guarantee.
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
retry. Namespace teardown does not automatically dispose of promises: a
surviving actor with that namespace can still collect its own reference.
Ownership transfer, automatic disposal on client/namespace teardown, remote
cancellation, and a portable ownership contract remain separate work.

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
