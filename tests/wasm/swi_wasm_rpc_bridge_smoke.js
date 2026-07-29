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
const workerToplevelOptionHelpersSource = workerSource.slice(
  workerSource.indexOf("function readSpawnSourceAtom"),
  workerSource.indexOf("function actorReceive")
);
const workerToplevelOptionHelpers = Function(
  workerToplevelOptionHelpersSource +
  "\nreturn { spawnSource: toplevelSpawnSource, callOptions: toplevelCallOptions };"
)();
const manualSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "manual.html"),
  "utf8"
);
function actorExample(name) {
  return fs.readFileSync(
    path.join(__dirname, "..", "..", "examples", "actors", name),
    "utf8"
  );
}
function statechartExample(name) {
  return fs.readFileSync(
    path.join(__dirname, "..", "..", "examples", "statecharts", name),
    "utf8"
  );
}
const nodeWsSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "prolog", "web_prolog", "node_ws.pl"),
  "utf8"
);
const nodeSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "prolog", "web_prolog", "node.pl"),
  "utf8"
);
const sharedDbSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "prolog", "web_prolog", "wasm", "shared_db.pl"),
  "utf8"
);
const statechartWasmSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "prolog", "web_prolog", "wasm", "statechart_wasm.pl"),
  "utf8"
);
const statechartWasmRuntimeSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "prolog", "web_prolog", "wasm", "statechart_wasm_runtime.pl"),
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
const tutorialSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "tutorial.html"),
  "utf8"
);
const actorTutorialSource = fs.readFileSync(
  path.join(__dirname, "..", "..", "web", "actor-profile-tutorial.html"),
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

function embeddedWorkbenchMethod(name, nextName) {
  const marker = name + ": function";
  const start = source.indexOf(marker);
  const functionStart = source.indexOf("function", start);
  const end = source.indexOf("\n          " + nextName + ": function", functionStart);
  const expression = source.slice(functionStart, end).trim().replace(/,$/, "");
  return Function("return (" + expression + ");")();
}

const editorRewriteSource = source.slice(
  source.indexOf("function scanQuotedText"),
  source.indexOf("function renderOutputData")
);
const rewriteEditorLoadTextAware = Function(
  editorRewriteSource + "\nreturn rewriteEditorLoadTextAware;"
)();
const rpcUriHelpersSource = source.slice(
  source.indexOf("function normalizeNodeUrl"),
  source.indexOf("function currentNodeReferenceUrls")
);
const rpcUriHelpers = Function(
  rpcUriHelpersSource +
  "\nreturn { resolveBrowserRpcBaseUri, resolveBrowserRpcLoadUri };"
)();
const qualifiedServiceParserSource = source.slice(
  source.indexOf("function parseSwiWasmQualifiedServiceAddress"),
  source.indexOf("function currentNodeReferenceUrls")
);
const parseSwiWasmQualifiedServiceAddress = Function(
  qualifiedServiceParserSource +
  "\nreturn parseSwiWasmQualifiedServiceAddress;"
)();
const swiWasmLocalPidHelpers = Function(
  qualifiedServiceParserSource +
  "\nreturn { qualify: qualifySwiWasmLocalPid, localize: localizeSwiWasmPid };"
)();
const pidDisplayHelpersSource = source.slice(
  source.indexOf("function shortenPidToken"),
  source.indexOf("function formatBindingsRow")
);
const pidDisplayHelpers = Function(
  pidDisplayHelpersSource +
  "\nreturn { token: shortenPidToken, text: shortenLocalPidsInText };"
)();
const makeBrowserPromiseRef = embeddedWorkbenchMethod(
  "makeBrowserPromiseRef", "isSwiWasmUnboundVariable"
);
const swiWasmValueRenderer = {
  swiWasmStructuredCompound: embeddedWorkbenchMethod(
    "swiWasmStructuredCompound", "cleanupSwiWasm2ShellEntry"
  ),
  formatSwiWasmValue: embeddedWorkbenchMethod(
    "formatSwiWasmValue", "formatSwiWasmAtom"
  ),
  formatSwiWasmAtom: embeddedWorkbenchMethod(
    "formatSwiWasmAtom", "reconnectActiveTransport"
  )
};
const formatJavaScriptObject = embeddedWorkbenchMethod(
  "formatJavaScriptObject", "logSwiWasmWorkerTraffic"
);
const protocolLogFieldOrder = embeddedWorkbenchMethod(
  "protocolLogFieldOrder", "sortProtocolLogValue"
);
const sortProtocolLogValue = embeddedWorkbenchMethod(
  "sortProtocolLogValue", "cropProtocolLogValue"
);
const cropProtocolLogValue = embeddedWorkbenchMethod(
  "cropProtocolLogValue", "prettyJsonText"
);
const prettyJsonText = embeddedWorkbenchMethod(
  "prettyJsonText", "formatQueryParams"
);
const wsSend = embeddedWorkbenchMethod(
  "wsSend", "closeWs"
);
const conciseSwiWasmOutput = embeddedWorkbenchMethod(
  "conciseSwiWasmOutput", "echoSwiWasmOutput"
);
const replaceIsotopeSession = embeddedWorkbenchMethod(
  "replaceIsotopeSession", "abortIsotopeComputation"
);
const replaceSwiWasm2Shell = embeddedWorkbenchMethod(
  "replaceSwiWasm2Shell", "sendSwiWasm2Call"
);
const sendSwiWasm2Call = embeddedWorkbenchMethod(
  "sendSwiWasm2Call", "runSwiWasm2Query"
);
const protocolLogRenderer = {
  protocolLogFieldOrder,
  sortProtocolLogValue,
  cropProtocolLogValue,
  prettyJsonText,
  formatJavaScriptObject
};
const javaScriptObjectRenderer = protocolLogRenderer;

ok(includes("window.swiRpcGetAsync = function(url, httpTimeout)"),
   "paged RPC has an asynchronous fetch helper");
ok(includes("signal: controller.signal") &&
   includes("window.swiAbortRpc = function()"),
   "paged RPC fetch is abortable");
ok(includes('"    Promise := swiRpcGetAsync(#FinalURL, #HTTPTimeout),"') &&
   includes('"    await(Promise, Resp),"'),
   "web_rpc_page awaits each remote page");
ok(!includes('"    Resp := swiRpcGet(#FinalURL),"'),
   "web_rpc_page no longer uses synchronous XHR");
ok(includes("window.swiEnsureFinalFullStop = function(text)") &&
   includes('"    Text := swiEnsureFinalFullStop(#S)."'),
   "multiline src_text preserves a terminating full stop before trailing whitespace");
ok(includes("window.swiResolveRpcLoadUri = function(uri)") &&
   includes('"    ResolvedURI := swiResolveRpcLoadUri(#URIText),"'),
   "rpc src_uri resolves its source before the browser fetches it");
{
  const savedWindow = global.window;
  global.window = { location: { origin: "https://n1.elfenbenstornet.se" } };
  const markdownSource =
    "'[https://n2.elfenbenstornet.se](https://n2.elfenbenstornet.se/)'";
  ok(rpcUriHelpers.resolveBrowserRpcLoadUri(markdownSource) ===
       "https://n2.elfenbenstornet.se/" &&
     rpcUriHelpers.resolveBrowserRpcBaseUri("localhost") ===
       "https://n1.elfenbenstornet.se",
     "localhost RPC keeps the browser node as target while Markdown src_uri resolves as source");
  global.window = savedWindow;
}
ok(workerSource.includes('function actorLoadUri(uriText)') &&
   workerSource.includes('Promise := actorLoadUri(#URIText)') &&
   !workerSource.includes('rpc_load_uri(Options, LoadURI)') &&
   !workerSource.includes('loadUri: String(loadUri || "")') &&
   includes('case "src_uri":') &&
   includes('result = this.loadSwiWasmUriSource(message.uri || "");') &&
   includes('resolveBrowserRpcBaseUri(message.node || "")'),
   "worker RPC fetches src_uri source without using it to choose the call target");
ok(workerSource.includes("function actorEnsureFinalFullStop(text)") &&
   workerSource.includes('"    Text := actorEnsureFinalFullStop(#Text0)."'),
   "worker RPC preserves a terminating full stop before trailing whitespace");
ok(includes('if (!response.ok) {') &&
   includes('throw new Error("RPC failed: HTTP " + response.status'),
   "worker RPC reports non-success HTTP responses before Prolog parsing");
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
ok(includes("showTerminalSystemInfo: true") &&
   includes("Show system information") &&
   includes("wb.showTerminalSystemInfo") &&
   includes("echoTerminalSystemInfo: function") &&
   includes('output.addClass("terminal-system-info")') &&
   includes("--terminal-info-ink:") &&
   includes(".terminal .terminal-output .terminal-system-info"),
   "terminal system information is muted and can be disabled in Settings");
ok(conciseSwiWasmOutput("Warning: /worker_user_code.pl:1:") === "" &&
   conciseSwiWasmOutput(
     "Warning:    Local definition of user:parallel/1 overrides weak import from swi_wasm_actor_bridge"
   ) === "Warning: parallel/1 replaces the built-in definition." &&
   conciseSwiWasmOutput("ordinary output") === "ordinary output" &&
   includes('output.addClass("terminal-swi-wasm-override")') &&
   includes("color: var(--terminal-override-ink) !important;") &&
   includes("--terminal-override-ink: #1d6fa8;") &&
   includes("--terminal-override-ink: #67b8ff;") &&
   includes('this.echoSwiWasmOutput(term, String(message.data || ""))'),
   "SWI-WASM override notices are concise and blue in both themes");
ok(conciseSwiWasmOutput(
     "% 805 inferences, 3.335 CPU in 3.335 seconds (100% CPU, 241 Lips)"
   ) === "% 805 inferences in 3.335 seconds" &&
   includes("this.formatTimingDisplay(line)") &&
   includes('return theme === "dark" ? "#7ae2a1" : "#15803d";') &&
   includes('return "[[;" + webPrologTerminalTimingColor() + ";]" + escaped + "]";'),
   "SWI-WASM time/1 output keeps inference and elapsed time only and uses theme-aware green");
ok(includes('return "Welcome to [[b;;]Web Prolog]!\\n" +') &&
   includes('"The [[b;;]" + profile + "] profile.\\n" +') &&
   includes('"Powered by [[!u;;;;https://www.swi-prolog.org/]SWI-Prolog]\\n"') &&
   includes('profile = "ACTOR"') &&
   includes('profile = "ISOTOPE"') &&
   includes('profile = "ISOBASE"') &&
   includes("initialNodeInfoReady = this.fetchNodeInfo()") &&
   includes("initialNodeInfoReady.then(function()"),
   "terminal greeting identifies the announced profile and links to SWI-Prolog");
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
ok(includes("self.echoSwiWasmOutput(self.terminal, String(text).replace(/\\n$/, \"\"));"),
   "output is streamed to the terminal while a runner is active");
ok(includes('"flush :-",') &&
   includes("atomics_to_string(['Shell got ', Atom], MessageString)") &&
   includes('"        terminal_output(MessageString),",') &&
   workerSource.includes('"flush :-",') &&
   workerSource.includes("atomics_to_string(['Shell got ', Atom], MessageString)") &&
   workerSource.includes('"        terminal_output(MessageString),",'),
   "flush always writes the Shell got prefix in both SWI-WASM models");
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
   includes("this.echoSwiWasmOutput(this.terminal, String(message.output)"),
   "a spawned worker's stdout reaches the terminal (worker posts {type:output}; coordinator echoes) -- child stdout is not a gap");
