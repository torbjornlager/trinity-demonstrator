// Dependency-free regression checks for the SWI-WASM RPC bridge embedded in
// demonstrator.html.  These assertions protect the browser scheduling
// contract: paged rpc/3 calls must await fetches, stream side effects, and
// make the in-flight fetch abortable.
//
// Run: node tests/wasm/swi_wasm_rpc_bridge_smoke.js

"use strict";

const fs = require("fs");
const path = require("path");

const source = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "demonstrator.html"),
  "utf8"
);
const workerSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "swi_wasm_actor_worker.js"),
  "utf8"
);
const editorFrameSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "editor_frame.html"),
  "utf8"
);

let failures = 0;
function ok(condition, label) {
  if (condition) {
    console.log("  ok   " + label);
  } else {
    failures += 1;
    console.log("  FAIL " + label);
  }
}

function includes(text) {
  return source.includes(text);
}

function editorIncludes(text) {
  return editorFrameSource.includes(text);
}

ok(includes("window.swiRpcGetAsync = function(url)"),
   "paged RPC has an asynchronous fetch helper");
ok(includes("signal: controller.signal") &&
   includes("window.swiAbortRpc = function()"),
   "paged RPC fetch is abortable");
ok(includes('"    Promise := swiRpcGetAsync(#FinalURL),"') &&
   includes('"    await(Promise, Resp),"'),
   "web_rpc_page awaits each remote page");
ok(!includes('"    Resp := swiRpcGet(#FinalURL),"'),
   "web_rpc_page no longer uses synchronous XHR");
ok(includes("window.swiEnsureFinalFullStop = function(text)") &&
   includes('"    Text := swiEnsureFinalFullStop(#S)."'),
   "multiline load_text preserves a terminating full stop before trailing whitespace");
ok(includes("window.swiAbortRpc();") &&
   includes("this.swiWasmProlog.abort();"),
   "Abort cancels both fetch and Prolog execution");
ok(includes("terminalConvertLinks: true") &&
   includes("Convert URLs to links") &&
   includes("settings.convertLinks = this.terminalConvertLinks") &&
   includes("convertLinks: this.terminalConvertLinks") &&
   includes("echoCommand: false") &&
   includes("formatTerminalEchoText: function") &&
   includes("echoTerminalCommand: function") &&
   includes("self.echoTerminalCommand(term, command)") &&
   includes("formatters: false") &&
   includes("installTerminalUrlLinkFormatter") &&
   includes("window.webPrologTerminalConvertLinks === false") &&
   includes("[[!;;]"),
   "terminal URLs are converted to links when enabled, including echoed typed/pasted commands");
ok(includes("terminalHighlightPredicates: false") &&
   includes("Highlight Web Prolog predicates") &&
   includes("built-in predicate calls and predicate indicators") &&
   includes("wb.terminalHighlightPredicates") &&
   includes("WEB_PROLOG_TERMINAL_HIGHLIGHT_PREDICATE_NAMES") &&
   includes("WEB_PROLOG_TERMINAL_HIGHLIGHT_PREDICATE_INDICATORS") &&
   includes('"self/1"') &&
   includes('"!/2"') &&
   includes("WEB_PROLOG_TERMINAL_HIGHLIGHT_BARE_PATTERN = /\\b(flush)\\b") &&
   includes("(?:\\/|\\()") &&
   includes("WEB_PROLOG_TERMINAL_HIGHLIGHT_SEND_FUNCTOR_PATTERN") &&
   includes("WEB_PROLOG_TERMINAL_HIGHLIGHT_SEND_OPERATOR_PATTERN") &&
   includes('"$1$2" + markup + "!]"') &&
   includes('"server_spawn"') &&
   includes('"server_spawn/3-4"') &&
   includes('"supervisor_count_children"') &&
   includes('"rpc"') &&
   !includes('"asserta"') &&
   !includes('"listing"') &&
   includes("installTerminalPredicateHighlightFormatter") &&
   includes("formatter.__meta__ = true") &&
   includes("format_split(text).map") &&
   includes("highlightWebPrologTerminalPredicates(part)") &&
   includes("window.webPrologTerminalHighlightPredicates !== true") &&
   includes("this.terminalHighlightPredicates") &&
   includes("webPrologTerminalPredicateHighlightColor") &&
   includes("theme === \"dark\" ? \"#8fd782\" : \"#006400\"") &&
   includes("[[b;\" + webPrologTerminalPredicateHighlightColor() + \";]") &&
   includes('span[style*="font-weight: bold"]') &&
   includes('span[data-text][style*="font-weight: bold"]') &&
   includes("font-weight: 700 !important") &&
   !includes("[[b;var(--terminal-predicate-highlight);]"),
   "terminal can highlight manual-listed Web Prolog predicate calls and indicators in bold dark green");
