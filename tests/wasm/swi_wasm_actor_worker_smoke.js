// Dependency-free smoke test for the JS actor-scheduling core of
// web/swi_wasm_actor_worker.js (mailbox, receive ordering, timeout,
// send-to-self, and the request/reply channel).
//
// It loads the worker IIFE with a mock Worker global and exercises the
// JS layer WITHOUT SWI-WASM: start() (which importScripts the bundle and
// boots Prolog) is never called, so no browser/WASM is needed.
//
// Run:  node tests/wasm/swi_wasm_actor_worker_smoke.js
//
// NOT covered here (still manual / browser-only): the generated Prolog
// actor bridge (spawn/receive guards/monitor/...) and the full
// worker<->coordinator integration. See the review notes.

"use strict";

const fs = require("fs");
const path = require("path");

let failures = 0;
function ok(cond, label) {
  if (cond) {
    console.log("  ok   " + label);
  } else {
    failures++;
    console.log("  FAIL " + label);
  }
}

function makeMockSelf() {
  const posted = [];
  const s = {
    postMessage: function(m) { posted.push(m); },
    close: function() { s._closed = true; },
    _posted: posted
  };
  return s;
}

function loadWorker() {
  const src = fs.readFileSync(
    path.join(__dirname, "..", "..", "web", "swi_wasm_actor_worker.js"),
    "utf8"
  );
  global.self = makeMockSelf();
  // The IIFE reads `self`, `setTimeout`, `clearTimeout` from globals;
  // importScripts/SWIPL are only touched inside start(), never run here.
  (0, eval)(src);
  return global.self;
}

