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
ok(includes('if (to === "statechart")') &&
   includes("this.enqueueSwiWasmStatechartEvent(message)") &&
   includes("current_predicate(statechart_wasm:statechart_send/1)") &&
   includes('Module.FS.writeFile("/swi_wasm_actor_bridge.pl", self.swiWasmRpcProlog())'),
   "<spawn> in WASM charts: bridge loaded for charts, send(statechart) routes from workers, replies become chart events");
ok(workerSource.includes('action === "input" ? null'),
   "worker input is exempt from the coordinator request timeout");

console.log(failures === 0
  ? "\nswi_wasm_rpc_bridge smoke: PASS"
  : "\nswi_wasm_rpc_bridge smoke: FAIL (" + failures + ")");
process.exit(failures === 0 ? 0 : 1);
