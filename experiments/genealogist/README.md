# The Genealogist — an independent SWI-WASM UI experiment

A modern browser version of Torbjörn Lager's [Genealogist tutorial](https://www.swi-prolog.org/pengines/),
using the public `SwiWasmNode.create()` API instead of `library(pengines)`.
The original family names and core relations connect the experiment to the
original example. The interface uses plain JavaScript, CSS and an accessible SVG
family diagram. No UI framework, jQuery, native node or Prolog server is required.

Runtime URLs are relative to the page, so the static UI and its runtime can
also be hosted together under a path such as `/genealogist/`.

The experiment is separate from the existing demonstrator and Studio prototype.
It is not included in the demonstrator's static distribution, and neither their
startup paths nor live node processes are changed.

## Run it

With Python 3.9+ and the demonstrator's browser dependency already set up:

```sh
python3 experiments/genealogist/serve.py --port 8093
```

Open http://localhost:8093/. The Python process only serves static files on
loopback; the Prolog engine and family database run in the browser.

The experiment can also use an independently extracted **swi-wasm-node v0.1.0**
package, without the demonstrator dependency setup or native SWI-Prolog:

```sh
python3 experiments/genealogist/serve.py \
  --runtime-package /path/to/swi-wasm-node \
  --port 8093
```

Use the directory containing `manifest.json` and `web/` from the
[release archive](https://github.com/torbjornlager/swi-wasm-node/releases/tag/v0.1.0).
The server checks the manifest hashes of its required runtime entry files. It
serves the package's web assets at `/runtime/`, without copying them. Runtime and
engine licenses remain in their package. This experiment directory can be moved
elsewhere and launched with an explicit package path.

## Explore

- Ask `ancestor_descendant(mike, Who)`; Next resumes alternatives, Stop abandons
  the remaining alternatives. Stop or finish before updating the family.
- Select a person in the diagram to fill in a descendant query. There are also
  shortcuts for sibling pairs and Sally's parents.
- Add `erica` as mother of `alex`. The diagram gains a person and
  `ancestor_descendant(mike, alex)` now succeeds. Remove the relationship using
  its × button; that query then fails.
- Try making `alex` a parent of `mike` while the previous connection exists:
  Prolog rejects the cycle. Duplicate additions are idempotent. Form names are
  lower-case identifiers of up to 32 characters; the wrappers limit the family
  to 200 relationship facts.
- Abort interrupts a running query. Output is separate from answers; `read/1`
  requests input in a dialog. Clear only clears displayed answers and output.
- Save Prolog downloads the current relationship facts together with the rules
  and update wrappers. The saved file can be loaded in SWI-Prolog or supplied as
  source to a new SWI-WASM session. This prototype has no file-import control.

Each page has its own Worker session. There is no localStorage, shared server
state or automatic persistence. Reloading or closing the page destroys its family.
Save before leaving. The preview server must remain running for asset requests.

## How it works

`genealogist.pl` supplies the facts, kinship rules and validated update predicates.
`genealogist.js` opens one browser session with that source, serializes operations,
and displays the public answer envelopes. `relationship/3` produces the snapshot
used by the diagram and relationship list. Topological levels in JavaScript only
position the nodes; all family queries and edits execute in Prolog.

The form calls `once(add_relationship(...))` or `once(remove_relationship(...))`,
then rereads the facts. Form values are validated and separately quoted as Prolog
atoms; they are not concatenated as goal fragments. Names, answers and output are
rendered as text rather than inserted as HTML. The source is visible under
“Under the hood”. The graph and edit controls refresh when a user query finishes
or is stopped; they do not compete with its answer continuation.

The query box intentionally permits ordinary Prolog queries, including updates.
Such queries can bypass the form's wrappers, introduce cycles, remove predicates
or otherwise invalidate the application. This is an educational local session,
not a restricted multiuser service. Runtime resources are disposed on page exit.
A failed or altered session can be restored to the sample by reloading the page.

## Verification

Nine native Prolog tests cover the original ancestors, deduplicated siblings,
recursive results after add/remove, idempotent duplicates, cycles, self-parenting,
invalid names, variable names and invalid roles:

```sh
swipl -f none -q -s experiments/genealogist/test_genealogist.pl \
  -g run_tests -t halt
```

The real browser runtime was also checked with the independently packaged
SWI-WASM runtime: startup, answer paging, Stop, form add/remove reflected in the
diagram and recursive queries, rejected cycles, output, failure, Abort while
waiting, input through `read/1`, and Prolog-file download. The saved program was
loaded in native SWI-Prolog. JavaScript syntax checks pass. No remote nodes,
authentication or public deployment are part of this experiment.
