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
function actorExample(name) {
  return fs.readFileSync(
    path.join(__dirname, "..", "..", "examples", "actors", name),
    "utf8"
  );
}
const nodeWsSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "prolog", "web_prolog", "node_ws.pl"),
  "utf8"
);
const editorFrameSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "editor_frame.html"),
  "utf8"
);
const swiWasmTutorialSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "swi-wasm-tutorial.html"),
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

function tutorialIncludes(text) {
  return swiWasmTutorialSource.includes(text);
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
   includes('this.cancelSwiWasmMainActorWaiters("swi_wasm_abort") > 0') &&
   includes("if (!resumedSuspendedQuery)") &&
   includes("this.swiWasmProlog.abort();"),
   "Abort settles suspended waits without leaving a Prolog abort for the next query");
ok(includes("cancelSwiWasmMainActorWaiters: function(reason)") &&
   includes("waiter.reject(reason);") &&
   includes("return waiters.length;"),
   "blocking receive/1 mailbox promises are rejectable");
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
ok(includes('self.swiWasmStatechartOwnsActorTraffic() ? "statechart" : "main"') &&
   includes("swiWasmStatechartOwnsActorTraffic: function()") &&
   includes('return this.editorKind === "statechart" && !!this.swiWasmStatechartActive;') &&
   includes("deliverSwiWasmRemoteResult: function") &&
   includes("self.deliverSwiWasmRemoteResult(remoteMessage,"),
   "remote <spawn> in WASM charts only owns browser actor traffic while the statechart workbench is active");
ok(includes('message.type === "output"') &&
   includes("this.terminal.echo(String(message.output)"),
   "a spawned worker's stdout reaches the terminal (worker posts {type:output}; coordinator echoes) -- child stdout is not a gap");
ok(tutorialIncludes('load_text("echo_actor :-') &&
   tutorialIncludes("node('{{actor_peer_host}}'),\n       session(true)") &&
   !tutorialIncludes("node('{{actor_peer_host}}')\n   ])."),
   "SWI-WASM remote tutorial examples ship remote echo source and keep remote toplevels as sessions");
ok(tutorialIncludes('onclick="consult(&quot;#srv-fridge-source&quot;)"'),
   "supervised fridge tutorial source has a Load control");
ok(tutorialIncludes('onclick="consult(&quot;#srv-fridge2-source&quot;)"'),
   "supervised fridge upgrade source has a Load control");
ok(includes("server_upgrade(To, Pred0, Options) :- collect_spawn_source(Options, Source)") &&
   includes("'$upgrade'(From, Ref, PlainPred, Source)") &&
   includes("server_upgrade(To, Pred0) :- server_upgrade_source(To, Pred0, '')"),
   "server_upgrade/3 transfers explicit source while server_upgrade/2 transfers none");
ok(includes("collect_remote_spawn_source(Goal, Options, Source)") &&
   includes("default_remote_spawn_source(echo_actor") &&
   includes("option(session(Session), Options, true)") &&
   includes("swiWasmRemoteToplevelSpawn(#NodeText, #ExtraSource, #SessionText)"),
   "SWI-WASM bridge keeps stale remote echo/toplevel tutorial commands working");
ok(includes('self.routeSwiWasmActorMessage("remote", message.target, message.message);') &&
   !includes("self.sendSwiWasmActorMessage(message.target, message.message, \"remote\");"),
   "SWI-WASM bridge routes inbound remote actor messages through the local delivery funnel");
ok(includes("var markdown = /^\\[(https?:\\/\\/[^\\]]+)\\]\\((https?:\\/\\/[^)]+)\\)$/.exec(node);") &&
   includes("return markdown[1];"),
   "SWI-WASM bridge normalizes markdown-link remote node URLs");
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
ok(includes('root.crypto.getRandomValues(values);') &&
   includes('randomValue = (values[0] & 0x1fffff) * 4294967296 + values[1];') &&
   includes('pid = String(min + (randomValue % span));') &&
   includes('this.swiWasmReservedWorkerActorPids[pid] = true;') &&
   includes('this.swiWasmActorWorkers[pid] || this.swiWasmReservedWorkerActorPids[pid]') &&
   workerSource.includes('/^[1-9][0-9]{9}$/.test(selfPidText)') &&
   nodeWsSource.includes("Id >= 1000000000") &&
   nodeWsSource.includes("Id =< 9999999999"),
   "SWI-WASM local workers use reserved random ten-digit numeric pids");
ok(includes('window.localStorage.getItem("wb.swiWasmModel") === "main"') &&
   includes('node === "swi-wasm-2" || (node === "swi-wasm" && model !== "main")') &&
   includes('this.initSwiWasmSession();') &&
   includes('this.initSwiWasm2Session();') &&
   includes('{ id: "swi-wasm", href: "?node=swi-wasm", label: "SWI-WASM", active: this.isBrowserSwiWasmMode }') &&
   !includes('{ id: "swi-wasm-2", href: "?node=swi-wasm-2"') &&
   includes('handleBrowserRuntimeModelChange: function()') &&
   includes('use_module(library(dom))'),
   "one SWI-WASM entry defaults to workers and Settings retains the DOM-capable main model");