ok(editorIncludes("WEB_PROLOG_CODEMIRROR_PREDICATE_NAMES") &&
   editorIncludes("WEB_PROLOG_CODEMIRROR_PREDICATE_INDICATORS") &&
   editorIncludes("cm-wp-builtin") &&
   editorIncludes("--editor-wp-predicate: #006400") &&
   editorIncludes("--editor-wp-predicate: #8fd782") &&
   editorIncludes('"self/1"') &&
   editorIncludes('"!/2"') &&
   editorIncludes('"flush/0"') &&
   editorIncludes("hasWebPrologSendOperatorLeftOperand") &&
   editorIncludes("hasWebPrologSendOperatorRightOperand") &&
   editorIncludes("editor.addOverlay(webPrologCodeMirrorOverlay)") &&
   editorIncludes("editor.removeOverlay(webPrologCodeMirrorOverlay)") &&
   !editorIncludes('"flush",'),
   "CodeMirror can apply the same Web Prolog predicate highlighting overlay");
ok(includes("self.terminal.echo(String(text).replace(/\\n$/, \"\"));"),
   "output is streamed to the terminal while a runner is active");
ok(includes("{ heartbeat: 1 }"),
   "long-running WASM queries yield frequently");
ok(includes("enqueueSwiWasmStatechartEvent") &&
   includes("self.swiWasmChartPending || self.swiWasmQueryPending") &&
   includes("self.drainSwiWasmStatechartEventQueue();"),
   "delayed statechart events are serialized behind all active engine work");
ok(!includes("window.prompt(") &&
   includes("requestSwiWasmActorInput") &&
   includes("if (this.swiWasmActorInputActive)"),
   "SWI-WASM read/1 and input/2 use the inline terminal prompt, not a modal");
ok(includes("swi_wasm_actor_bridge:swi_wasm_drive(user:(") &&
   includes("swi_wasm_await_more") &&
   includes("deterministic(Det)") &&
   includes("window.swiWasmAwaitMore = function()") &&
   includes("presentSwiWasmSolution") &&
   !includes('"limit(" + (LIMIT + 1)'),
   "solutions page lazily: side effects between answers run only on ';' (no eager forEach buffering)");
ok(includes('String(pidText) === "statechart"') &&
   includes("enqueueSwiWasmStatechartEvent(String(messageText") &&
   includes("current_predicate(statechart_wasm:statechart_send/1)") &&
   includes('Module.FS.writeFile("/swi_wasm_actor_bridge.pl", self.swiWasmRpcProlog())'),
   "<spawn> in WASM charts: bridge loaded for charts, send(statechart) routes from workers (via sendSwiWasmActorMessage), replies become chart events");
ok(includes("window.swiWasmStatechartMonitor = function(pidText, refText)") &&
   includes('self.monitorSwiWasmActor("statechart"') &&
   includes('if (pid === "statechart")'),
   "a chart's monitor/2 watches as `statechart`, so a monitored child's down(...) routes back as a chart event");
ok(includes('self.swiWasmStatechartActive ? "statechart" : "main"') &&
   includes("deliverSwiWasmRemoteResult: function") &&
   includes("self.deliverSwiWasmRemoteResult(remoteMessage)"),
   "remote <spawn> in WASM charts: a remote node's results/replies route to the running chart, not the unread main mailbox");
ok(includes('message.type === "output"') &&
   includes("this.terminal.echo(String(message.output)"),
   "a spawned worker's stdout reaches the terminal (worker posts {type:output}; coordinator echoes) -- child stdout is not a gap");
ok(includes("finalizeSwiWasmWorkerActor: function") &&
   includes("self.finalizeSwiWasmWorkerActor(pid,") &&
   includes('"worker_error: "'),
   "an uncaught worker error finalizes the actor (monitors' down/3 + name clear + reap), not just a log");
ok(includes("function settleReject(error)") &&
   includes("remote actor connection timed out:") &&
   includes("remote actor connection closed before ready:"),
   "remote connection settles once: rejects on close-before-open and on timeout, so the connect promise never parks");
ok(workerSource.includes('action === "input" ? null'),
   "worker input is exempt from the coordinator request timeout");

console.log(failures === 0
  ? "\nswi_wasm_rpc_bridge smoke: PASS"
  : "\nswi_wasm_rpc_bridge smoke: FAIL (" + failures + ")");
process.exit(failures === 0 ? 0 : 1);