ok(tutorialIncludes('src_text("echo_actor :-') &&
   tutorialIncludes("node('{{actor_peer_host}}'),\n       session(true)") &&
   !tutorialIncludes("node('{{actor_peer_host}}')\n   ])."),
   "SWI-WASM remote tutorial examples ship remote echo source and keep remote toplevels as sessions");
ok(tutorialIncludes('onclick="consult(&quot;#srv-fridge-source&quot;)"'),
   "supervised fridge tutorial source has a Load control");
ok(!tutorialIncludes('onclick="consult(&quot;#srv-fridge2-source&quot;)"') &&
   tutorialIncludes('<pre id="srv-upgrade">?- server_upgrade(fridge, fridge2, [') &&
   tutorialIncludes('src_text("'),
   "supervised fridge upgrade transfers callback source without replacing the shell");
ok(includes('<div class="project-title">Web Prolog code</div>') &&
   includes('<div class="project-title">SXML code</div>') &&
   includes('showPrologExamples: function() {\n            return this.hasWorkspacePane;') &&
   includes('showStatechartExamples: function() {\n            return this.hasWorkspacePane;') &&
   includes('if (example.kind === "statechart") {\n              return "actor";') &&
   includes(':class="{ \'is-profile-incompatible\': isExampleUnavailable(example) }"'),
   "the Examples drawer exposes both full code menus and marks profile-incompatible entries");
ok(includes('"02 grammar.pl": "stateless"') &&
   includes('"11 promise-and-yield.pl": "stateless"') &&
   !actorExample("11 promise-and-yield.pl").includes("writeln(") &&
   actorExample("11 promise-and-yield.pl").includes("sleep(0.5)") &&
   actorExample("11 promise-and-yield.pl").includes("timeout(0.1)") &&
   !actorExample("11 promise-and-yield.pl").includes("sleep(1)") &&
   !actorExample("11 promise-and-yield.pl").includes("sleep(2)"),
   "grammar and promise/yield examples are available on ISOBASE nodes");
{
  const currentLoadText = embeddedWorkbenchMethod(
    "currentLoadText", "currentSwiWasm2LoadText"
  );
  const context = {
    nodeAnnouncedProfile: "stateless",
    workspaceTab: "prolog",
    isBrowserSwiWasmMode: false,
    editorKind: "prolog",
    currentPrologText: () => "asynch_test_1(ok).",
    stripCommentLines: text => text
  };
  ok(currentLoadText.call(context) === "asynch_test_1(ok)." &&
     currentLoadText.call({ ...context, nodeAnnouncedProfile: "relation" }) === "",
     "ISOBASE calls include active editor source while RELATION calls remain source-free");
}
ok(includes(':href="profileTutorial.path"') &&
   includes('{{ profileTutorial.label }}') &&
   includes('path: "/isobase-profile-tutorial"') &&
   includes('label: "The ISOBASE profile"') &&
   includes('path: "/isotope-profile-tutorial"') &&
   includes('label: "The ISOTOPE profile"') &&
   includes('path: "/actor-profile-tutorial"') &&
   includes('label: "The ACTOR profile"') &&
   includes(':href="profileTutorial.apiPath"') &&
   includes('{{ profileTutorial.apiLabel }}') &&
   includes('apiPath: "/isobase-api-tutorial"') &&
   includes('apiLabel: "The stateless HTTP API"') &&
   includes('apiPath: "/isotope-api-tutorial"') &&
   includes('apiLabel: "The semi-stateful HTTP API"') &&
   includes('apiPath: "/actor-api-tutorial"') &&
   includes('apiLabel: "The stateful WebSocket API"') &&
   !includes('href="/wp-tutorial"') &&
   !includes('>Web Prolog Tutorial</a>'),
   "the Tutorials drawer exposes profile and API tutorials for each profile");
