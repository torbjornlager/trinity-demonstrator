# SWI-WASM runtime implementation guide

The [Web Prolog language manual](manual.html) is the shared API reference for
all nodes. This guide records browser implementation details and operational
limitations; it does not define a separate browser language.

## Worker and compatibility main engine

The Worker runtime runs each actor in its own Web Worker and SWI-Prolog engine.
The optional main-thread compatibility runtime runs shell queries in a shared
page engine; actors spawned from it still use Workers. Their implementations
live in [swi_wasm_actor_worker.js](swi_wasm_actor_worker.js) and
[vendor/swi-wasm-node.js](vendor/swi-wasm-node.js). The demonstrator supplies
presentation adapters through the host interface; the
[independent minimal host](vendor/swi-wasm-minimal.html) uses the same runtime.
The [extraction inventory and host API](../docs/SWI_WASM_NODE_EXTRACTION.md)
record the repository boundary. Statechart
interpreter sources are under [prolog/web_prolog/wasm](../prolog/web_prolog/wasm/).
The main engine has DOM access and cooperative interruption; Workers can be
terminated by the browser. Neither remains alive after its page is destroyed.

The bundled engine is pinned to `swipl-wasm@8.2.5` (SWI-Prolog 10.1.19), with
package integrity and bundle checksum in `dependencies/swi-wasm.json`.

## Language text and native boundaries

Both browser modes initialise `user:double_quotes` to `chars`. Goals and options,
interactive input, editor/URI source, the isolated `wasm_shared_db` module and
statechart datamodels read double-quoted literals as lists of one-character
Unicode atoms (`"hé😀"` is `[h,é,'😀']`; empty text is `[]`). This is a browser
reading-mode migration, not adoption of the experimental portable-text profile
by every node. `write/1` prints these values as list terms.

Bridge and library modules keep native string reading. Known text inputs (source,
URI and prompt text) convert character lists explicitly at JS/native boundaries;
numeric code lists are rejected. Existing URI origin, CORS and fetch restrictions
remain in force. The shared database is loaded explicitly into its own module,
with bridge imports; it is not copied into user source.

Canonical term messages are still read with `double_quotes(string)`. Native string
objects created by libraries, including returned HTTP data, keep their type and
variable sharing through the wire and Worker startup. Local `src_list/1` and
`src_predicates/1` are already typed terms: their generated source brackets native
string reading and restores character reading afterward. Internally supplied
behaviour code has the same boundary; ordinary user source reads characters.
Explicit remote source retains the destination's existing loading convention and
source ordering. No new remote text-mode negotiation is introduced.

The regression scenarios `portable_text_worker` and `portable_text_main` in
`tests/wasm/swi_wasm_contracts.js` run against the real WASM engine. See
[the migration verification record](../docs/verification/wasm-character-text-2026-10-25/REPORT.md)
for the complete WASM tier and temporary-origin UI checks.

## Main-thread output flushing

The main-thread lazy query driver flushes Prolog's `user_output` and `user_error`
before publishing each answer or exception. Cleanup flushes trailing output on
failure or abandonment. Flush errors do not replace query exceptions, and output
from later alternatives is produced only when the user requests the next answer.
This complements the existing Worker terminal flush; it does not change stream
buffering globally. Regression and UI evidence is in
[the output-flushing record](../docs/verification/wasm-output-flush-2026-10-25/REPORT.md).

## Source loading and named startup

The creating engine asks the page coordinator to fetch supplemental Prolog URI
source before child creation. Fetching retains the URI origin allowlist,
`credentials: same-origin` and CORS restrictions. Worker collection groups
text, lists, copied predicates and URI text; the main engine retains source-option
order. Repeated URIs cause separate fetches. Failed fetches propagate before
creation. Late completion cannot resume abandoned creation; cancelling an
in-flight fetch is a separate concern.

Wrappers separate their own options and framework metadata before forwarding
spawn options. Name reservations belong to matching creation tokens; explicit
registration and competing creation cannot claim a pending name. The coordinator
records an acknowledged remote pid before resuming the caller, and retains
rollback ownership through publication approval. On setup failure, output
mismatch or interruption it releases the name and withdraws startup-owned
monitors, requesting termination of known remote actors. A late correlated
acknowledgement cannot publish an abandoned creation. Cancellation before socket
readiness prevents late dispatch. Pending records last until acknowledgement
or connection close; remote side effects cannot be undone.

Remote spawn uses `request_id` correlation. Named startup rejects untagged
replies, while unnamed startup retains the legacy FIFO fallback. Reordered
replies settle their own requests; tagged cleanup exits cannot consume another
spawn reply. Remote alias cleanup checks current bindings before removal, then
delivers monitor notifications; old down events cannot remove replacement names.

## Monitor and worker cleanup