ok(includes('aria-label="About SWI-WASM execution models"') &&
   includes('for="swiWasmExecutionModel"') &&
   includes('id="swiWasmExecutionModel"') &&
   includes('Worker actors (default): the shell runs in a Web Worker') &&
   includes('Main thread + DOM: the shell runs on the browser UI thread') &&
   includes('Spawned actors still run in Workers.') &&
   includes('class="admin-config-help-button settings-model-help-button"') &&
   includes('type="button"') &&
   includes('.settings-model-help-button[data-help]') &&
   includes('document.getElementById("clampedHelpPopover")') &&
   includes('document.addEventListener("click", handleClick, true)'),
   "SWI-WASM model help is detailed and keyboard accessible");
ok(includes('"ptcp(" + pid + ",terminal,true)"') &&
   includes('"shell_toplevel"') &&
   includes('message.type === "shell_event"') &&
   workerSource.includes('message.command === "shell_call"') &&
   workerSource.includes('actorShellEvent(#Message, #Text)') &&
   workerSource.includes('flush_output(user_output)') &&
   includes('this.swiWasmPromptText(args[1])'),
   "SWI-WASM-2 drives a persistent worker-resident ptcp/3 shell actor");
ok(includes('entry.worker.terminate();') &&
   includes('Replacing only the shell Worker provides a') &&
   includes('this.swiWasm2ShellPid,\n              "",\n              "shell_toplevel"'),
   "SWI-WASM-2 hard abort replaces a blocked shell Worker at the same pid");
ok(workerSource.includes('consultSource(behaviourSource, "/worker_behaviour.pl")') &&
   workerSource.includes('consultSource(inheritedSource, "/worker_user_code.pl")') &&
   includes('currentSwiWasm2LoadText: function()'),
   "SWI-WASM-2 keeps runtime predicates separate from reloadable editor source");
ok(workerSource.includes('redefine_system_predicate(read(_))') &&
   workerSource.includes('redefine_system_predicate(read_term(_, _))') &&
   workerSource.includes('read(Term) :- input(\\"|:\\", Term).') &&
   workerSource.includes('read_term(Term, _) :- input(\\"|:\\", Term).') &&
   workerSource.includes("atom(Prompt) -> atom_string(Prompt, PromptText)"),
   "the worker shell routes read/1 and read_term/2 through its explicit prompt protocol");
ok(includes('source: String(extraSourceText || "")') &&
   !includes('extraSourceText || this.currentLoadText()'),
   "spawned SWI-WASM actors receive only explicit load_* source");
ok(actorExample("04 count_server.pl").includes("load_predicates([count_server/1])") &&
   actorExample("05 fridge.pl").includes("load_predicates([fridge/1])") &&
   actorExample("07 ping-pong.pl").includes("load_predicates([pong/0])") &&
   actorExample("07 ping-pong.pl").includes("load_predicates([ping/2])") &&
   actorExample("08 dining_philosophers.pl").includes("load_predicates([doForks/1])") &&
   actorExample("08 dining_philosophers.pl").includes("doWaiter/4, processWaitList/2, areAvailable/2") &&
   actorExample("08 dining_philosophers.pl").includes("philosopher/3, sleep/0") &&
   actorExample("10 simple_toplevel.pl").includes("load_predicates([session/2])"),
   "actor examples explicitly transfer editor predicates to spawned workers");
ok(includes("load_predicates([Pred/Arity])") &&
   !includes("wasm_user_source") &&
   actorExample("13 fridge_server.pl").includes("load_predicates([fridge/4])"),
   "WASM behaviours transfer declared callbacks without inheriting the editor");
ok(includes("numbervars(Copy, 0, _, [singletons(true)])") &&
   workerSource.includes("numbervars(Copy, 0, _, [singletons(true)])"),
   "generated WASM source preserves singleton variables as anonymous");
ok(workerSource.includes('actorRequest("remote_spawn"') &&
   workerSource.includes('actorRequest("remote_toplevel_spawn"') &&
   includes('case "remote_spawn":') &&
   includes('case "remote_toplevel_spawn":'),
   "worker actors delegate remote spawning to the JavaScript node controller");
ok(workerSource.includes('rpc(Node, Goal) :- rpc(Node, Goal, []).') &&
   workerSource.includes('Promise := actorRpc(') &&
   workerSource.includes('member(load_predicates(Indicators), Options)') &&
   includes('case "rpc":') &&
   includes('requestSwiWasmWorkerRpc: function(message)'),
   "SWI-WASM-2 provides rpc/2-3 through the JavaScript node controller");
ok(workerSource.includes('promise(Node, Goal, Ref) :-') &&
   workerSource.includes('Ref := actorPromiseStart(') &&
   workerSource.includes('Promise := actorPromiseWait('),
   "SWI-WASM-2 provides promise/3-4 and yield/2-3 over controller RPC");
ok(workerSource.includes('statechart_spawn(Pid, Options) :-') &&
   workerSource.includes('installStatechartRuntime(message)') &&
   includes('case "statechart_spawn":') &&
   includes('"statechart_actor"'),
   "SWI-WASM-2 runs statecharts in dedicated worker actors");
ok(includes('typeof args[1] === "string" ? args[1] : this.formatSwiWasmValue(args[1])'),
   "SWI-WASM-2 terminal output renders strings without Prolog quotes");
ok(includes('!this.isSwiWasmUnboundVariable(row[key])') &&
   includes('display[key] = this.formatSwiWasmValue(row[key])'),
   "SWI-WASM-2 omits unbound variables from successful binding rows");

console.log(failures === 0
  ? "\nswi_wasm_rpc_bridge smoke: PASS"
  : "\nswi_wasm_rpc_bridge smoke: FAIL (" + failures + ")");
process.exit(failures === 0 ? 0 : 1);