ok(includes('<div class="settings-option-label">SXML code</div>') &&
   !includes('<div class="settings-option-label">Statechart XML</div>'),
   "Settings calls Statechart XML coloring SXML code");
ok(includes("var EXAMPLES_PREFERRED_WIDTH_PX = 260;") &&
   includes("examplesWidthPx: EXAMPLES_PREFERRED_WIDTH_PX") &&
   includes("this.examplesWidthPx = EXAMPLES_PREFERRED_WIDTH_PX") &&
   !includes("fitExamplesWidth: function(workspaceWidth)") &&
   includes('window.localStorage.removeItem("wb.examplesWidthPx")') &&
   !includes('window.localStorage.setItem("wb.examplesWidthPx"') &&
   !includes('window.localStorage.setItem("wb.examplesWidthVersion"'),
   "the Examples drawer has one fixed width instead of per-node persisted or clamped widths");
ok(includes('workspaceTab: /^#[A-Za-z0-9_-]+$/.test(String(window.location.hash || "")) ? "tutorial" : "prolog",') &&
   includes('hasEditorPane: function() {\n            return this.hasWorkspacePane;') &&
   includes('if (normalized === "relation" && this.workspaceTab === "prolog") {') &&
   includes('if (this.examplesVisible) {\n              return {\n                gridTemplateColumns:\n                  "36px " +\n                  this.examplesWidthPx + "px "') &&
   !includes('this.nodeAnnouncedProfile + "-examples"'),
   "N1-N5 and SWI-WASM share the Editor and Examples drawer layout");
ok(includes('<p v-if="isBrowserSwiWasmMode" class="wb-header-section-note">\n              <a href="/wasm/shared_db.pl"') &&
   includes('rel="noopener noreferrer">Shared DB</a>') &&
   !includes('rel="noopener noreferrer">{{ currentPortalNodeAddress }}</a>'),
   "remote and SWI-WASM shared database links use the Shared DB label");
ok(includes('.editor-source-label {') &&
   includes('font-size: calc(var(--mono-size) + 1px);') &&
   includes('color: #000000;') &&
   includes(':root[data-theme="dark"] .editor-source-label {\n        color: #ffffff;'),
   "editor scratch-buffer and filename labels are larger and theme-aware");
const expandedEditorCommand = rewriteEditorLoadTextAware(
  "statechart_spawn(Pid, [src_text(<editor>)]).",
  "src_text('<statechart/>')"
);
ok(expandedEditorCommand.count === 1 &&
   expandedEditorCommand.invalidCount === 0 &&
   expandedEditorCommand.text ===
     "statechart_spawn(Pid, [src_text('<statechart/>')]).",
   "src_text(<editor>) expands as one explicit UI placeholder");
const ignoredEditorText = rewriteEditorLoadTextAware(
  "writeln('src_text(<editor>)'), % src_text(<editor>)\n/* <editor> */ true.",
  "src_text('wrong')"
);
ok(ignoredEditorText.count === 0 && ignoredEditorText.invalidCount === 0,
   "quoted and commented <editor> text is not expanded");
const invalidEditorText = rewriteEditorLoadTextAware(
  "statechart_spawn(Pid, [src_uri(<editor>)]).",
  "src_text('wrong')"
);
ok(invalidEditorText.count === 0 && invalidEditorText.invalidCount === 1,
   "<editor> outside src_text/1 is rejected instead of sent to Prolog");
ok(includes("prepareEditorCommand: function(command, term)") &&
   includes("prepared = this.prepareEditorCommand(combined, term);") &&
   includes('notice = "% <editor> expanded from') &&
   !includes('snapshot at submission') &&
   includes('src_text(<editor>)  snapshot the active SXML editor') &&
   !includes('statechart_spawn(Pid, [...]).'),
   "terminal and Examples share visible submission-time editor expansion");
ok(includes("escapeNestedPrologNegation: function(text)") &&
   includes("normalizeMarkdownUrlLiterals: function(text)") &&
   includes("this.normalizeMarkdownUrlLiterals(") &&
   includes("rawGoal = this.escapeNestedPrologNegation(") &&
   workerSource.includes("function escapeNestedPrologNegation(text)"),
   "all terminal transports protect negation inside nested Prolog source before parsing it");
ok(!includes('@click="runStatechart"') &&
   !includes('@click="haltStatechart"') &&
   !includes("runStatechart: function") &&
   !includes("haltStatechart: function") &&
   !includes("runSwiWasmStatechart: function") &&
   !includes("haltSwiWasmStatechart: function"),
   "the editor toolbar has no separate Run or Halt execution path");
ok(includes('class="terminal-action clear logger-filters-clear"') &&
   includes(".logger-filters-clear {\n        margin-left: auto;") &&
   includes(".logger-filters {\n        display: flex;") &&
   includes("min-height: 46px;\n        box-sizing: border-box;\n        padding: 8px 12px;") &&
   !includes(".logger-toolbar .terminal-action"),
   "Logger Clear sits at the right of the bottom panel at standard Clear size");
ok(includes('visibleLogKinds: ["info", "trace", "transport"]') &&
   includes('{ id: "info", label: "Info" }') &&
   includes('var filterKind = entry.kind === "trace" || entry.kind === "transport"') &&
   includes('window.localStorage.setItem("wb.visibleLogKindsVersion", "2")'),
   "Logger groups lifecycle, warning, error, timing, and UI events under Info");
ok(!includes("syncTracePreferenceToLiveSessions") &&
   !includes("isTraceLoggingEnabled") &&
   includes('this.log("trace", traceText, "statechart")') &&
   includes('this.notifyTutorialStatechartTrace(text)') &&
   includes('this.notifyTutorialStatechartTrace(event.data)'),
   "statechart traces always feed both the Logger and tutorial animations while SXML trace only filters display");
ok(includes('options: this.toplevelSpawnOptionsText(loadText, true)') &&
   includes('jsonBody: body\n            }).then(function(event) {\n              self.log("transport", JSON.stringify(event, null, 2), "isotope", "response");'),
   "ISOTOPE puts session and initial source in spawn options and logs the response as API traffic");
ok(includes('if (entry.scope === "wasm-worker") return "STATEFUL WORKER · JS OBJECT";') &&
   includes('logSwiWasmWorkerTraffic: function(envelope, direction)') &&
   includes('this.formatJavaScriptObject(envelope || {})') &&
   includes('command: "toplevel_spawn"') &&
   includes('command: "toplevel_call"') &&
   includes('command: "toplevel_next"') &&
   includes('command: "toplevel_stop"') &&
   includes('command: "toplevel_respond"') &&
   includes('message.type === "success"') &&
   includes('message.type === "failure"') &&
   includes('message.type === "stop"') &&
   includes('message.type === "prompt"') &&
   !includes('command: "shell_call"') &&
   !workerSource.includes('post("shell_event"') &&
   workerSource.includes('message.command === "toplevel_call"') &&
   workerSource.includes('post("success"') &&
   workerSource.includes('post("failure"'),
   "SWI-WASM Worker toplevel traffic uses the stateful API protocol on the actual Worker boundary");
