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
  const sendP = S.actorSend("worker_actor(99)", "msg");
  const req = S._posted.find(function(m) { return m.type === "request" && m.action === "send"; });
  ok(!!req && req.to === "worker_actor(99)" && req.message === "msg", "send posts a request");
  S.onmessage({ data: { command: "reply", id: req.id, ok: true, result: true } });
  ok((await sendP) === true, "reply (ok) resolves the request");

  // 6. a failing reply rejects the request promise
  const sendP2 = S.actorSend("worker_actor(98)", "m2");
  const req2 = S._posted.filter(function(m) { return m.type === "request"; }).pop();
  let rejected = false;
  S.onmessage({ data: { command: "reply", id: req2.id, ok: false, error: "no such actor" } });
  try { await sendP2; } catch (_e) { rejected = true; }
  ok(rejected, "reply (not ok) rejects the request");

  // 7. Requests that carry a target pid must not be overwritten by the
  // worker's own pid.  Seed selfPidText via the invalid-start path so the
  // test remains dependency-free and does not import the SWI-WASM bundle.
  S.onmessage({ data: { command: "start", pid: "invalid_actor" } });
  S.actorSpawnWithPid("worker_actor(42)", "true", "");
  const spawnReq = S._posted.filter(function(m) {
    return m.type === "request" && m.action === "spawn";
  }).pop();
  ok(!!spawnReq && spawnReq.pid === "worker_actor(42)",
     "spawn request preserves target pid");

  console.log(failures === 0
    ? "\nswi_wasm_actor_worker smoke: PASS"
    : "\nswi_wasm_actor_worker smoke: FAIL (" + failures + ")");
  process.exit(failures === 0 ? 0 : 1);
}

main().catch(function(error) {
  console.error("smoke test crashed:", error);
  process.exit(1);
});
