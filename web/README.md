# SWI-WASM runtime implementation guide

The [Web Prolog language manual](manual.html) is the shared API reference for
all nodes. This guide records browser implementation details and operational
limitations; it does not define a separate browser language.

## Worker and compatibility main engine

The Worker runtime runs each actor in its own Web Worker and SWI-Prolog engine.
The optional main-thread compatibility runtime runs shell queries in a shared
page engine; actors spawned from it still use Workers. Their implementations
live in [swi_wasm_actor_worker.js](swi_wasm_actor_worker.js) and the runtime and
coordinator sections of [demonstrator.html](demonstrator.html). Statechart
interpreter sources are under [prolog/web_prolog/wasm](../prolog/web_prolog/wasm/).
The main engine has DOM access and cooperative interruption; Workers can be
terminated by the browser. Neither remains alive after its page is destroyed.

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

The [native transport implementation notes](../prolog/web_prolog/README.md#node-transport-implementation)
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