ok(includes('options: this.toplevelSpawnOptionsText(extraSourceText, true)') &&
   includes('options: this.toplevelCallOptionsText({ limit: 1 })') &&
   !includes('callEnvelope.src_text = source') &&
   !includes('src_text: String(extraSourceText || "")') &&
   workerSource.includes('spawnSource = toplevelSpawnSource(message.options || "[]")') &&
   workerSource.includes('var callOptions = toplevelCallOptions(message.options || "[]")') &&
   workerSource.includes('toplevelCallHasSourceOption(message.options)') &&
   workerSource.includes('Unsupported toplevel_call source option') &&
   !workerSource.includes('deliver("\'$reload\'")'),
   "SWI-WASM Worker source crosses only in toplevel_spawn options and calls reject source options");
ok(includes('var nextEnvelope = {\n              command: "toplevel_next",\n              pid: Number(this.swiWasm2ShellPid)\n            };') &&
   includes('this.wsSend({\n              command: "toplevel_next",\n              pid: this.wsPid\n            });') &&
   includes('if (requestedLimit !== "default") {\n                envelope.limit = Number(requestedLimit);') &&
   workerSource.includes('deliver("\'$next\'([])")') &&
   !includes('pid: Number(this.swiWasm2ShellPid),\n              limit: 1') &&
   !includes('pid: this.isotopePid,\n                limit: String(this.solutionLimit)'),
   "browser-generated toplevel_next carries only pid and inherits the active call limit");
ok(workerToplevelOptionHelpers.spawnSource(
     "[session(true),src_text('p(''quoted''). q :- \\\\+ bad.')]"
   ) === "p('quoted'). q :- \\+ bad." &&
   JSON.stringify(workerToplevelOptionHelpers.callOptions(
     "[limit(7),offset(3),once(true)]"
   )) === JSON.stringify({ limit: 7, offset: 3, once: true }),
   "the Worker consumes canonical spawn and call options instead of parallel private fields");
ok(formatJavaScriptObject.call(javaScriptObjectRenderer, {
     command: "toplevel_call",
     pid: 4384261893,
     data: [{ Xs: "[]" }],
     more: true
   }) === [
     "{",
     '  command: "toplevel_call",',
     "  pid: 4384261893,",
     "  data: [",
     "    {",
     '      Xs: "[]"',
     "    }",
     "  ],",
     "  more: true",
     "}"
   ].join("\n"),
   "SWI-WASM API traffic is rendered as a JavaScript object literal rather than JSON text");
ok(formatJavaScriptObject.call(javaScriptObjectRenderer, {
     options: "abcdefghijklmnopqrstuvwxyz",
     goal: "q(X)",
     pid: 4384261893,
     command: "toplevel_call"
   }) === [
     "{",
     '  command: "toplevel_call",',
     "  pid: 4384261893,",
     '  goal: "q(X)",',
     '  options: "abcdefghijklmnopqrstuvwxy..."',
     "}"
   ].join("\n"),
   "SWI-WASM request fields follow book order and long values use remote-node cropping");
ok(prettyJsonText.call(protocolLogRenderer, JSON.stringify({
     more: false,
     data: [{ Pid: 91883433 }],
     pid: 23981144,
     type: "success"
   })) === [
     "{",
     '  "type": "success",',
     '  "pid": 23981144,',
     '  "data": [',
     "    {",
     '      "Pid": 91883433',
     "    }",
     "  ],",
     '  "more": false',
     "}"
   ].join("\n"),
   "JSON responses follow the book's type, pid, data, more field order");
{
  const previousWebSocket = global.WebSocket;
  let sentText = null;
  global.WebSocket = { OPEN: 1 };
  wsSend.call(Object.assign({
    ws: {
      readyState: 1,
      send: function(text) { sentText = text; }
    },
    log: function() {}
  }, protocolLogRenderer), {
    options: "[limit(1)]",
    goal: "q(X)",
    pid: 23981144,
    command: "toplevel_call"
  });
  global.WebSocket = previousWebSocket;
  ok(sentText === '{"command":"toplevel_call","pid":23981144,"goal":"q(X)","options":"[limit(1)]"}',
     "actual WebSocket request JSON is serialized in the book's field order");
}
ok(includes('POST /interaction_log (durable usage log): ') &&
   includes('Interaction log request failed: '),
   "interaction logging is visible, including failed recording attempts");
ok(includes('replacing ISOTOPE session ') &&
   includes('replacing ACTOR session ') &&
   includes('return this.spawnIsotopeSession(term, generation, loadSpec).then(function(newPid)') &&
   includes('self.haltIsotopeSession(retiringPid).then(function(event)') &&
   includes("the node's idle-session cleanup will reclaim it") &&
   includes('this.requestJson("/toplevel_halt"') &&
   includes('command: "toplevel_halt"') &&
   includes('return self.ensureWsSession(self.terminal, loadSpec)') &&
   !includes('params.src_text = reloadSpec.text') &&
   !includes('command.src_text = reloadSpec.text'),
   "edited source spawns an ISOTOPE replacement before best-effort retirement and never loads source through a call");
ok(includes('SWI-WASM actor" +') &&
   includes('" running: " + survivingPids.join(", ")'),
   "SWI-WASM hard Abort reports surviving actor pids");
ok(!includes('retractall(swi_wasm_actor_bridge:deferred(_))'),
   "the main-thread SWI-WASM model preserves deferred mailbox messages across queries");
ok([
  "01 pause-and-resume.xml", "02 spaghetti.xml", "03 emotions.xml",
  "04 clock.xml", "05 pingpong.xml", "06 parallel.xml",
  "07 closure.xml", "08 gcd.xml", "09 spawn-actor.xml",
  "10 spawn-toplevel.xml", "11 boxshop-1.xml", "12 boxshop-2.xml",
  "14 deferred-events.xml"
].every(function(name) {
  const text = statechartExample(name);
  return text.includes(
    "statechart_spawn(Pid, [\n       src_text(<editor>)\n   ])."
  ) && /\?- statechart_halt\(\$Pid, Reply, 1\)\.\n\n-->\s*$/.test(text);
}), "every numbered SXML file exposes launch and final halt queries");
ok(includes("return this.loadTutorialSourceIntoWsSession(sourceText)") &&
   includes("return this.replaceWsSession({") &&
   includes('origin: "transient"'),
   "tutorial Load replaces the ACTOR toplevel and transfers source only at spawn");
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
{
  const service = parseSwiWasmQualifiedServiceAddress(
    "counter@'https://n3.elfenbenstornet.se'"
  );
  const quotedService = parseSwiWasmQualifiedServiceAddress(
    "'publication-service'@'https://n3.elfenbenstornet.se'"
  );
  ok(service && service.pid === "counter" &&
     service.node === "https://n3.elfenbenstornet.se" &&
     quotedService && quotedService.pid === "publication-service" &&
     parseSwiWasmQualifiedServiceAddress(
       "1234567890@'https://n3.elfenbenstornet.se'"
     ) === null &&
     includes("var remote = parseSwiWasmQualifiedServiceAddress(pid) ||"),
     "SWI-WASM send routes qualified published-service addresses through the remote actor transport");
}
ok(includes("var markdown = /^\\[(https?:\\/\\/[^\\]]+)\\]\\((https?:\\/\\/[^)]+)\\)$/.exec(node);") &&
   includes("return markdown[2];"),
   "SWI-WASM bridge normalizes markdown-link remote node URLs");
