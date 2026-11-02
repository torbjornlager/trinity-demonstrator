'use strict';

// Browser lifecycle and asynchronous operations. The Prolog module owns the UI.
let node,
  prolog,
  source = '',
  resolveInput = null,
  disposed = false;

// Short synchronous calls update the Prolog-owned DOM and presentation state.
// Long-running user queries go through the asynchronous session API instead.
function ui(goal, bindings = {}) {
  const answer = prolog.query('genealogist_ui:' + goal, bindings).once();
  if (answer?.error) throw new Error(answer.message);
  return answer;
}

// library(dom) event handlers call this bridge with an action name.
window.genealogistAction = (action) => {
  // Return from library(dom)'s event query before starting an async search.
  setTimeout(async () => {
    if (disposed) return;
    try {
      const prepared = ui('begin(Action, Goal)', { Action: action });
      if (!prepared || prepared.success === false) return;
      if (action === 'abort') {
        await node.abort();
        return;
      }
      if (action === 'stop') {
        await node.stop();
        ui('stopped');
        return;
      }
      // Engine strings may be boxed; atoms already arrive as JavaScript strings.
      const goal = prepared.Goal?.v ?? prepared.Goal;
      const answer = await (action === 'next'
        ? node.next()
        : node.query('genealogist_ui:solve(' + node.prologQuotedText(goal) + ')', {
            limit: 1,
          }));
      if (!disposed)
        ui('completed(Type, More, Message)', {
          Type: answer.type,
          More: answer.more === true,
          Message: typeof answer.data === 'string' ? answer.data : '',
        });
    } catch (error) {
      if (!disposed)
        ui('completed(Type, More, Message)', {
          Type: 'error',
          More: false,
          Message: error.message,
        });
    }
  }, 0);
  return true;
};

// Resolve at most one input request, including cancellation on page exit.
window.genealogistRespond = (value) => {
  if (resolveInput) {
    const resolve = resolveInput;
    resolveInput = null;
    resolve(value);
  }
  return true;
};

// Prolog serializes facts; the browser supplies Blob URLs and the download click.
// Keep UI code out of the saved program so it also loads in native SWI-Prolog.
window.genealogistSave = (facts) => {
  const text =
    source.split('% Sample facts')[0] +
    '% Saved facts from this browser session.\n' +
    facts;
  const url = URL.createObjectURL(
    new Blob([text], { type: 'text/plain;charset=utf-8' })
  );
  const link = document.createElement('a');
  link.href = url;
  link.download = 'my-family.pl';
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  return true;
};

// Closing the page ends the session and any pending input Promise.
window.addEventListener('pagehide', () => {
  disposed = true;
  genealogistRespond(null);
  if (node) node.dispose();
});

// Defer binding the UI until both source files and the browser engine are ready.
(async function boot() {
  try {
    const files = await Promise.all(
      ['genealogist.pl', 'genealogist_ui.pl'].map(async (name) => {
        const response = await fetch(name);
        if (!response.ok) throw new Error('Cannot load ' + name);
        return response.text();
      })
    );
    if (disposed) return;
    source = files[0];
    node = SwiWasmNode.create({
      mode: 'main',
      workerUrl: new URL(
        'runtime/swi_wasm_actor_worker.js?api=main-session',
        location.href
      ).href,
      engineUrl: new URL('runtime/swipl-bundle.js', location.href).href,
      prologBaseUrl: new URL('runtime/wasm/', location.href).href,
      sharedDatabaseUrl: null,
      onEvent(event) {
        if (!disposed && prolog && event.type === 'output')
          ui('output(Text)', { Text: event.data });
        return true;
      },
      onInput(prompt) {
        ui('input(Text)', { Text: prompt });
        return new Promise((resolve) => {
          resolveInput = resolve;
        });
      },
    });
    await node.open({ source });
    if (disposed) return;
    // Keep domain rules in user and UI predicates in their own module.
    // The UI is consulted once, after the high-level session has finished opening.
    prolog = node.swiWasmProlog;
    node.swiWasmModule.FS.writeFile('/genealogist_ui.pl', files[1]);
    const loaded = prolog.query("use_module('/genealogist_ui.pl', [])").once();
    if (loaded?.error || loaded?.success === false)
      throw new Error(loaded.message || 'Cannot load Prolog UI');
    ui('text(program, Text)', { Text: source });
    ui('init');
  } catch (error) {
    if (node) node.dispose();
    document.getElementById('status').textContent =
      'Could not start: ' + error.message + '. Reload to try again.';
  }
})();
