// Semantic-contract tests for the SWI-WASM Worker runtime (web/
// swi_wasm_actor_worker.js), run against the real SWI-WASM engine
// (web/swipl-bundle.js) under Node.
//
// Each scenario boots one Worker in its own Node process with a mock
// coordinator: requests are answered at once, and every message the Worker
// sends is recorded.  The scenarios pin the decisions recorded in
// "Semantic Contracts: Decisions Before Repair" (D1-D5) for the browser
// runtime, as the tiered Prolog tests pin them for the native node.
//
// Run:  node tests/wasm/swi_wasm_contracts.js            (all scenarios)
//       node tests/wasm/swi_wasm_contracts.js <scenario> (one, verbose)

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..", "..");
const PID = "1234567890";
const QPID = PID + "@localhost";
const CLIENT = "9999999999";
const html = fs.readFileSync(path.join(ROOT, "web", "demonstrator.html"), "utf8");
const behaviourBody = html.split("swiWasmBehaviourProlog: function() {")[1].split("\n          },")[0];
const behaviourSource = Function(behaviourBody)();

// ------------------------------------------------------------------ harness

function bootWorker() {
  const posted = [];
  const sends = [];
  const control = { hold: [], held: [], reply: null };
  let S = null;
  global.self = {
    crypto: require("crypto").webcrypto,
    postMessage: function(m) {
      posted.push(m);
      if (m.type === "request") {
        if (m.action === "send") sends.push({ to: m.to, message: m.message });
        if (control.hold.includes(m.action)) { control.held.push(m); return; }
        setImmediate(function() {
          const reply = control.reply ? control.reply(m) : { result: true };
          S.onmessage({ data: Object.assign({ command: "reply", id: m.id, ok: true }, reply) });
        });
      }
    },
    close: function() { posted.push({ type: "closed" }); }
  };
  global.window = global.self;
  global.importScripts = function() {
    global.SWIPL = require(path.join(ROOT, "web", "swipl-bundle.js"));
  };
  global.fetch = async function(url) {
    const file = path.join(ROOT, "prolog", "web_prolog", String(url).replace(/^\//, ""));
    const text = fs.readFileSync(file, "utf8");
    return { ok: true, text: async function() { return text; } };
  };
  (0, eval)(fs.readFileSync(path.join(ROOT, "web", "swi_wasm_actor_worker.js"), "utf8"));
  S = global.self;
  return { S: S, posted: posted, sends: sends, control: control };
}

const sleep = function(ms) { return new Promise(function(r) { setTimeout(r, ms); }); };

async function until(pred, ms) {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > (ms || 5000)) return false;
    await sleep(10);
  }
  return true;
}

async function startToplevel(W, lifecycle) {
  W.S.onmessage({ data: {
    command: "start", pid: PID, behaviourSource: behaviourSource,
    goal: "swi_wasm_actor_bridge:ptcp(" + QPID + ", " + CLIENT + "@localhost, " + (lifecycle || "true") + ")"
  } });
  if (!await until(function() { return W.posted.some(function(m) { return m.type === "started"; }); }, 20000)) {
    throw new Error("worker did not start");
  }
  await sleep(100);
}

async function startActor(W, goal) {
  W.S.onmessage({ data: { command: "start", pid: PID, goal: goal } });
  if (!await until(function() { return W.posted.some(function(m) { return m.type === "started"; }); }, 20000)) {
    throw new Error("worker did not start");
  }
}

function deliver(W, text) { W.S.onmessage({ data: { command: "deliver", message: text } }); }
function abort(W) { W.S.onmessage({ data: { command: "abort" } }); }
function messages(W) { return W.sends.map(function(s) { return s.message; }); }
async function nSends(W, n, ms) { await until(function() { return W.sends.length >= n; }, ms || 5000); return messages(W); }
function done(W) { return W.posted.filter(function(m) { return m.type === "done"; }); }