ok(includes('var markdown = /^\\[(https?:\\/\\/[^\\]]+)\\]\\((https?:\\/\\/[^)]+)\\)$/.exec(trimmed);') &&
   includes('trimmed = markdown[2];') &&
   includes('window.swiResolveRpcBase = function(baseUri)'),
   "SWI-WASM RPC accepts pasted Markdown-link node URLs");
ok(includes("finalizeSwiWasmWorkerActor: function") &&
   includes("self.finalizeSwiWasmWorkerActor(pid,") &&
   includes('"worker_error: "'),
   "an uncaught worker error finalizes the actor (monitors' down/3 + name clear + reap), not just a log");
{
  const installMonitor = embeddedWorkbenchMethod(
    "monitorSwiWasmActor", "demonitorSwiWasmActor"
  );
  const delivered = [];
  const controller = {
    swiWasmActorWorkers: {
      main: { worker: {}, done: false, reason: null },
      failed: { worker: {}, done: true, reason: "false" }
    },
    swiWasmActorMonitors: [],
    resolveSwiWasmActorTarget: function(pid) { return String(pid); },
    parseSwiWasmRemoteToplevelPid: function() { return null; },
    parseSwiWasmRemoteActorPid: function() { return null; },
    swiWasmActorPidLive: function(pid) {
      const entry = this.swiWasmActorWorkers[String(pid)];
      return !!(entry && entry.worker && !entry.done);
    },
    deliverSwiWasmActorDown: function(watcher, ref, pid, reason) {
      delivered.push({ watcher, ref, pid, reason });
    }
  };
  const installed = installMonitor.call(
    controller, "main", "failed", "failed-ref"
  );
  ok(installed === true &&
     delivered.length === 1 &&
     delivered[0].reason === "false" &&
     controller.swiWasmActorMonitors.length === 0,
     "a monitor installed after a SWI-WASM worker exits receives its recorded failure reason");
}
{
  const exitActor = embeddedWorkbenchMethod(
    "exitSwiWasmActor", "abortSwiWasmActor"
  );
  let terminated = false;
  let notified = null;
  const controller = {
    swiWasmActorWorkers: {
      busy: {
        worker: {
          postMessage: function() {},
          terminate: function() { terminated = true; }
        },
        done: false,
        reason: null
      }
    },
    resolveSwiWasmActorTarget: function(pid) { return String(pid); },
    parseSwiWasmRemoteToplevelPid: function() { return null; },
    parseSwiWasmRemoteActorPid: function() { return null; },
    notifySwiWasmActorMonitors: function(pid, reason) {
      notified = { pid, reason };
    },
    log: function() {}
  };
  const exited = exitActor.call(controller, "busy", "true");
  ok(exited === true &&
     terminated === true &&
     controller.swiWasmActorWorkers.busy.done === true &&
     controller.swiWasmActorWorkers.busy.reason === "true" &&
     notified && notified.pid === "busy" && notified.reason === "true",
     "SWI-WASM exit hard-terminates a busy Worker and notifies its monitors");
}
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
   includes('this.swiWasmActorWorkers[pid] ||') &&
   includes('this.swiWasmReservedWorkerActorPids[pid] ||') &&
   workerSource.includes('/^[1-9][0-9]{9}$/.test(selfPidText)') &&
   nodeWsSource.includes("Id >= 1000000000") &&
   nodeWsSource.includes("Id =< 9999999999"),
   "SWI-WASM local workers use reserved random ten-digit numeric pids");
ok(swiWasmLocalPidHelpers.qualify("2159438818") === "2159438818@localhost" &&
   swiWasmLocalPidHelpers.localize("2159438818@localhost") === "2159438818" &&
   includes('Pid = LocalPid@localhost') &&
   workerSource.includes('"self(" + qualifyLocalPid(selfPidText) + ")."') &&
   includes('pids.push(qualifySwiWasmLocalPid(pid));') &&
   includes('qualifySwiWasmLocalPid(registry[name])') &&
   includes('qualifySwiWasmLocalPid(pidText)') &&
   nodeWsSource.includes('browser_local_pid(Id@localhost)') &&
   includes("'?localhost'?") &&
   manualSource.includes('reserve <code>localhost</code> as the local-node designator'),
   "browser actors expose Id@localhost while coordinator keys remain numeric");
ok(pidDisplayHelpers.token("2159438818@localhost", false) ===
     "2159438818@localhost" &&
   pidDisplayHelpers.token("2159438818@localhost", true) === "2159438818" &&
   pidDisplayHelpers.text("S = 2159438818@localhost.", false) ===
     "S = 2159438818@localhost." &&
   pidDisplayHelpers.text("S = 2159438818@localhost.", true) ===
     "S = 2159438818." &&
   pidDisplayHelpers.text(
     "Shell got down(5074010345@localhost,2356029108,true)", true
   ) === "Shell got down(5074010345,2356029108,true)" &&
   includes("self.terminal.echo(self.formatDisplayText(String(text)))") &&
   includes("term.echo(this.formatDisplayText(") &&
   includes("var text = this.formatDisplayText(renderOutputData(data));") &&
   includes("this.echoSwiWasmOutput(this.terminal, buf.replace") &&
   includes("this.echoSwiWasmOutput(this.terminal, output.replace"),
   "Hide local node in pid only removes @localhost from terminal display");
ok(includes("reserveSwiWasmActorRef: function()") &&
   includes("this.swiWasmReservedActorRefs[ref] = true;") &&
   includes("this.swiWasmReservedActorRefs[pid]") &&
   workerSource.includes('return actorRequest("make_ref", {});') &&
   workerSource.includes('"    await(Promise, RefText),"') &&
   !workerSource.includes('return "ref(" + selfPidText') &&
   !includes('return "ref(" + self.swiWasmNextActorRefId'),
   "SWI-WASM references are coordinator-reserved ten-digit numeric tokens");
{
  const livePromises = {};
  const ref1 = makeBrowserPromiseRef(livePromises);
  livePromises[String(ref1)] = true;
  const ref2 = makeBrowserPromiseRef(livePromises);
  ok(String(ref1).length === 10 && String(ref2).length === 10 &&
     ref1 >= 1000000000 && ref2 <= 1073741823 && ref1 !== ref2 &&
     workerSource.includes("function makePromiseRef()") &&
     !workerSource.includes("var nextRefId = 1"),
     "main and Worker SWI-WASM promises use opaque ten-digit references");
}
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
ok(includes('"swi_wasm_actor_bridge:ptcp(" + qualifySwiWasmLocalPid(pid) + ",terminal,true)"') &&
   includes('"shell_toplevel"') &&
   includes('message.type === "success"') &&
   workerSource.includes('message.command === "toplevel_call"') &&
   workerSource.includes('actorToplevelEvent(#Message, #Text)') &&
   workerSource.includes('flush_output(user_output)') &&
   includes('this.requestSwiWasmActorInput(String(message.data || ""))'),
   "SWI-WASM-2 drives a persistent worker-resident ptcp/3 shell actor");
