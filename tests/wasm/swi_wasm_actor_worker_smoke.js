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
  const sendP = S.actorSend("9900000000", "msg");
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

  // 7. Requests that carry a target pid must not be overwritten by the
  // worker's own pid.  Seed selfPidText via the invalid-start path so the
  // test remains dependency-free and does not import the SWI-WASM bundle.
  S.onmessage({ data: { command: "start", pid: "invalid_actor" } });
  S.actorSpawnWithPid("4200000000", "true", "");
  const spawnReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "spawn";
  }).pop();
  ok(!!spawnReq && spawnReq.pid === "4200000000",
     "spawn request preserves target pid");

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

  // 9. A shell-role worker translates controller commands into the ptcp/3
  // mailbox protocol.  An invalid pid avoids booting the actual WASM bundle.
  S.onmessage({ data: { command: "start", pid: "invalid_shell", role: "shell_toplevel" } });
  S.onmessage({ data: { command: "shell_call", goal: "member(X,[a,b])", limit: 1 } });
  const shellCall = await S.actorReceive(-1);
  ok(shellCall.indexOf("'$call_text'") === 0 && shellCall.includes("member(X,[a,b])"),
     "shell call enters the toplevel actor mailbox");

  // 10. Worker-side rpc/2-3 uses the same controller request channel as
  // remote actor transport; the Worker does not own browser HTTP policy.
  const rpcP = S.actorRpc("'https://n1.example'", "path(a,X)", "v(X)", 0, 10, "edge(a,b).");
  const rpcReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "rpc";
  }).pop();
  ok(!!rpcReq && rpcReq.goal === "path(a,X)" && rpcReq.loadText === "edge(a,b).",
     "RPC is delegated to the node controller");
  S.onmessage({ data: { command: "reply", id: rpcReq.id, ok: true, result: "success([v(b)],false)" } });
  ok((await rpcP) === "success([v(b)],false)", "RPC response text returns to Prolog");

  // Promise/yield starts the same RPC request without blocking Prolog, then
  // consumes its response through a stable numeric reference.
  const promiseRef = S.actorPromiseStart("'https://n2.example'", "mortal(Who)", "mortal(Who)", 0, 10, "");
  const promiseReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "rpc";
  }).pop();
  ok(Number.isInteger(promiseRef) && promiseReq.goal === "mortal(Who)",
     "promise starts RPC and returns a numeric reference");
  const promiseWait = S.actorPromiseWait(promiseRef, -1);
  S.onmessage({ data: { command: "reply", id: promiseReq.id, ok: true, result: "success([mortal(socrates)],false)" } });
  ok((await promiseWait) === "success([mortal(socrates)],false)",
     "yield wait consumes the promised RPC response");

  const retainedRef = S.actorPromiseStart("'https://n2.example'", "slow(X)", "slow(X)", 0, 10, "");
  const retainedReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "rpc";
  }).pop();
  ok((await S.actorPromiseWait(retainedRef, 0)) === null,
     "timed-out yield leaves the promise pending");
  S.onmessage({ data: { command: "reply", id: retainedReq.id, ok: true, result: "success([slow(done)],false)" } });
  ok((await S.actorPromiseWait(retainedRef, -1)) === "success([slow(done)],false)",
     "a later yield consumes a previously timed-out promise");

  // 11. Statechart creation is coordinated from JS so load_uri and Worker
  // placement stay node-controller responsibilities.
  const chartP = S.actorStatechartSpawn("uri", "/examples/chart.xml", "true");
  const chartReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "statechart_spawn";
  }).pop();
  ok(!!chartReq && chartReq.source === "/examples/chart.xml" && chartReq.trace === true,
     "statechart spawn is delegated to the node controller");
  S.onmessage({ data: { command: "reply", id: chartReq.id, ok: true, result: "5500000000" } });
  ok((await chartP) === "5500000000", "statechart spawn returns its Worker pid");

  console.log(failures === 0
    ? "\nswi_wasm_actor_worker smoke: PASS"
    : "\nswi_wasm_actor_worker smoke: FAIL (" + failures + ")");
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(function(error) {
  console.error("smoke test crashed:", error);
  process.exit(1);
});