// Deterministic coordinator stand-in for the existing worker cleanup handshake.
function installCleanupReplies(W) {
  const monitors = {};
  W.control.reply = m => {
    if (m.action === "make_ref") return {result:"8765432100"};
    if (m.action === "monitor") monitors[m.target] = m.ref;
    if (m.action === "exit") {
      const ref = monitors[m.pid];
      setImmediate(()=>deliver(W,"down("+m.pid+","+ref+",killed)"));
    }
    return {result:true};
  };
}

// ---------------------------------------------------------------- scenarios

const scenarios = {


  async rpc_short_pages(W, check) {
    const offsets = [];
    W.control.reply = m => {
      if (m.action !== "rpc") return {result:true};
      offsets.push(m.offset);
      return {result: offsets.length === 1 ? "success([v(a),v(b)],true)" : "success([v(c)],false)"};
    };
    await startToplevel(W);
    deliver(W, "'$call'(findall(X,rpc('https://example.org',p(X),[template(X),limit(5)]),Xs),[template(Xs)])");
    const m = await nSends(W, 1);
    check(/\[\[a,b,c\]\],false\)/.test(m[0] || ""), "all answers survive a short page: " + m[0]);
    check(JSON.stringify(offsets) === "[0,2]", "offset follows actual page length: " + offsets);
  },

  async promise_timeout_retry_and_callback(W, check) {
    W.control.hold = ["rpc"];
    await startToplevel(W);
    deliver(W, "'$call'((promise('https://example.org',p,Ref),assertz(user:saved_ref(Ref)),yield(Ref,R,[timeout(0)])),[template(R)])");
    const m = await nSends(W, 1);
    check(/\[timeout\],false\)/.test(m[0] || ""), "default wait answer is timeout: " + m[0]);
    deliver(W, "'$call'((user:saved_ref(Ref),yield(Ref,R,[timeout(0),on_timeout(R=custom)])),[template(R)])");
    const m2 = await nSends(W, 2);
    check(/\[custom\],false\)/.test(m2[1] || ""), "callback can bind the answer: " + m2[1]);
    deliver(W, "'$call'((user:saved_ref(Ref),catch(yield(Ref,_,[timeout(0),on_timeout(fail)]),E,true)),[template(E)])");
    const m3 = await nSends(W, 3);
    check(/timeout_callback_failed/.test(m3[2] || ""), "failing callback reports an error: " + m3[2]);
    const request = W.control.held.shift();
    W.S.onmessage({data:{command:"reply",id:request.id,ok:true,result:"success([p],false)"}});
    deliver(W, "'$call'((user:saved_ref(Ref),yield(Ref,R)),[template(R)])");
    const m4 = await nSends(W, 4);
    check(/success\(\[p\],false\)/.test(m4[3] || ""), "retry collects the original promise: " + m4[3]);
    deliver(W, "'$call'((user:saved_ref(Ref),catch(yield(Ref,_),E,true)),[template(E)])");
    const m5 = await nSends(W, 5);
    check(/existence_error\(promise,/.test(m5[4] || ""), "consumed reference is rejected: " + m5[4]);
  },

  async promise_error_answer_and_invalid_refs(W, check) {
    W.control.reply = m => m.action === "rpc" ? {ok:false,error:'network "failure"'} : {result:true};
    await startToplevel(W);
    deliver(W, "'$call'((promise('https://example.org',p,Ref),yield(Ref,R)),[template(R)])");
    const m = await nSends(W, 1);
    check(/\[error\(rpc_error\(/.test(m[0] || ""), "transport failure is an answer term: " + m[0]);
    deliver(W, "'$call'(catch(yield(42,_),E,true),[template(E)])");
    deliver(W, "'$call'(catch(yield(bogus,_),E,true),[template(E)])");
    const all = await nSends(W, 3);
    check(/existence_error\(promise,42\)/.test(all[1] || ""), "unknown reference rejected: " + all[1]);
    check(/type_error\(integer,bogus\)/.test(all[2] || ""), "noninteger reference rejected: " + all[2]);
  },

  async first_solution_reply_mismatch_consumed(W, check) {
    installCleanupReplies(W);
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,worker-wrong),(swi_wasm_actor_bridge:wait_first([worker],wanted,continue,stop)->R=unexpected;R=mismatch),receive({worker-_ -> Left=leftover},[timeout(0),on_timeout(Left=empty)])),[template(R-Left)])");
    const m = await nSends(W, 2);
    check(/\[-\(mismatch,empty\)\],false\)/.test(m[m.length-1] || ""), "reply selected and workers cleaned before output mismatch: " + m.join(" | "));
    check(W.posted.some(x=>x.action==="exit"), "cleanup requested before failure");
  },

  async server_yield_reply_mismatch_consumed(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,42-wrong),(server_yield(42,wanted)->R=unexpected;R=mismatch),receive({42-_ -> Left=leftover},[timeout(0),on_timeout(Left=empty)])),[template(R-Left)])");
    const m = await nSends(W, 2);
    check(/\[-\(mismatch,empty\)\],false\)/.test(m[m.length-1] || ""), "server reply consumed before mismatch: " + m.join(" | "));
  },

  async worker_exit_policy(W, check) {
    installCleanupReplies(W);
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,down(worker,r,killed)),catch(swi_wasm_actor_bridge:wait_first([worker],_,continue,stop),E,true)),[template(E)])");
    const m = await nSends(W, 2);
    check(/worker_exit\(worker,killed\)/.test(m[m.length-1] || ""), "unexplained first-solution exit is an error: " + m.join(" | "));
    deliver(W, "'$call'((self(S),send(S,down(worker,r,killed)),send(S,other-ok),swi_wasm_actor_bridge:wait_first([worker,other],R,continue,continue)),[template(R)])");
    const n = W.sends.length;
    await until(()=>messages(W).some(x=>/\[ok\],false\)/.test(x)));
    check(messages(W).some(x=>/\[ok\],false\)/.test(x)), "on_error(continue) accepts a later winner: " + messages(W).slice(n-1).join(" | "));
    deliver(W, "'$call'((self(S),send(S,down(worker,r,true)),catch(swi_wasm_actor_bridge:par_yield([worker],worker,_),E,true)),[template(E)])");
    await until(()=>messages(W).some(x=>/worker_exit\(worker,true\)/.test(x)));
    check(messages(W).some(x=>/worker_exit\(worker,true\)/.test(x)), "normal exit without an answer is an error");
  },

  async parallel_out_of_order_and_post_answer_exit(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,down(later,r,true)),send(S,later-[b]),send(S,first-[a]),send(S,down(first,r,killed)),swi_wasm_actor_bridge:par_yield([first,later],first,A),swi_wasm_actor_bridge:par_yield([first,later],later,B)),[template(A-B)])");
    await until(()=>messages(W).some(x=>/\[-\(\[a\],\[b\]\)\],false\)/.test(x)));
    check(messages(W).some(x=>/\[-\(\[a\],\[b\]\)\],false\)/.test(x)), "later normal down deferred; accepted result survives termination reason: " + messages(W).join(" | "));
  },

  async paging(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'(member(X,[a,b,c]),[template(X),limit(2)])");
    deliver(W, "'$next'([])");
    const m = await nSends(W, 2);
    check(m[0] === "success(@(" + PID + ",localhost),[a,b],true)", "first page, canonical text: " + m[0]);
    check(m[1] === "success(@(" + PID + ",localhost),[c],false)", "second page: " + m[1]);
  },

  async stale_next_before_call_is_discarded(W, check) {
    await startToplevel(W);
    deliver(W, "'$next'([])");
    deliver(W, "'$stop'");
    await sleep(200);
    deliver(W, "'$call'(member(X,[a,b]),[template(X),limit(1)])");
    const m = await nSends(W, 1);
    await sleep(300);
    check(messages(W).length === 1 && /\[a\],true\)$/.test(m[0]), "earlier next/stop not applied: " + messages(W).join(" | "));
  },

  async abort_in_s3_is_acknowledged(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'(member(X,[a,b,c]),[template(X),limit(1)])");
    await nSends(W, 1);
    abort(W);
    await nSends(W, 2);
    deliver(W, "'$call'(Y = ok,[template(Y)])");
    const m = await nSends(W, 3);
    check(m[1] === "abort(" + QPID + ")", "acknowledgement follows the answers: " + m[1]);
    check(/success\(.*\[ok\],false\)/.test(m[2] || ""), "toplevel accepts a new call: " + m[2]);
  },

  async abort_in_s2_is_acknowledged(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((repeat,fail),[])");
    await sleep(300);
    abort(W);
    await nSends(W, 1);
    deliver(W, "'$call'(Y = ok,[template(Y)])");
    const m = await nSends(W, 2);
    check(m[0] === "abort(" + QPID + ")", "running goal aborted and acknowledged: " + m[0]);
    check(/\[ok\],false\)/.test(m[1] || ""), "then a new call: " + m[1]);
  },

  async abort_in_s1_is_acknowledged_and_changes_nothing(W, check) {
    await startToplevel(W);
    abort(W);
    await nSends(W, 1);
    deliver(W, "'$call'(Y = ok,[template(Y)])");
    const m = await nSends(W, 2);
    check(m[0] === "abort(" + QPID + ")", "idle abort is acknowledged: " + m[0]);
    check(/\[ok\],false\)/.test(m[1] || ""), "toplevel stays idle and serves the next call: " + m[1]);
  },

  async throw_none_is_an_error(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'(throw(none),[template(x),limit(5)])");
    deliver(W, "'$call'((member(X,[1,2]), (X == 2 -> throw(none) ; true)),[template(X),limit(5)])");
    await nSends(W, 2);
    deliver(W, "'$next'([])");
    const m = await nSends(W, 3);
    check(/^error\(.*,none\)$/.test(m[0]), "throw(none) is an error, not failure: " + m[0]);
    check(/\[1\],true\)$/.test(m[1] || ""), "solution first: " + m[1]);
    check(/^error\(.*,none\)$/.test(m[2] || ""), "then the error: " + m[2]);
  },

  async abort_ends_one_shot_toplevel(W, check) {
    await startToplevel(W, "ptcp_options(false, infinite, infinite)");
    deliver(W, "'$call'((repeat,fail),[])");
    await sleep(300);
    abort(W);
    await nSends(W, 1);
    await until(function() { return done(W).length > 0; });
    check(messages(W)[0] === "abort(" + QPID + ")", "acknowledged");
    check(done(W).length === 1, "one-shot toplevel ended");
  },

  async stale_next_after_stop_is_discarded(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'(member(X,[a,b,c]),[template(X),limit(1)])");
    await nSends(W, 1);
    deliver(W, "'$stop'");
    await sleep(100);
    deliver(W, "'$next'([])");
    await sleep(100);
    deliver(W, "'$call'(member(X,[x,y]),[template(X),limit(1)])");
    const m = await nSends(W, 2);
    await sleep(300);
    check(messages(W).length === 2 && /\[x\],true\)/.test(m[1]), "stale next not applied: " + messages(W).join(" | "));
  },

  async partial_page_precedes_error(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((member(X,[1,2,bad]), Y is X+1),[template(Y),limit(5)])");
    await nSends(W, 1);
    deliver(W, "'$next'([])");
    const m = await nSends(W, 2);
    check(/\[2,3\],true\)$/.test(m[0]), "solutions first: " + m[0]);
    check(/^error\(.*type_error/.test(m[1] || ""), "then the error: " + m[1]);
  },

  async constrained_answer_is_rejected(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'(dif(X,a),[template(X)])");
    deliver(W, "'$call'((dif(X,a), X = b),[template(X)])");
    const m = await nSends(W, 2);
    check(/representation_error\(constraints\)/.test(m[0]), "constrained answer: " + m[0]);
    check(/\[b\],false\)$/.test(m[1] || ""), "bound variable is fine: " + m[1]);
  },

  async double_quotes_are_strings(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((X = \"ab\", string(X), Y = f('$VAR'(1), 'a b')),[template(X-Y)])");
    const m = await nSends(W, 1);
    check(m[0] === "success(@(" + PID + ",localhost),[-(\"ab\",f('$VAR'(1),'a b'))],false)", "strings and '$VAR' survive: " + m[0]);
  },

  async time_limit_reports_error_without_ack(W, check) {
    await startToplevel(W, "ptcp_options(true, 0.3, infinite)");
    deliver(W, "'$call'((repeat,fail),[])");
    await nSends(W, 1, 3000);
    deliver(W, "'$call'(Y = ok,[template(Y)])");
    const m = await nSends(W, 2);
    check(/resource_error\(time\)/.test(m[0]), "time error: " + m[0]);
    check(/\[ok\],false\)/.test(m[1] || ""), "no acknowledgement, new call served: " + m[1]);
  },

  async time_limit_interrupts_blocked_goal(W, check) {
    await startToplevel(W, "ptcp_options(true, 0.3, infinite)");
    deliver(W, "'$call'(receive({never -> true}),[])");
    await nSends(W, 1, 3000);
    deliver(W, "'$call'(Y = ok,[template(Y)])");
    const m = await nSends(W, 2);
    check(/resource_error\(time\)/.test(m[0]), "time error while blocked in receive: " + m[0]);
    check(/\[ok\],false\)/.test(m[1] || ""), "then a new call: " + m[1]);
  },

  async guard_error_is_a_non_match(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((self(S), S ! a, receive({M if (M == a -> throw(oops) ; true) -> R = first}, [timeout(0.2), on_timeout(R = timeout)]), receive({a -> R2 = kept})),[template(R-R2)])");
    const m = await nSends(W, 1);
    check(/\[-\(timeout,kept\)\],false\)$/.test(m[0]), "message survives a failing guard: " + m[0]);
  },

  async guard_control_exception_propagates(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((self(S), S ! a, catch(receive({M if throw('$ptcp_time_limit') -> true}), '$ptcp_time_limit', true), receive({a -> R = kept})),[template(R)])");
    const m = await nSends(W, 1);
    check(/\[kept\],false\)$/.test(m[0]), "control exception propagates, message kept: " + m[0]);
  },

  async abort_during_rpc_wait(W, check) {
    await startToplevel(W);
    W.control.hold = ["rpc"];
    deliver(W, "'$call'(rpc('https://example.org', p(X)),[template(X)])");
    check(await until(() => W.control.held.length > 0), "RPC request is pending");
    abort(W);
    await nSends(W, 1);
    deliver(W, "'$call'(Y=ok,[template(Y)])");
    const m = await nSends(W, 2);
    check(/^abort\(/.test(m[0] || "") && /\[ok\],false\)/.test(m[1] || ""), "abort cancels RPC and next call survives");
  },

  async abort_during_input_wait(W, check) {
    await startToplevel(W);
    W.control.hold = ["input"];
    deliver(W, "'$call'((P := actorInput(\"|:\"), swi_wasm_actor_bridge:actor_await(P,X)),[template(X)])");
    check(await until(() => W.control.held.length > 0), "input request is pending");
    abort(W);
    await nSends(W, 1);
    deliver(W, "'$call'(Y=ok,[template(Y)])");
    const m = await nSends(W, 2);
    check(/^abort\(/.test(m[0] || "") && /\[ok\],false\)/.test(m[1] || ""), "input cancels and next call survives");
  },

  async abort_during_send_wait(W, check) {
    await startToplevel(W);
    W.control.hold = ["send"];
    deliver(W, "'$call'(send(9999999999@localhost, payload),[])");
    check(await until(() => W.control.held.length > 0), "send request is pending");
    W.control.hold = [];
    abort(W);
    await nSends(W, 2);
    deliver(W, "'$call'(Y=ok,[template(Y)])");
    const m = await nSends(W, 3);
    check(/^abort\(/.test(m[1] || "") && /\[ok\],false\)/.test(m[2] || ""), "send wait cancels and next call survives");
  },

  async second_abort_during_acknowledgement(W, check) {
    await startToplevel(W);
    W.control.hold = ["send"];
    abort(W);
    await until(() => W.control.held.length === 1);
    abort(W);
    W.control.hold = [];
    const ack = W.control.held.shift();
    W.S.onmessage({data:{command:"reply",id:ack.id,ok:true,result:true}});
    await nSends(W, 2);
    deliver(W, "'$call'(Y=ok,[template(Y)])");
    const m = await nSends(W, 3);
    check(m.filter(x => /^abort\(/.test(x)).length === 2, "both aborts acknowledged");
    check(/\[ok\],false\)/.test(m[2] || ""), "persistent toplevel still responds");
  },

  async application_interrupt_atom_is_data(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'(receive({X -> true}),[template(X)])");
    await sleep(100);
    deliver(W, "'$wasm_interrupt'");
    const m = await nSends(W, 1);
    check(/success\(.*\['\$wasm_interrupt'\],false\)/.test(m[0] || ""), "reserved-looking atom is ordinary data: " + m[0]);
  },

  async abort_during_time_limit_report(W, check) {
    await startToplevel(W, "ptcp_options(true, 0.15, infinite)");
    W.control.hold = ["send"];
    deliver(W, "'$call'(receive({never -> true}),[])");
    check(await until(() => W.control.held.length > 0), "time limit report is pending");
    abort(W);
    W.control.hold = [];
    const report = W.control.held.shift();
    W.S.onmessage({data:{command:"reply",id:report.id,ok:true,result:true}});
    const m = await nSends(W, 2);
    check(/resource_error\(time\)/.test(m[0] || "") && /^abort\(/.test(m[1] || ""), "time report and abort acknowledgement both delivered");
  },

  async exit_first_reason_wins(W, check) {
    await startActor(W, "(catch(exit(first), _, true), exit(second))");
    await until(function() { return done(W).length > 0; });
    check(done(W).length === 1 && done(W)[0].reason === "first", "first reason: " + JSON.stringify(done(W)));
  }
};