Monitor removal during Prolog unwinding cannot await JavaScript promises.
Notifications for a withdrawn reference are filtered until the coordinator
confirms local removal. Only the operation's own monitor is withdrawn. Remote
withdrawal is best effort and does not cancel a server request or collect a late
reply.

Combinators record worker ownership before launch. Normal result collection can
wait for coordinator cleanup; exception unwinding initiates cleanup without
awaiting JavaScript promises. Hard shell Abort closes combinator scopes before
replacing the shell. Ordinary actors outside those scopes survive and are listed
in the survivor notice. Forced Worker termination can bypass Prolog cleanup.

## Supervisors

Startup journals cover initial children, dynamic additions and replacement
groups, including detached and nested local starts. Ownership is tracked before
Worker creation/readiness and monitor setup. Readiness timeout rolls back the
caller's attempt; cleanup exceptions retain the original startup error. Initial
readiness reporting is not reused for later restart failures.

Group restarts preserve original specification records and list positions;
new dynamic children append. Old pid notifications are ignored after replacement.
Counts inspect processed supervisor records, not an independent liveness scan.
Shutdown installs private monitors before stop requests; recognised servers use
a tagged stop acknowledgement, and cleanup removes only that private reply and
monitor. Acknowledgement alone is not a termination barrier.

Browser supervisor halt uses a tagged request and acknowledges after child
shutdown. Its caller deadline remains independent of internal child shutdown
deadlines. Legacy `'$sup_stop'(From)` messages keep their `reply(true)` response.
The shared manual documents the different native halt acknowledgement timing
and the scope of restart/rollback guarantees.

## Promises

Each engine owns a local promise store. The main store persists across shell
queries; spawned Workers never inherit it. A numeric reference is meaningful
only in that engine and can coincide with a number in another store. Isolation
is not a security boundary against trusted JavaScript with access to the page.

Expiry is checked on access and by a timer, so browser timer throttling does not
extend the five-minute validity period. Collector claims are released before
running timeout callbacks. Collection commits when Prolog resumes after the
wait; output mismatch then consumes the selected result. Disposing or expiring
a reference retires its timers, waiters and local transport resources. Late
completion cannot reinsert it. Destroying an engine destroys its entire store.

## Statecharts and transport

The compatibility main engine hosts its first chart directly, using the fixed
`statechart` pid, and sends subsequent local charts to Workers. Its dispatch
branches keep local, nested and remote entry points separate so nested creation
does not overwrite the active interpreter configuration. XML is fetched by the
engine/node running the chart; supplemental Prolog follows the source-loading
path above.

Worker-backed statecharts expose the same `Id@localhost` pid form as ordinary
actors. Their spawn monitors retain that complete pid as the reference. The
main-thread singleton keeps the `statechart` pid; successful startup publishes
its liveness before monitor installation. Its stop boundary retires only that
chart's monitors, delivers normal `down/3` notifications once, and retains normal
completion for a chart that finishes before its spawn monitor is installed.
Main-thread sends and status synchronization use the same retirement boundary;
status checks inspect the WASM query result's `success` field rather than the
truthiness of its result object. Unrelated actor monitors are preserved.

The [native transport implementation notes](https://github.com/torbjornlager/swi-prolog-node/blob/main/prolog/web_prolog/README.md#node-transport-implementation)
document wire envelopes, terminal acknowledgements, session replay and monitor
reference serialization once. Browser connections offer `web-prolog-sync-v1`;
an upgrade failure before opening can retry without a subprotocol for legacy
asynchronous use. A synchronous call checks correlation support both before
monitor setup and on the actual sending socket. Connection setup is outside the
receive timeout.

Clients request `answer_terms:true`; negotiated asynchronous answers are parsed
as complete terms. Main-engine calls request `format(prolog)` to keep explicit
templates, while Worker actor-term calls already retain them. Legacy peers keep
their display-field limitations. The shared manual defines the observable errors
for absent/malformed negotiated terms and unsupported synchronous peers.

## Regression coverage

Browser regression drivers and UI checks cover option/child-spec validation,
source ordering, monitor cleanup, partial worker startup and interruption,
supervisor ordering/rollback/restart/shutdown, engine-local promise ownership,
statechart routing, remote naming, correlation and answer fidelity. Runtime
repair histories belong here and in test descriptions, not in predicate entries.


## Relation to the research agenda

The book’s [research and engineering agenda](https://github.com/torbjornlager/boken/blob/main/author/appendix-research-agenda.tex)
is maintained separately from this runtime guide.

The source-fetch, worker/supervisor cleanup, naming, monitor and promise-store
sections above record SWI-WASM implementation status. Browser-engine coverage,
resource/lifetime guarantees and portable lifecycle contracts remain engineering
and conformance questions, rather than conclusions implied by those repairs.

The shared SXML schema is supplied by the pinned native dependency during
`tools/setup_swi.py`; run browser tests through `tools/test.sh WASM` after setup.