ok(workerSource.includes('"    await(Promise, PidText),",\n      "    term_string(Pid, PidText).') &&
   includes('"    PidText := swiWasmActorWhereis(#Kind, #NameText),",\n              "    term_string(Pid, PidText).'),
   "whereis/2 binds an absent local name to undefined like a remote node");
ok(includes('entry.worker.terminate();') &&
   includes('Replacing only the shell Worker provides a') &&
   includes('this.swiWasm2ShellPid,\n              "",\n              "shell_toplevel"'),
   "SWI-WASM-2 hard abort replaces a blocked shell Worker at the same pid");
ok(workerSource.includes(':- module(swi_wasm_actor_bridge, [') &&
   workerSource.includes('].concat(behaviourSource.split("\\n")).join("\\n")') &&
   workerSource.includes('Prolog.query("use_module(\'/worker_actor_bridge.pl\')").once()') &&
   workerSource.includes('Goal = user:PlainGoal') &&
   workerSource.includes('strip_module(Goal0, GoalModule, PlainGoal)') &&
   workerSource.includes('Goal = GoalModule:PlainGoal') &&
   !workerSource.includes('consultSource(behaviourSource, "/worker_behaviour.pl")') &&
   workerSource.includes('consultSource(inheritedSource, "/worker_user_code.pl")') &&
   workerSource.includes('swi_wasm_actor_bridge:load_private_source(') &&
   includes('currentSwiWasm2LoadText: function()'),
   "SWI-WASM-2 keeps module-private runtime predicates separate from reloadable user source");
ok(workerSource.includes('"    toplevel_halt/1, toplevel_halt/2,"') &&
   workerSource.includes('"toplevel_halt(Pid) :- exit(Pid, true)."') &&
   workerSource.includes('"    monitor(Pid, Ref),"') &&
   workerSource.includes('"    receive({down(Pid, Ref, _) -> Reply = true}),"') &&
   !workerSource.includes('"        (   toplevel_halt(Pid),"') &&
   !workerSource.includes("'$halt'(From)") &&
   includes('"    toplevel_halt/1, toplevel_halt/2,"') &&
   includes('"toplevel_halt(Pid) :- exit(Pid, true)."') &&
   includes('"    receive({down(Pid, Ref, _) -> Reply = true}),"') &&
   !includes('"        (   toplevel_halt(Pid),"') &&
   !includes("'$halt'(From)"),
   "both SWI-WASM bridges halt through runtime exit without awaiting in cleanup");
ok(workerSource.includes('fetch("/wasm/shared_db.pl", { cache: "no-store" })') &&
   workerSource.includes('return installSharedDatabase().then(function()') &&
   workerSource.includes("load_files('/worker_shared_db.pl',[module(wasm_shared_db),silent(true)])") &&
   workerSource.includes('add_import_module(user,wasm_shared_db,start)') &&
   includes('fetch("/wasm/shared_db.pl", { cache: "no-store" })') &&
   nodeSource.includes("wasm_module_file_name('shared_db.pl').") &&
   sharedDbSource.includes('list_price(widget, 100).'),
   "every runtime imports an independent copy of the standalone SWI-WASM shared database");
ok(workerSource.includes('restore_shared_db_imports') &&
   workerSource.includes('shadowing_empty_dynamic(Name, Arity)') &&
   workerSource.includes('predicate_property(user:Head, number_of_clauses(0))') &&
   workerSource.includes('abolish(user:Name/Arity)'),
   "worker source loading repairs accidental empty dynamic shadows");
ok(workerSource.includes('load_private_source(') &&
   workerSource.includes('user:message_hook(redefined_procedure(_, _), warning, Lines)') &&
   workerSource.includes("sub_atom(File, _, _, 0, 'worker_shared_db.pl')") &&
   workerSource.includes('suppress_shared_override_warnings') &&
   includes('swi_wasm_actor_bridge:load_private_source'),
   "intentional shared-predicate shadows suppress only their loader redefinition warnings");
ok(includes('installSwiWasmSharedDatabase(Prolog, Module)') &&
   includes("load_files('/swi_wasm_shared_db.pl',[module(wasm_shared_db),silent(true)])") &&
   includes('swi_wasm_actor_bridge:load_private_source'),
   "the optional main-thread model uses the same shared/private module boundary");
ok(tutorialIncludes('id="tutorial-private-and-shared-knowledge"') &&
   tutorialIncludes('price(Item, Price) :-') &&
   tutorialIncludes('list_price(Item, ListPrice)') &&
   tutorialIncludes('spawn((price(widget, Price), Self ! child_price(Price)), _)') &&
   tutorialIncludes('consultAppend(&quot;#private-list-price&quot;)') &&
   tutorialIncludes('Shadowing operates on the complete predicate indicator') &&
   includes('appendSource: function(source, id)'),
   "the SWI-WASM tutorial demonstrates private pricing over shared knowledge");
ok(actorTutorialSource.includes('id="tutorial-private-and-shared-knowledge"') &&
   actorTutorialSource.includes('id="shadow-private-price"') &&
   actorTutorialSource.includes('src_text("list_price(widget, 80).")') &&
   actorTutorialSource.includes('Prices = [widget-100, gadget-250, gizmo-400]'),
   "the ACTOR profile tutorial demonstrates node-side private/shared shadowing");
ok(sharedDbSource.includes('echo_actor :-') &&
   sharedDbSource.includes('receive({') &&
   sharedDbSource.includes('From ! echo(Msg)') &&
   !sharedDbSource.includes('swi_wasm_actor_bridge:'),
   "the standalone SWI-WASM shared database accepts ordinary actor source");
ok(workerSource.includes('\":- use_module(\'/worker_actor_bridge.pl\').\\n\" + sourceText') &&
   includes('\":- use_module(\'/swi_wasm_actor_bridge.pl\').\\n\" + sourceText') &&
   includes('Unable to install the SWI-WASM actor bridge for the shared database'),
   "both SWI-WASM models import the actor API before compiling shared node code");
ok(tutorialSource.includes('id="mpc-spawn-echo">?- spawn(echo_actor, Pid).') &&
   actorTutorialSource.includes('id="mpc-spawn-echo">?- spawn(echo_actor, Pid).') &&
   tutorialSource.includes('prolog/web_prolog/wasm/shared_db.pl') &&
   actorTutorialSource.includes('prolog/web_prolog/wasm/shared_db.pl') &&
   !actorTutorialSource.includes('consult(&quot;#mpc-echo-source&quot;)'),
   "the echo tutorials identify the shared definition and need neither source transfer nor Load");
ok(workerSource.includes('Module.FS.writeFile("/worker_read_shim.pl"') &&
   workerSource.includes('redefine_system_predicate(read(_))') &&
   workerSource.includes('redefine_system_predicate(read_term(_, _))') &&
   workerSource.includes('read(Term) :- swi_wasm_actor_bridge:input(\\"|:\\", Term).') &&
   workerSource.includes('read_term(Term, _) :- swi_wasm_actor_bridge:input(\\"|:\\", Term).') &&
   workerSource.includes("atom(Prompt) -> atom_string(Prompt, PromptText)"),
   "the user-module worker shell routes read/1 and read_term/2 through its explicit prompt protocol");