// ------------------------------------------------------------------- runner

async function runOne(name) {
  const W = bootWorker();
  let failures = 0;
  const check = function(cond, label) {
    if (!cond) failures++;
    console.log((cond ? "  ok   " : "  FAIL ") + name + ": " + label);
  };
  await scenarios[name](W, check);
  W.sends.filter(s => /^abort\(/.test(s.message)).forEach(s =>
    check(s.to === CLIENT, "abort recipient is routable: " + s.to));
  return failures;
}

if (process.argv[2]) {
  runOne(process.argv[2]).then(function(failures) {
    process.exit(failures ? 1 : 0);
  }, function(error) {
    console.log("  FAIL " + process.argv[2] + ": " + (error && error.stack || error));
    process.exit(1);
  });
} else {
  let failed = 0;
  Object.keys(scenarios).forEach(function(name) {
    const r = spawnSync(process.execPath, [__filename, name], { encoding: "utf8", timeout: 60000 });
    const lines = (r.stdout || "").split("\n").filter(function(l) { return /^  (ok|FAIL) /.test(l); });
    lines.forEach(function(l) { console.log(l); });
    if (r.status !== 0 || lines.length === 0) {
      failed++;
      if (lines.length === 0) console.log("  FAIL " + name + ": no result" + (r.stderr ? " (" + r.stderr.trim().split("\n").pop() + ")" : ""));
    }
  });
  console.log(failed ? failed + " scenario(s) failed" : "all scenarios passed");
  process.exit(failed ? 1 : 0);
}
