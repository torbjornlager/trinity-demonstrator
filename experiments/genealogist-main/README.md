# The Genealogist — Main thread + DOM

This is the original Genealogist demo with the same CSS, Prolog program and
interface, running its shell on the browser UI thread. `library(dom)` is
preloaded. The interface itself is written in Prolog using that DOM access.
The worker version remains in `../genealogist`.

Both execution models now use `SwiWasmNode.create()` and the same high-level
`open`, `query`, `next`, `stop`, `abort`, `input` and `dispose` methods. This app
selects `mode:'main'`; the original app uses the default Worker mode. There is
no application-specific session adapter. The runtime owns paging, input waits,
interruption, output flushing, initialization and disposal, with common public
answer envelopes. Source loads once, preserving edits between queries. Stop
avoids future alternatives' side effects. Main-thread Abort remains cooperative:
a call that cannot yield can freeze the page. Spawned actors still use Workers.

Run with a verified, extracted swi-wasm-node package:

```sh
python3 experiments/genealogist-main/serve.py \
  --runtime-package /path/to/swi-wasm-node-package --port 8094
```

Open http://localhost:8094/. Use a swi-wasm-node package with the new `mode`
session option. The published comparison uses the same checksummed runtime in both demos,
with SWI-Prolog 10.1.19 / swipl-wasm 8.2.5. Each deployment manifest records its
committed application source, runtime revision and file checksums. The default
server package follows the demonstrator's current pin, so supply an explicit
`--runtime-package` containing the main session API when running this experiment.

Published versions:

- Worker actor: https://trinity.elfenbenstornet.se/genealogist/
- Prolog-driven Main thread + DOM: https://trinity.elfenbenstornet.se/genealogist-main/

The family is local to this page and disappears on reload. Save Prolog downloads
the current facts and original rules.

Try the original descendant, sibling and parent queries, or direct DOM access:

```prolog
E := document[getElementById(#'output')],
append_html(E, 'Hello from Prolog').
```

Expand Prolog output to see the text added by `library(dom)`.

## Prolog UI

`genealogist_ui.pl` owns SVG construction, generation layout, relationship rows,
answer cards, control state, keyboard and form bindings, input-dialog behaviour,
and serialization of saved facts. It uses `library(dom)` to build HTML and bind
events, `library(wasm)` for SVG and DOM properties, and `library(ugraphs)` for
cycle detection and topological layout. Its `solve/1` renders native bindings as
each answer is found. Next and Stop use the runtime's existing lazy driver.

The UI reads `relationship/3` directly. Form values become native atoms passed
to `add_relationship/3` and `remove_relationship/3`, without constructing goal
strings. DOM content is inserted as text. Query text remains executable Prolog,
as in the original demo; it is parsed with the user's operators and character
reading mode, while preserving whitespace inside quoted terms.

`genealogist.js` handles engine/source startup, asynchronous query orchestration,
Promise resolution for input, and Blob download. It schedules searches after DOM
event callbacks return; Prolog handles the actual events and rendering. The
UI renders native Prolog terms before the shared session API returns its normal
formatted binding rows. The family program and CSS are identical in both versions, as are the
packaged runtime bytes.

## Comparison with the original Worker UI

The formatted Worker app spans 481 JavaScript lines. This app spans 144
JavaScript lines and 595 Prolog UI lines, for 739 total. These are physical
source lines, including comments and blank lines, and exclude the shared runtime,
family program, HTML and CSS. Formatting alone changes these counts; they are
not a complexity score. Session management belongs to the shared runtime and
its cross-mode tests, rather than to an application-specific adapter.

The Worker app is smaller and follows the familiar web UI / Prolog engine
boundary. The Prolog UI keeps family data, edit validation calls, term formatting
and DOM events together, and avoids serializing a drawing snapshot or quoting
form values into goal strings. For a Prolog-focused maintainer this can be the
clearer domain flow. DOM construction still involves imperative operations,
nonbacktrackable UI state, and asynchronous browser coordination.

The shared API does not change thread isolation. In local headless Chrome,
ordinary waiting and yielding Prolog computation leave both interfaces usable.
A blocking foreign/JavaScript call leaves the Worker page responsive and blocks
the main-thread page for that call's duration. Main's heartbeat is cooperative;
it cannot preempt such a call.

## Verification

`test_browser.cjs` uses Playwright and an installed browser. With a static server
rooted at the homepage repository, test the packaged page and compare query
answers against the worker version:

```sh
DEMO_URL=http://localhost:8095/genealogist-main/ \
WORKER_URL=http://localhost:8095/genealogist/ \
CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
node experiments/genealogist-main/test_browser.cjs
```

Run `test_prolog_ui.cjs` with the same environment for the native DOM interface.
It checks matching diagram geometry, SVG keyboard and shortcut bindings, native
form errors, quoted whitespace and string/list answers, lazy side effects,
syntax-error recovery, cycle and empty-family layout, text-safe output, and
Prolog-bound Clear/Abort controls during a yielding CPU query.

Install or expose `playwright` through `NODE_PATH` if needed. Omit `CHROME_PATH`
to use Playwright's own browser. Optional `SCREENSHOT` and `SAVED_PROLOG` paths
control output artifacts. Checks cover the actual main-thread engine, zero shell
Workers, direct DOM changes through `append_html/2`, answer parity, paging,
Stop, lazy side effects, family edits, cycles, output, errors, input, input
cancellation, cooperative Abort and download. The copied native Prolog tests
can also run with:

```sh
swipl -f none -q -s experiments/genealogist-main/test_genealogist.pl \
  -g run_tests -t halt
```

The homepage's `tools/package_genealogist_main.py` creates a self-contained static
snapshot with a verified runtime, licenses and checksums. Use `--working-tree`
only for previews of uncommitted application source; the manifest explicitly
records that provenance and source hashes. For an uncommitted runtime package,
also pass `--development-runtime`; the deployment records this provenance while still verifying every runtime checksum.
Release builds require a clean runtime by default. Neither helper publishes the site.

## Source layout

The handwritten source favours readable statements, descriptive names and
comments explaining query lifetime, DOM operations and validation boundaries.
Both versions keep the same family clauses and CSS rules. JavaScript, HTML and
CSS use the local `.prettierrc.json`; Prolog uses four-space clause indentation
with separate goals and documented entry points. A few HTML `prettier-ignore`
markers preserve meaningful inline spacing around punctuation and line breaks.

To reproduce the web-source formatting from the repository root:

```sh
npx prettier@3.9.10 --write 'experiments/genealogist-main/*.{js,cjs,css,html}'
```

Edit these maintained source files, then rebuild the homepage snapshots. Do not
format the vendored engine or deployed runtime copies by hand.