ok(includes('source: String(extraSourceText || "")') &&
   !includes('extraSourceText || this.currentLoadText()'),
   "spawned SWI-WASM actors receive only explicit src_* source");
ok(actorExample("04 count_server.pl").includes("src_predicates([count_server/1])") &&
   actorExample("05 fridge.pl").includes("src_predicates([fridge/1])") &&
   actorExample("07 ping-pong.pl").includes("src_predicates([pong/0])") &&
   actorExample("07 ping-pong.pl").includes("src_predicates([ping/2])") &&
   actorExample("08 dining_philosophers.pl").includes("src_predicates([doForks/1])") &&
   actorExample("08 dining_philosophers.pl").includes("doWaiter/4, processWaitList/2, areAvailable/2") &&
   actorExample("08 dining_philosophers.pl").includes("philosopher/3, sleep/0") &&
   actorExample("10 simple_toplevel.pl").includes("src_predicates([session/2])"),
   "actor examples explicitly transfer editor predicates to spawned workers");
ok(includes("src_predicates([Pred/Arity])") &&
   !includes("wasm_user_source") &&
   actorExample("13 fridge_server.pl").includes("src_predicates([fridge/4])") &&
   actorTutorialSource.includes("start(server(fridge, [initial_state([])]))"),
   "supervised servers transfer callbacks across both actor boundaries");
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
   workerSource.includes('option(limit(Limit), Options, 10000000000)') &&
   workerSource.includes('"    Offset = 0,"') &&
   includes('"    Offset = 0,"') &&
   workerSource.includes('rpc_transport_options(Options, RemoteTimeout, Once, HTTPTimeout)') &&
   workerSource.includes('member(src_predicates(Indicators), Options)') &&
   includes('case "rpc":') &&
   includes('requestSwiWasmWorkerRpc: function(message)') &&
   includes('url.searchParams.set("once", "true")') &&
   includes('setTimeout(function() { controller.abort(); }, httpTimeout * 1000)'),
   "both SWI-WASM rpc/3 models keep initial transport offset internal");
ok(workerSource.includes('promise(Node, Goal, Ref) :-') &&
   workerSource.includes('Ref := actorPromiseStart(') &&
   workerSource.includes('option(offset(Offset), Options, 0)') &&
   includes('(member(offset(Offset), Opts) -> true ; Offset = 0)') &&
   workerSource.includes('Promise := actorPromiseWait(') &&
   includes('finish(null, false)') &&
   workerSource.includes('option(on_timeout(OnTimeout), Options, true)'),
   "both browser models provide non-consuming yield timeouts with the common default");
ok(workerSource.includes('runtime_property(implementation(swi_wasm_worker)).') &&
   workerSource.includes('runtime_property(inbound_addressable(false)).') &&
   includes('runtime_property(implementation(swi_wasm_main)).') &&
   includes('runtime_property(dom(true)).'),
   "browser runtimes expose their host capabilities through runtime_property/1");
ok(workerSource.includes('self(main@localhost).') === false &&
   includes('self(main@localhost).') &&
   includes('if (text === "main") return "main@localhost";') &&
   workerSource.includes('if (text === "main") return "main@localhost";'),
   "browser pid presentation consistently qualifies the main actor");
ok(workerSource.includes('transportable_term(Term) :-') &&
   includes('transportable_term(Term) :-') &&
   workerSource.includes('must_be_transportable_term(Message)') &&
   includes('must_be_transportable_term(Message)'),
   "browser actor boundaries enforce the shared portable-term subset");
ok(manualSource.includes('id="runtime_property/1"') &&
   manualSource.includes('<code>main@localhost</code>') &&
   manualSource.includes('All conforming native and browser runtimes accept:') &&
   manualSource.includes('<code>http_timeout(+Number)</code>') &&
   !manualSource.slice(
     manualSource.indexOf('<article class="predicate-entry" id="rpc/2-3">'),
     manualSource.indexOf('<article class="predicate-entry" id="promise/3-4">')
   ).includes('offset(+Integer)') &&
   manualSource.slice(
     manualSource.indexOf('<article class="predicate-entry" id="promise/3-4">'),
     manualSource.indexOf('<article class="predicate-entry" id="yield/2-3">')
   ).includes('offset(+Integer)') &&
   manualSource.includes('opaque ten-digit integer') &&
   manualSource.includes('If <code>on_timeout/1</code> is omitted, the timeout path succeeds.') &&
   !manualSource.includes('The native runtime additionally accepts') &&
   !manualSource.includes('The SWI-WASM runtimes additionally accept'),
   "the HTML manual presents one common browser/native programming contract");
ok(workerSource.includes('parallel/1, first_solution/2, first_solution/3') &&
   workerSource.includes('parallel(QualifiedGoals) :-') &&
   workerSource.includes('first_solution_(Solution, QualifiedGoals, Options) :-') &&
   workerSource.includes('option(on_fail(OnFail), Options, continue)') &&
   workerSource.includes('option(on_error(OnError), Options, stop)') &&
   includes('parallel/1, first_solution/2, first_solution/3') &&
   includes('parallel(QualifiedGoals) :-') &&
   includes('first_solution_(Solution, QualifiedGoals, Options) :-'),
   "both SWI-WASM models provide the actor-based predicate generics");
ok(workerSource.includes('statechart_spawn(Pid, Options) :-') &&
   !workerSource.includes('statechart_spawn(Pid) :-') &&
   !workerSource.includes('statechart_spawn/1,') &&
   workerSource.includes('statechart_wasm:set_trace_hook(user:statechart_trace_hook)') &&
   !workerSource.includes('message.statechartTrace') &&
   !includes('statechart_spawn(Pid) :-') &&
   !includes('statechart_spawn/1,') &&
   includes('statechart_wasm:set_trace_hook(') &&
   workerSource.includes('installStatechartRuntime(message)') &&
   includes('case "statechart_spawn":') &&
   includes('"statechart_actor"'),
   "SWI-WASM-2 runs statecharts in dedicated worker actors");
ok(workerSource.includes('post("terminal_output", {') &&
   workerSource.includes('term: String(termText || "true")') &&
   includes('/swi_wasm_actor_worker.js?v=20260729-spawn-source') &&
   includes('parentPid: startFields && startFields.parentPid') &&
   includes('this.spawnSwiWasmStatechartActor(message.sourceKind, message.source, pid)') &&
   includes('"terminal_output(" + qualifySwiWasmLocalPid(pid) + "," +') &&
   includes('this.sendSwiWasmActorMessage('),
   "SWI-WASM statechart terminal output is delivered to the spawning actor mailbox");
ok(includes("spawnSwiWasmWorkerActorReady") &&
   includes('result = this.spawnSwiWasmWorkerActorReady(message.goal') &&
   includes("await(SpawnPromise, SpawnedText)"),
   "SWI-WASM worker spawns resolve only after the child worker is ready");
ok(workerSource.includes('adapted.replace(/self\\(statechart\\)\\./g') &&
   workerSource.includes('"[target(" + qualifyLocalPid(selfPidText) + ")|Options]"') &&
   includes('"statechart_actor",') &&
   !includes('"statechart", "statechart_actor"'),
   "SWI-WASM-2 statechart workers route child replies to their concrete chart pid");