async function main() {
  const S = loadWorker();

  // 1. deliver -> receive (mailbox already has the message)
  S.onmessage({ data: { command: "deliver", message: "hello" } });
  ok((await S.actorReceive(-1)) === "hello", "deliver then receive");

  // 2. receive (blocks) -> later deliver wakes the waiter
  const pending = S.actorReceive(-1);
  S.onmessage({ data: { command: "deliver", message: "world" } });
  ok((await pending) === "world", "receive then deliver wakes waiter");

  // 3. receive timeout returns null after roughly the requested delay
  const t0 = Date.now();
  const timedOut = await S.actorReceive(0.03);
  ok(timedOut === null, "receive timeout returns null");
  ok(Date.now() - t0 >= 20, "receive timeout actually waited");

  // 4. send-to-self is delivered locally (no coordinator round-trip)
  await S.actorSend("self", "to-self");
  ok((await S.actorReceive(-1)) === "to-self", "send to self delivers locally");

  // 5. send to another pid -> posts a request, reply resolves it
  const sendP = S.actorSend("9900000000@localhost", "msg");
  const req = S._posted.find(function(m) { return m.type === "request" && m.action === "send"; });
  ok(!!req && req.to === "9900000000" && req.message === "msg", "send posts a request");
  S.onmessage({ data: { command: "reply", id: req.id, ok: true, result: true } });
  ok((await sendP) === true, "reply (ok) resolves the request");

  // 6. a failing reply rejects the request promise
  const sendP2 = S.actorSend("9800000000", "m2");
  const req2 = S._posted.filter(function(m) { return m.type === "request"; }).pop();
  let rejected = false;
  S.onmessage({ data: { command: "reply", id: req2.id, ok: false, error: "no such actor" } });
  try { await sendP2; } catch (_e) { rejected = true; }
  ok(rejected, "reply (not ok) rejects the request");

  // Browser-node references use the same opaque ten-digit numeric form as
  // deployed nodes. The coordinator allocates them globally so separate
  // actor Workers cannot mint colliding local counters.
  const refP = S.actorMakeRef();
  const refReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "make_ref";
  }).pop();
  ok(!!refReq, "make_ref is delegated to the node controller");
  S.onmessage({ data: { command: "reply", id: refReq.id, ok: true, result: "7928403267" } });
  ok((await refP) === "7928403267", "make_ref returns an opaque numeric reference");

  // 7. Requests that carry a target pid must not be overwritten by the
  // worker's own pid.  Seed selfPidText via the invalid-start path so the
  // test remains dependency-free and does not import the SWI-WASM bundle.
  S.onmessage({ data: { command: "start", pid: "invalid_actor" } });
  S.actorSpawnWithPid("4200000000", "true", "");
  const spawnReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "spawn";
  }).pop();
  ok(!!spawnReq && spawnReq.pid === "4200000000" && spawnReq.link === true,
     "spawn request preserves target pid and defaults link to true");
  S.actorSpawnWithPid("4300000000", "true", "", "", "false");
  const unlinkedSpawnReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "spawn";
  }).pop();
  ok(!!unlinkedSpawnReq && unlinkedSpawnReq.pid === "4300000000" &&
     unlinkedSpawnReq.link === false,
     "spawn request preserves an explicit link(false)");

  // 8. Remote work is delegated to the JavaScript node controller.  The
  // worker keeps the same spawn vocabulary without owning a WebSocket.
  const remoteSpawnP = S.actorRemoteSpawn("'https://n4.example'", "echo_actor", "");
  const remoteSpawnReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "remote_spawn";
  }).pop();
  ok(!!remoteSpawnReq && remoteSpawnReq.node === "'https://n4.example'",
     "remote spawn is delegated to the node controller");
  S.onmessage({ data: { command: "reply", id: remoteSpawnReq.id, ok: true, result: "1234567890@'https://n4.example'" } });
  ok((await remoteSpawnP) === "1234567890@'https://n4.example'",
     "remote spawn reply preserves the distributed pid");

  // 9. A shell-role worker translates toplevel API commands into the ptcp/3
  // mailbox protocol.  An invalid pid avoids booting the actual WASM bundle.
  S.onmessage({ data: {
    command: "toplevel_spawn",
    pid: "invalid_shell",
    options: "[session(true),src_text('p(a).')]"
  } });
  S.onmessage({ data: {
    command: "toplevel_call",
    goal: "member(X,[a,b])",
    options: "[limit(7),offset(3),once(true)]"
  } });
  const shellCall = await S.actorReceive(-1);
  ok(shellCall.indexOf("'$call_text'") === 0 &&
     shellCall.includes("member(X,[a,b])") &&
     shellCall.endsWith(",7,3,true)"),
     "shell call consumes limit, offset, and once from canonical options");

  S.onmessage({ data: {
    command: "toplevel_next",
    pid: "invalid_shell"
  } });
  const shellNext = await S.actorReceive(-1);
  ok(shellNext === "'$next'([])",
     "shell next carries no limit and leaves the active call limit unchanged");

  S.onmessage({ data: {
    command: "toplevel_call",
    goal: 'rpc(node, immortal(Who), [src_text("immortal(Who) :- \\+ mortal(Who).")])',
    options: "[limit(1)]"
  } });
  const nestedNegation = await S.actorReceive(-1);
  const nestedGoalLiteral = nestedNegation.match(/^'\$call_text'\(("(?:[^"\\]|\\.)*"),/);
  const nestedGoal = nestedGoalLiteral && JSON.parse(nestedGoalLiteral[1]);
  ok(nestedGoal && nestedGoal.includes(String.fromCharCode(92, 92) + "+ mortal(Who)"),
     "shell call escapes negation inside nested Prolog source before reparsing it");

  S.onmessage({ data: {
    command: "toplevel_call",
    goal: "true",
    options: "[limit(1)]",
    src_text: "p(edited)."
  } });
  const rejectedCallSource = S._posted.filter(function(m) {
    return m.type === "error" &&
      m.data === "Unsupported toplevel_call source option";
  }).pop();
  ok(!!rejectedCallSource,
     "shell call rejects the legacy call-time src_text field");

  await S.onmessage({ data: {
    command: "toplevel_call",
    pid: 42,
    goal: "p(X)",
    options: "[limit(1),src_text('forbidden.')]"
  } });
  const rejectedOptionSource = S._posted.filter(function(m) {
    return m.type === "error" &&
      m.data === "Unsupported toplevel_call source option";
  }).pop();
  ok(!!rejectedOptionSource,
     "shell call rejects source hidden in call options");

  // 9b. A read/1 answer carrying a comma + trailing '.' is parenthesised and
  // the period stripped, so '$input' stays arity 2 (a bare comma would make
  // it '$input'/3 and the shell's receive would never match).
  S.onmessage({ data: { command: "toplevel_respond", input: "a, b." } });
  const shellInput = await S.actorReceive(-1);
  ok(shellInput === "'$input'(terminal,(a, b))",
     "shell input parenthesises the answer and strips the read terminator");
  // An empty answer maps to end_of_file (not the invalid term '()').
  S.onmessage({ data: { command: "toplevel_respond", input: "" } });
  const shellEof = await S.actorReceive(-1);
  ok(shellEof === "'$input'(terminal,end_of_file)",
     "an empty shell input answer is end_of_file");

  // Prolog toplevel events cross the Worker boundary as the canonical API
  // response itself, not wrapped in a private shell_event envelope.
  S.actorToplevelEvent({
    $t: "t",
    success: ["invalid_shell", [{ Xs: { $t: "l", v: ["a"] } }], true]
  }, "success(invalid_shell,[_{Xs:[a]}],true)");
  const successEvent = S._posted.filter(function(m) { return m.type === "success"; }).pop();
  ok(!!successEvent && successEvent.data[0].Xs === "[a]" && successEvent.more === true &&
     !Object.prototype.hasOwnProperty.call(successEvent, "event"),
     "toplevel success is posted in the canonical API response shape");
  ok(JSON.stringify(Object.keys(successEvent)) ===
     JSON.stringify(["type", "pid", "data", "more"]),
     "toplevel success fields are emitted in the book's response order");

  S.actorToplevelEvent({
    $t: "t",
    error: ["invalid_shell", { $t: "t", existence_error: ["procedure", "q/1"] }]
  }, "error(existence_error(procedure,q/1),context(solution_sequences:offset/2,_))",
  "error(existence_error(procedure,q/1),_)");
  const errorEvent = S._posted.filter(function(m) { return m.type === "error"; }).pop();
  ok(!!errorEvent &&
     errorEvent.data === "error(existence_error(procedure,q/1),context(solution_sequences:offset/2,_))" &&
     errorEvent.details === "error(existence_error(procedure,q/1),_)",
     "toplevel errors preserve raw data and add a context-elided exception term");

  // 10. Worker-side rpc/2-3 uses the same controller request channel as
  // remote actor transport; the Worker does not own browser HTTP policy.
  const rpcP = S.actorRpc("'https://n1.example'", "path(a,X)", "v(X)", 0, 10,
    "edge(a,b).", 2.5, true, 3);
  const rpcReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "rpc";
  }).pop();
  ok(!!rpcReq && rpcReq.goal === "path(a,X)" && rpcReq.loadText === "edge(a,b)." &&
     rpcReq.remoteTimeout === 2.5 && rpcReq.once === true && rpcReq.httpTimeout === 3 &&
     !Object.prototype.hasOwnProperty.call(rpcReq, "loadUri"),
     "RPC delegates the common execution and transport options to the node controller");
  S.onmessage({ data: { command: "reply", id: rpcReq.id, ok: true, result: "success([v(b)],false)" } });
  ok((await rpcP) === "success([v(b)],false)", "RPC response text returns to Prolog");
  ok(S.actorEnsureFinalFullStop("p(a).\n   ") === "p(a).\n   " &&
     S.actorEnsureFinalFullStop("p(a)") === "p(a).",
     "RPC src_text terminator detection ignores trailing whitespace");

  const loadUriP = S.actorLoadUri("'https://n2.example'");
  const loadUriReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "src_uri";
  }).pop();
  ok(!!loadUriReq && loadUriReq.uri === "'https://n2.example'",
     "RPC src_uri source is delegated to the node controller");
  S.onmessage({ data: { command: "reply", id: loadUriReq.id, ok: true, result: "p(a)." } });
  ok((await loadUriP) === "p(a).", "RPC src_uri source returns to the worker");

  // Promise/yield starts the same RPC request without blocking Prolog, then
  // consumes its response through an opaque ten-digit reference.
  const promiseRef = S.actorPromiseStart("'https://n2.example'", "mortal(Who)", "mortal(Who)", 0, 10, "");
  const promiseReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "rpc";
  }).pop();
  ok(Number.isInteger(promiseRef) && String(promiseRef).length === 10 &&
     promiseRef >= 1000000000 && promiseRef <= 1073741823 &&
     promiseReq.goal === "mortal(Who)",
     "promise starts RPC and returns an opaque ten-digit reference");
  const promiseWait = S.actorPromiseWait(promiseRef, -1);
  S.onmessage({ data: { command: "reply", id: promiseReq.id, ok: true, result: "success([mortal(socrates)],false)" } });
  ok((await promiseWait) === "success([mortal(socrates)],false)",
     "yield wait consumes the promised RPC response");

  const retainedRef = S.actorPromiseStart("'https://n2.example'", "slow(X)", "slow(X)", 0, 10, "");
  const retainedReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "rpc";
  }).pop();
  ok(String(retainedRef).length === 10 && retainedRef !== promiseRef,
     "separate worker promises receive distinct ten-digit references");
  ok((await S.actorPromiseWait(retainedRef, 0)) === null,
     "timed-out yield leaves the promise pending");
  S.onmessage({ data: { command: "reply", id: retainedReq.id, ok: true, result: "success([slow(done)],false)" } });
  ok((await S.actorPromiseWait(retainedRef, -1)) === "success([slow(done)],false)",
     "a later yield consumes a previously timed-out promise");

  // 11. Statechart creation is coordinated from JS so src_uri and Worker
  // placement stay node-controller responsibilities.
  const chartP = S.actorStatechartSpawn(
    "uri", "/examples/chart.xml", "helper(ok).", "inner", "false",
    "collector", "false"
  );
  const chartReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "statechart_spawn";
  }).pop();
  ok(!!chartReq && chartReq.source === "/examples/chart.xml" &&
     chartReq.supportSource === "helper(ok)." && chartReq.name === "inner" &&
     chartReq.link === false && chartReq.ioTarget === "collector" &&
     chartReq.trace === false,
     "statechart spawn is delegated to the node controller");
  S.onmessage({ data: { command: "reply", id: chartReq.id, ok: true, result: "5500000000" } });
  ok((await chartP) === 'statechart_spawn_ok("5500000000")',
     "statechart spawn returns its Worker pid in an explicit startup result");

  const invalidChartP = S.actorStatechartSpawn(
    "text", "<statechart/>", "", "", "true", "", "true"
  );
  const invalidChartReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "statechart_spawn";
  }).pop();
  S.onmessage({ data: {
    command: "reply",
    id: invalidChartReq.id,
    ok: false,
    error: "SXML validation failed: missing version"
  } });
  ok((await invalidChartP) ===
       'statechart_spawn_error("SXML validation failed: missing version")',
     "statechart startup failures preserve their diagnostic across the Worker boundary");

  const inheritedChartP = S.actorStatechartSpawn(
    "text", "<statechart version=\"0.2\" initial=\"s\"><state id=\"s\"/></statechart>", "", "", "true", "", "true"
  );
  const inheritedChartReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "statechart_spawn";
  }).pop();
  ok(typeof inheritedChartReq.ioTarget === "string" && inheritedChartReq.ioTarget.length > 0,
     "nested statechart output defaults to its spawning actor");
  S.onmessage({ data: { command: "reply", id: inheritedChartReq.id, ok: true, result: "5600000000" } });
  await inheritedChartP;

  // 12. Deliberate terminal output from a statechart remains a Prolog term
  // for the coordinator to place in the spawning shell's actor mailbox.
  // Raw engine output continues to use the ordinary output stream.
  const Chart = loadWorker();
  Chart.onmessage({ data: {
    command: "start",
    pid: "invalid_statechart",
    role: "statechart_actor"
  } });
  Chart.actorTerminalOutput("result(shared,local)", "result(shared,local)");
  const chartOutput = Chart._posted.filter(function(m) {
    return m.type === "terminal_output";
  }).pop();
  ok(!!chartOutput && chartOutput.term === "result(shared,local)" &&
     !Object.prototype.hasOwnProperty.call(chartOutput, "output"),
     "statechart terminal output crosses the Worker boundary as a mailbox term");

  console.log(failures === 0
    ? "\nswi_wasm_actor_worker smoke: PASS"
    : "\nswi_wasm_actor_worker smoke: FAIL (" + failures + ")");
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(function(error) {
  console.error("smoke test crashed:", error);
  process.exit(1);
});
