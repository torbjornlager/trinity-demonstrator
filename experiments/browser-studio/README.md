# Trinity Studio: a separate UI experiment

An IDE-style interface inspired by the workspace/editor/query arrangement of
ErgoAI Studio 2. This is an original small prototype, using custom CSS Grid,
plain JavaScript, the demonstrator's existing CodeMirror editor, and the public
SWI-WASM Worker-session API. No new framework or downloaded dependencies.
It is not integrated into the demonstrator or its static distribution.

After completing the normal demonstrator dependency setup, run from the
repository root:

```sh
python3 experiments/browser-studio/serve.py --port 8092
```

Open http://localhost:8092/. The server binds to loopback and serves the
experiment alongside the already installed runtime assets. It does not start,
restart, proxy or configure native nodes. The existing demonstrator is untouched.
The launch script requires Python 3; execution requires a current browser.

Select an example, press **Load program**, then **Run query**. **Next** resumes
answer alternatives; **Stop** abandons them before another query. **Abort**
interrupts running work. **Reset session** disposes the runtime but retains source.
Editing source requires loading it again. Loading creates a fresh session.
Switching files disposes the previous session and retains per-file editor drafts.

You can open a local .pl file, download source with **Save source**, resize the
panes by dragging their separators (or using arrow keys when focused), and switch
between dark and light themes. The narrow-screen layout stacks the panes.
Answers, output and session diagnostics have separate tabs. Input requests open
a response dialog. Query history and drafts are held in page memory only;
closing or reloading the page loses them and destroys the engines. Save source
before leaving. No native-node connections, SSO, persistent workspace, project
filesystem, debugger or Monaco language services are implemented here.

There is no packaged shared example database: the visible source is passed to
`SwiWasmNode.create().open({source})`. Displayed answers come from the real engine.
Runtime and CodeMirror assets are served from the demonstrator's existing web/
paths, with their original licenses; they are not copied into this directory.

## Verification

Checked in the in-app browser with the installed real runtime: recursive family
query and Next, Stop followed by a new query, failure with streamed output,
exception reporting, actor ping/pong, Abort during a pending receive, and
read/1 through the input dialog. Also checked theme switching, narrow stacked
and compact three-column layouts, and keyboard pane resizing. JavaScript and
Python syntax checks pass. Remote-node access and real SSO are outside this
prototype's scope.