ok(statechartWasmSource.includes('send(Self, Event, Options) :-\n    self(Self),') &&
   statechartWasmSource.includes('Scheduled := wasmStatechartSchedule') &&
   statechartWasmSource.includes('Cancelled := wasmStatechartCancel') &&
   !statechartWasmSource.includes('send(statechart, Event, Options) :-'),
   "delayed statechart self-sends use the cancellable local scheduler in both SWI-WASM models");
ok(statechartWasmRuntimeSource.includes(
     'statechart_wasm:self(Self),\n    statechart_wasm:send(Self, Event, [delay(Delay), id(Ref)])'
   ) &&
   !statechartWasmRuntimeSource.includes(
     'statechart_wasm:send(statechart, Event, [delay(Delay), id(Ref)])'
   ),
   "after transitions resolve the rewritten worker self pid before scheduling");
ok(includes('statechart_spawn/2, statechart_halt/2, statechart_halt/3,') &&
   includes('statechart_halt(statechart, Reply, _Timeout) :-') &&
   includes('statechart_wasm:statechart_stop') &&
   includes('Reply = stopped.'),
   "the main-thread SWI-WASM bridge implements statechart_halt/2-3");
ok(workerSource.includes('"    monitor(Pid, Ref),"') &&
   workerSource.includes('"            exit(Pid, kill),"') &&
   workerSource.includes('"            receive({down(Pid, Ref, _) -> Reply = killed})"'),
   "statechart_halt/3 force-stops a busy SWI-WASM chart after its timeout");
ok(workerSource.includes('data = typeof args[1] === "string" ? args[1] : formatValue(args[1]);') &&
   workerSource.includes('post("output", { data: data });'),
   "SWI-WASM-2 terminal output renders strings without Prolog quotes");
ok(workerSource.includes('!(row[key] && row[key].$t === "v")') &&
   workerSource.includes('display[key] = formatValue(row[key])'),
   "SWI-WASM-2 omits unbound variables from successful binding rows");
ok(includes('compound.functor === "-" && args.length === 2') &&
   includes('this.formatSwiWasmValue(args[0]) + "-" + this.formatSwiWasmValue(args[1])'),
   "SWI-WASM renders pair terms with infix minus notation");
ok(includes('compound.functor === "=" && args.length === 2') &&
   includes('this.formatSwiWasmValue(args[0]) + "=" + this.formatSwiWasmValue(args[1])') &&
   includes('compound.functor === "," && args.length === 2') &&
   includes('return "(" + this.formatSwiWasmValue(args[0]) + "," +') &&
   swiWasmValueRenderer.formatSwiWasmValue({
     $t: "t",
     functor: "success",
     success: [
       {
         $t: "l",
         v: [{
           $t: "t",
           functor: ",",
           ",": [
             {$t: "t", functor: "sleep", sleep: [1]},
             {$t: "t", functor: "=", "=": ["a", "a"]}
           ]
         }]
       },
       false
     ]
   }) === "success([(sleep(1),a=a)],false)",
   "SWI-WASM renders unification and conjunction in operator notation inside RPC answers");

{
  const isotopeCalls = [];
  const isotopeHarness = {
    isotopePid: 11,
    spawnIsotopeSession: function() {
      isotopeCalls.push("spawn");
      this.isotopePid = 22;
      return Promise.resolve(22);
    },
    haltIsotopeSession: function(pid) {
      isotopeCalls.push("halt:" + pid);
      return Promise.reject(new Error("Not found"));
    },
    log: function(kind) {
      isotopeCalls.push("log:" + kind);
    }
  };
  replaceIsotopeSession.call(
    isotopeHarness, null, 1, { text: "p(new).", origin: "editor" }
  ).then(function(pid) {
    return new Promise(function(resolve) {
      setTimeout(function() {
        ok(pid === 22 &&
           isotopeCalls[0] === "spawn" &&
           isotopeCalls[1] === "halt:11" &&
           isotopeCalls.indexOf("log:warn") >= 0,
           "ISOTOPE replacement survives an older node's /toplevel_halt 404 after switching to the new pid");
        resolve();
      }, 0);
    });
  }).catch(function(error) {
    ok(false, "ISOTOPE replacement survives retirement failure: " + error.message);
  }).then(function() {
    const workerCalls = [];
    const oldEntry = { ready: true, done: false };
    const workerHarness = {
      swiWasm2ShellPid: "11",
      swiWasm2ShellReady: true,
      swiWasm2QueryPending: false,
      swiWasm2LoadedSource: "old.",
      swiWasmActorWorkers: { "11": oldEntry },
      lastBindings: { Old: "binding" },
      lastDollarVars: ["Old"],
      reserveSwiWasmWorkerActorPid: function() {
        return "22";
      },
      spawnSwiWasmWorkerActorReady: function(goal, sourceText, pid, name, role, fields) {
        workerCalls.push({
          action: "spawn",
          goal: goal,
          source: sourceText,
          pid: pid,
          name: name,
          role: role,
          candidate: fields.shellCandidate
        });
        this.swiWasmActorWorkers[pid] = {
          ready: true,
          done: false,
          shellCandidate: true
        };
        return Promise.resolve(pid);
      },
      retireSwiWasm2Shell: function(pid) {
        workerCalls.push({ action: "halt", pid: pid });
      },
      cleanupSwiWasm2ShellEntry: function(pid) {
        delete this.swiWasmActorWorkers[pid];
      }
    };
    global.qualifySwiWasmLocalPid = swiWasmLocalPidHelpers.qualify;
    return replaceSwiWasm2Shell.call(workerHarness, "new.").then(function(pid) {
      ok(pid === "22" &&
         workerHarness.swiWasm2ShellPid === "22" &&
         workerHarness.swiWasm2LoadedSource === "new." &&
         workerCalls[0].action === "spawn" &&
         workerCalls[0].source === "new." &&
         workerCalls[0].candidate === true &&
         workerCalls[1].action === "halt" &&
         workerCalls[1].pid === "11",
         "SWI-WASM Worker spawns and activates the sourced replacement before halting its predecessor");

      let sentEnvelope = null;
      const callHarness = {
        swiWasmActorWorkers: {
          "22": {
            ready: true,
            done: false,
            worker: {
              postMessage: function(envelope) {
                sentEnvelope = envelope;
              }
            }
          }
        },
        swiWasm2QueryPending: false,
        activeGoal: "queens(8, Queens)",
        pauseTerm: function() {},
        toplevelCallOptionsText: function() { return "[limit(1)]"; },
        logSwiWasmWorkerTraffic: function() {}
      };
      sendSwiWasm2Call.call(callHarness, {}, "22");
      ok(JSON.stringify(sentEnvelope) === JSON.stringify({
           command: "toplevel_call",
           pid: 22,
           goal: "queens(8, Queens)",
           options: "[limit(1)]"
         }),
         "SWI-WASM Worker calls use the canonical options field and carry no source");
      delete global.qualifySwiWasmLocalPid;
    });
  }).catch(function(error) {
    ok(false, "SWI-WASM replacement lifecycle: " + error.message);
  }).then(function() {
    console.log(failures === 0
      ? "\nswi_wasm_rpc_bridge smoke: PASS"
      : "\nswi_wasm_rpc_bridge smoke: FAIL (" + failures + ")");
    process.exit(failures === 0 ? 0 : 1);
  });
}
