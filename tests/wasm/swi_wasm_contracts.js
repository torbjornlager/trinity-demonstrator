// Semantic-contract tests for the SWI-WASM Worker runtime (web/
// swi_wasm_actor_worker.js), run against the real SWI-WASM engine
// (web/swipl-bundle.js) under Node.
//
// Each scenario runs in its own Node process. Worker scenarios boot a mock
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
      if (m.type !== "request" && control.event) control.event(m);
      if (m.type === "server_monitor_cleanup" && control.cleanup) control.cleanup(m);
      if (m.type === "request") {
        if (m.action === "send") sends.push({ to: m.to, message: m.message });
        if (control.request) { control.request(m); return; }
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


function workbenchMethod(name, next) {
  const start = html.indexOf("          " + name + ": function") + ("          " + name + ": ").length;
  const tail = html.slice(start);
  const boundary = new RegExp("\\n[ \\t]+" + next + ": function").exec(tail);
  const chunk=tail.slice(0,boundary.index);
  const closing="\n          }";
  const end=chunk.lastIndexOf(closing+",");
  return Function("return (" + chunk.slice(0,end+closing.length) + ")")();
}

// Use the real coordinator's monitor table/removal/barrier, with only transport mocked.
function serverMonitorCoordinator(deliverMessage) {
  return {
    swiWasmActorMonitors: [], swiWasmActorWorkers: {}, cleaned: [],
    resolveSwiWasmActorTarget: x => String(x),
    swiWasmActorPidLive: () => true,
    parseSwiWasmRemoteActorPid: () => null,
    parseSwiWasmRemoteToplevelPid: () => null,
    monitorSwiWasmActor: workbenchMethod("monitorSwiWasmActor", "demonitorSwiWasmActor"),
    demonitorSwiWasmActor: workbenchMethod("demonitorSwiWasmActor", "cleanupSwiWasmServerMonitor"),
    cleanupSwiWasmServerMonitor: workbenchMethod("cleanupSwiWasmServerMonitor", "notifySwiWasmActorMonitors"),
    sendSwiWasmActorMessage(watcher, text) { deliverMessage(text); return true; }
  };
}

function installServerMonitorCoordinator(W) {
  const host = serverMonitorCoordinator(text => deliver(W, text));
  host.swiWasmActorWorkers[PID]={};
  const handleWorkerMessage=workbenchMethod("handleSwiWasmWorkerActorMessage","handleSwiWasmActorRequest");
  let nextRef = 8765432100;
  W.control.reply = m => {
    if (m.action === "make_ref") return {result:String(nextRef++)};
    if (m.action === "monitor") {
      const result=host.monitorSwiWasmActor(PID,m.target,m.ref);
      return W.control.monitorError ? {ok:false,error:W.control.monitorError} : {result:result};
    }
    if (m.action === "send" && m.to === "server" && W.control.sendError) return {ok:false,error:W.control.sendError};
    if (m.action === "send" && m.to === "server" && W.control.serverReply) {
      const ref=/,(\d{10}),request\)$/.exec(m.message)[1];
      deliver(W,ref+"-ok");
    }
    return {result:true};
  };
  W.control.cleanup = m => {
    host.cleaned.push(m.ref);
    // Simulate notifications already posted on the coordinator/worker channel.
    deliver(W,"down(server,"+m.ref+",queued)");
    handleWorkerMessage.call(host,PID,{data:m});
  };
  return host;
}


// The parent and children all run the real WASM runtime. Only browser Worker
// plumbing is adapted to Node worker_threads; coordinator methods are unmodified.
function scopedWorkerCoordinator(W, owner = PID) {
  const {Worker: NodeWorker} = require("worker_threads");
  const threads=new Set();
  const host=serverMonitorCoordinator(text=>deliver(W,text));
  host.options={}; host.created=[]; host.killed=[]; host.calls=0;
  global.qualifySwiWasmLocalPid = text => /^\d+$/.test(String(text)) ? text+"@localhost" : String(text);
  global.sanitizeDownReasonTerm = text => String(text);
  global.Worker=class {
    constructor() {
      const script=`
        const fs=require('fs'),path=require('path'),{parentPort}=require('worker_threads');
        const root=${JSON.stringify(ROOT)};
        global.self={postMessage:m=>parentPort.postMessage(m),close:()=>process.exit(0),crypto:require('crypto').webcrypto};
        global.window=global.self;
        global.importScripts=()=>{global.SWIPL=require(path.join(root,'web/swipl-bundle.js'));};
        global.fetch=async url=>({ok:true,text:async()=>fs.readFileSync(path.join(root,'prolog/web_prolog',String(url).replace(/^\\//,'')),'utf8')});
        (0,eval)(fs.readFileSync(path.join(root,'web/swi_wasm_actor_worker.js'),'utf8'));
        parentPort.on('message',data=>global.self.onmessage({data}));
      `;
      this.thread=new NodeWorker(script,{eval:true}); threads.add(this);
      this.thread.on('message',m=>{
        if (host.options.holdReady && m.type==="ready") { host.heldReady=m; return; }
        if(this.onmessage) this.onmessage({data:m});
      });
      this.thread.on('error',e=>{if(this.onerror)this.onerror(e);});
    }
    postMessage(m) { this.thread.postMessage(m); }
    terminate() { threads.delete(this); return this.thread.terminate(); }
  };
  const methods={
    swiWasmWorkerScopeKey:"openSwiWasmWorkerScope", openSwiWasmWorkerScope:"reserveSwiWasmScopedWorker",
    reserveSwiWasmScopedWorker:"spawnSwiWasmScopedWorker",spawnSwiWasmScopedWorker:"releaseSwiWasmScopedWorker",
    releaseSwiWasmScopedWorker:"closeSwiWasmWorkerScopes",closeSwiWasmWorkerScopes:"closeSwiWasmWorkerScope",closeSwiWasmWorkerScope:"spawnSwiWasmWorkerActor",
    spawnSwiWasmWorkerActor:"spawnSwiWasmWorkerActorReady",spawnSwiWasmWorkerActorReady:"swiWasmRemoteNodeUrl",
    handleSwiWasmWorkerActorMessage:"handleSwiWasmActorRequest",handleSwiWasmActorRequest:"requestSwiWasmActorInput",
    notifySwiWasmActorMonitors:"deliverSwiWasmActorDown",deliverSwiWasmActorDown:"clearSwiWasmActorNamesForPid",
    clearSwiWasmActorNamesForPid:"terminateLinkedSwiWasmChildren",terminateLinkedSwiWasmChildren:"exitSwiWasmActor",
    exitSwiWasmActor:"abortSwiWasmActor",finalizeSwiWasmWorkerActor:"receiveSwiWasmActorMessage",
    swiWasmActorListText:"sendSwiWasmActorMessage",
    swiWasmActorPidLive:"takeSwiWasmRemoteMonitor"
  };
  for(const [name,next] of Object.entries(methods))host[name]=workbenchMethod(name,next);
  host.swiWasmReservedWorkerActorPids={};host.swiWasmActorNames={};host.swiWasmActorServices={};
  host.swiWasmBehaviourProlog=()=>behaviourSource;
  host.resolveSwiWasmActorTarget=text=>String(text).replace(/^@\((\d+),\s*localhost\)$/, '$1').replace(/@localhost$/,'');
  let nextPid=7000000000;
  host.reserveSwiWasmWorkerActorPid=()=>{const pid=String(nextPid++);host.swiWasmReservedWorkerActorPids[pid]=true;return pid;};
  host.log=()=>{};host.logSwiWasmWorkerTraffic=()=>{};
  host.swiWasmActorWorkers[owner]={worker:{postMessage:data=>{
    if (host.options.holdReservation && data.id===host.reservingRequest) {host.heldReservation=data;return;}
    W.S.onmessage({data});
  }},ready:true,done:false};
  host.sendSwiWasmActorMessage=function(to,text) {
    to=this.resolveSwiWasmActorTarget(to);
    if(to===owner)deliver(W,text);
    else if(to!==CLIENT && this.swiWasmActorWorkers[to] && !this.swiWasmActorWorkers[to].done)this.swiWasmActorWorkers[to].worker.postMessage({command:"deliver",message:text});
    return true;
  };
  const spawn=host.spawnSwiWasmWorkerActorReady;
  host.spawnSwiWasmWorkerActorReady=function(...args) {
    const pending=spawn.apply(this,args);this.created.push(args[2]);this.calls++;
    if(this.options.extraAt===this.calls){
      this.extraPid=args[2];this.extraRef=String(8999999900+this.calls);
      this.monitorSwiWasmActor(owner,args[2],this.extraRef);
    }
    if(this.options.failAt===this.calls){pending.catch(()=>{});throw new Error("startup_original");}
    return pending;
  };
  const exit=host.exitSwiWasmActor;
  host.exitSwiWasmActor=function(pid,reason){this.killed.push(String(pid));return exit.call(this,pid,reason);};
  W.control.request=m=>{
    if(m.action==="worker_scope_reserve")host.reservingRequest=m.id;
    host.handleSwiWasmActorRequest(owner,m);
  };
  W.control.event=m=>host.handleSwiWasmWorkerActorMessage(owner,{data:m});
  W.S.workerTestError=e=>e.message;
  host.live=()=>Object.keys(host.swiWasmActorWorkers).filter(p=>p!==owner&&!host.swiWasmActorWorkers[p].done);
  host.scopeCount=()=>Object.keys(host.swiWasmWorkerScopes||{}).length;
  host.stop=async()=>{await Promise.all([...threads].map(w=>w.terminate()));};
  return host;
}



function spawnOptionCases(main=false) {
  const cases=[
    ["_","instantiation_error"], ["[unknown(1)]","domain_error(spawn_option,unknown(1))"],
    ["[link(true)|_]","instantiation_error"], ["[link(true)|bad]","type_error(list,_)"],
    ["[_]","instantiation_error"], ["[link]","domain_error(spawn_option,link)"],
    ["[link(true,false)]","domain_error(spawn_option,link(true,false))"],
    ["[link(_)]","instantiation_error"], ["[link(maybe)]","type_error(boolean,maybe)"],
    ["[link(true),link(0)]","type_error(boolean,0)"], ["[monitor(_)]","instantiation_error"],
    ["[monitor(1)]","type_error(boolean,1)"], ["[node(_)]","instantiation_error"],
    ["[node(42)]","type_error(atom_or_string,42)"], ["[name(_)]","instantiation_error"],
    ["[name(compound(x))]","type_error(atom,compound(x))"],
    ["[target(_)]","instantiation_error"], ["[io_target(_)]","instantiation_error"],
    ["[src_text(p(a))]","type_error(atom_or_string,p(a))"],
    ["[src_text([112,46])]","type_error(atom_or_string,[112,46])"],
    ["[src_list(bad)]","type_error(list,bad)"], ["[src_list([p|_])]","instantiation_error"],
    ["[src_predicates([p])]","type_error(predicate_indicator,p)"],
    ["[src_predicates([p/(-1)])]","type_error(nonneg,-1)"],
    ["[src_predicates([P/1])]","instantiation_error"],
    ["[strategy(one_for_one)]","domain_error(spawn_option,strategy(one_for_one))"],
    ["[initial_state([])]","domain_error(spawn_option,initial_state([]))"],
    ["[start(true)]","domain_error(spawn_option,start(true))"],
    ["[monitor_ref(42)]","domain_error(spawn_option,monitor_ref(42))"],
    ["[src_text('fact(ok).'),unknown(1)]","domain_error(spawn_option,unknown(1))"]
  ];
  if(main)cases.push(["[src_uri(_)]","instantiation_error"], ["[src_uri(42)]","type_error(atom_or_string,42)"],
    ["[src_uri('https://example.org/source.pl'),unknown(1)]","domain_error(spawn_option,unknown(1))"]);
  else cases.push(["[src_uri('https://example.org/source.pl')]","domain_error(spawn_option,src_uri('https://example.org/source.pl'))"]);
  // Validate the whole list even when a remote dispatch is selected.
  return cases.concat(cases.slice(1).map(([opts,err])=>["[node('https://example.org')|"+opts+"]",err]));
}
function invalidSpawnGoal([options,error]) {
  return "(Opts="+options+",term_variables(Opts,Vars),catch((spawn(true,Pid,Opts),State=accepted),error(Formal,context(spawn/3,_)),State=rejected),State==rejected,nonvar(Formal),Formal="+error+",var(Pid),maplist(var,Vars))";
}
// Mock transport only: the public predicates, option extraction and serializers
// execute in a real WASM engine. Each successful startup supplies a fresh pid.
function spawnOptionWorkerReplies(W) {
  let next=7100000000;
  W.control.reply=m=>{
    if(m.action==="reserve_pid")return {result:String(next++)};
    if(m.action==="spawn"){
      if(m.goal.includes("wasm_supervisor_init"))deliver(W,"'$supervisor_ready'("+m.pid+"@localhost)");
      return {result:m.pid};
    }
    if(m.action==="remote_spawn")return {result:"8800000000@'https://example.org'"};
    if(m.action==="make_ref")return {result:"8900000000"};
    return {result:true};
  };
}
function spawnOptionMainHarness() {
  const calls=[];let next=7200000000;const mailbox=[];
  function record(action,args,result){calls.push({action,args});return result;}
  Object.assign(global.self,{
    swiWasmActorReservePid:()=>record("reserve",[],String(next++)),
    swiWasmActorSpawnWithPid:(...args)=>{
      if(args[1].includes("wasm_supervisor_init"))mailbox.push("'$supervisor_ready'("+args[0]+"@localhost)");
      return Promise.resolve(record("spawn",args,args[0]));
    },
    swiWasmActorRemoteSpawn:(...args)=>Promise.resolve(record("remote",args,"8800000000@'https://example.org'")),
    swiWasmActorMonitor:(...args)=>Promise.resolve(record("monitor",args,true)),
    swiWasmActorRegister:(...args)=>record("register",args,true),
    swiWasmActorMakeRef:()=>"8900000000",
    swiWasmBehaviourSource:()=>behaviourSource,
    swiWasmLoadUriSource:(...args)=>Promise.resolve(record("source",args,"uri_fact(ok).")),
    swiWasmActorReceive:()=>Promise.resolve(mailbox.shift()||null)
  });
  return calls;
}
const validSpawnOptions="[name(first),name(second),link(false),link(true),monitor(true),monitor(false),target(route(T)),io_target(route(T)),src_text('first(a).'),src_text(\"second(b).\"),src_list([list_fact(ok)]),src_predicates([spawn_fact/1])]";
const wrapperSetup="assertz(user:spawn_callback(_,S,ok,S)),";



// Run the same child-specification contract against both real WASM engines.
const invalidChildSpecs = [
  ["_", "instantiation_error"],
  ["[child(a,[start(true)])|bad]", "type_error(list,_)"],
  ["[_]", "instantiation_error"],
  ["[child(a,[start(true)])|_]", "instantiation_error"],
  ["[child(a,[start(true)|_])]", "instantiation_error"],
  ["[child(a,[start(true),_])]", "instantiation_error"],
  ["[child(a,[start(true),restart(_)])]", "instantiation_error"],
  ["[child(a,[start(true),start(true,false)])]", "domain_error(spawn_option,start(true,false))"],
  ["[wrong(a)]", "type_error(supervisor_child_spec,_)"],
  ["[child(_,[start(true)])]", "instantiation_error"],
  ["[child(42,[start(true)])]", "type_error(atom,42)"],
  ["[child(a,_)]", "instantiation_error"],
  ["[child(a,[start(true)|bad])]", "type_error(list,_)"],
  ["[child(a,[])]", "missing_start_option(a)"],
  ["[child(a,[start(_)])]", "instantiation_error"],
  ["[child(a,[start(42)])]", "type_error(callable,42)"],
  ["[child(a,[start(_:true)])]", "instantiation_error"],
  ["[child(a,[start(true),start(42)])]", "type_error(callable,42)"],
  ["[child(a,[start(true),restart(sometimes)])]", "type_error(oneof(_),sometimes)"],
  ["[child(a,[start(true),type(other)])]", "type_error(oneof(_),other)"],
  ["[child(a,[start(true),shutdown(-1)])]", "domain_error(supervisor_child_shutdown,-1)"],
  ["[child(a,[start(true),significant(maybe)])]", "type_error(boolean,maybe)"],
  ["[child(a,[start(true),unknown(1)])]", "domain_error(spawn_option,unknown(1))"],
  ["[child(a,[start(true),monitor(maybe)])]", "type_error(boolean,maybe)"],
  ["[child(a,[start(true)]),child(a,[start(true)])]", "permission_error(duplicate,supervisor_child_id,a)"],
  ["[child(a,[start(server(_,[]))])]", "instantiation_error"],
  ["[child(a,[start(server(cb,[initial_state(_),unknown(1)]))])]", "domain_error(spawn_option,unknown(1))"],
  ["[child(a,[start(start_sub_supervisor([child(b,[])],[]))])]", "missing_start_option(b)"],
  ["[child(a,[start(start_sub_supervisor([],[period(0)]))])]", "domain_error(supervisor_period,0)"],
  ["[child(a,[start(true)]),child(b,[])]", "missing_start_option(b)"]
];
async function childSpecContract(run, check, sideEffects, main) {
  for(const [spec,error] of invalidChildSpecs) {
    const goal="Specs="+spec+",catch((supervisor_spawn(Specs,Pid),fail),error("+error+",context(supervisor_spawn/3,_)),Caught=true),Caught==true,var(Pid)";
    check(await run(goal),"rejects initial specs "+spec);
  }
  const dynamic="catch((supervisor_spawn_child(sup,child(a,[]),Reply),fail),error(missing_start_option(a),context(supervisor_spawn_child/3,_)),Caught=true),Caught==true,var(Reply)";
  check(await run(dynamic),"invalid dynamic API request rejected before send");
  check(await run("Specs=[child(a,[start(true)])|Specs],catch((supervisor_spawn(Specs,_),fail),error(representation_error(cyclic_term),_),Caught=true),Caught==true"),"cyclic initial list rejected");
  check(await run("Specs=[child(a,[start(start_sub_supervisor(Specs,[]))])],catch((supervisor_spawn(Specs,_),fail),error(representation_error(cyclic_term),_),Caught=true),Caught==true"),"recursive child specification rejected");
  check(sideEffects()===0,"all invalid initial/dynamic specs rejected before any transport or startup");
  const b="swi_wasm_actor_bridge:";
  check(await run("S=sup(one_for_one,1,5,[],[]),"+b+"wasm_handle_supervisor_call(start_child(child(a,[])),error(error(missing_start_option(a),_)),S,After),After==S,"+b+"wasm_handle_supervisor_call(count_children,counts(0,0),After,After)"),"malformed receiver request leaves supervisor responsive and unchanged");
  check(await run("S=sup(one_for_one,1,5,[child(a,pid,child(a,[start(true)]))],[]),"+b+"wasm_handle_supervisor_call(start_child(child(a,[start(true)])),error(already_present),S,After),After==S"),"duplicate dynamic ID rejected without spawning");
  check(sideEffects()===0,"receiver validation and duplicates have no startup side effects");
  const valid="Specs=[child(a,[start(goal(X)),start(other(X)),restart(temporary),restart(permanent),shutdown(0.25),type(worker),significant(false),src_list([fact(X)])]),child(b,[start(server(cb,[initial_state(X),initial_state(other),name(first),name(second)]))]),child(c,[start(start_sub_supervisor([child(n,[start(goal(X))])],[strategy(rest_for_one),intensity(0),period(0.25)])),type(supervisor),shutdown(infinity)]),child(d,[start(true),shutdown(brutal_kill)])]";
  check(await run(valid+",copy_term(Specs,Before),"+b+"browser_validate_child_specs(Specs,supervisor_spawn/3),Specs =@= Before,var(X),Specs=[child(_,[start(goal(A)),start(other(B))|_]),child(_,[start(server(_,[initial_state(C)|_]))])|_],A==X,B==X,C==X"),"nested goals, metadata, duplicate settings and shared arbitrary state remain unchanged");
  check(await run("supervisor_spawn([child(a,[start(goal(X))])],_,[]),var(X)"),"valid initial startup preserves defaults and goal variables");
  check(await run(b+"browser_validate_child_specs([child(a,[start(true)]),child(b,[start(start_sub_supervisor([child(a,[start(true)])],[]))])],supervisor_spawn/3)"),"duplicate IDs in different supervisor lists are allowed");
  check(await run(b+"wasm_child_start(server(cb,[initial_state(X),initial_state(other),name(first)]),a,[name(child_name),src_list([fact(X)])],_),var(X)"),"server special form keeps arbitrary initial state and forwarded source sharing");
  check(await run(b+"wasm_child_start(start_sub_supervisor([],[strategy(rest_for_one),strategy(one_for_all),intensity(0),period(0.25)]),nested,[],_)"),"nested supervisor creation retains option precedence");
  check(await run("Original=child(plain,[start(goal(X)),start(other(X)),restart(temporary),shutdown(5),type(worker),significant(false),monitor(false)]),"+b+"wasm_handle_supervisor_call(start_child(Original),ok,sup(one_for_one,1,5,[],[]),sup(one_for_one,1,5,[child(plain,_,Saved)],[])),Saved==Original,var(X)"),"valid dynamic child retains original shared specification");
  // URI capability remains a runtime difference even inside nested specs.
  const uriSpec="[child(a,[start(server(cb,[src_uri('https://example.org/support.pl')]))])]";
  const uriGoal=main?b+"browser_validate_child_specs("+uriSpec+",supervisor_spawn/3)":
    "catch(("+b+"browser_validate_child_specs("+uriSpec+",supervisor_spawn/3),fail),error(domain_error(spawn_option,src_uri(_)),_),Caught=true),Caught==true";
  check(await run(uriGoal),"nested source options retain runtime URI capability");
}


// Exercise the actual supervisor down handler and spawn path in each engine;
// only coordinator startup/monitoring is mocked. Do not pin deferred ordering
// or inactive-child bookkeeping behavior in these policy tests.
async function supervisorRestartPolicyContract(run, spawnCount, check) {
  const reasons=["true","false","exception(test_error)","killed","shutdown"];
  for(const policy of ["transient","permanent","temporary"]) {
    for(const reason of reasons) {
      const restart=policy==="permanent"||(policy==="transient"&&reason!=="true");
      const before=spawnCount();
      const expected=restart?
        "State=sup(one_for_one,10,5,Children,[_]),memberchk(child(policy_child,NewPid,Saved),Children),nonvar(NewPid),Saved==Spec":
        "State=sup(one_for_one,10,5,_,[])";
      const goal="Spec=child(policy_child,[start(receive({stop->true})),restart("+policy+")]),"+
        "swi_wasm_actor_bridge:wasm_handle_down(7000000000,"+reason+",sup(one_for_one,10,5,[child(policy_child,7000000000,Spec)],[]),State),"+expected;
      check(await run(goal),policy+" / "+reason+" preserves the expected restart record");
      check(spawnCount()-before===(restart?1:0),policy+" / "+reason+(restart?" starts one replacement":" starts no replacement"));
    }
  }
}

const wrapperKinds={toplevel:"toplevel_spawn/2",server:"server_spawn/4",supervisor:"supervisor_spawn/3",statechart:"statechart_spawn/2"};
function wrapperCall(kind, opts="Opts") {
  return {toplevel:"toplevel_spawn(Pid,"+opts+")", server:"server_spawn(spawn_callback,State,Pid,"+opts+")",
    supervisor:"supervisor_spawn([],Pid,"+opts+")",statechart:"statechart_spawn(Pid,"+opts+")"}[kind];
}
function wrapperOptionCases(kind, main=false) {
  let cases=spawnOptionCases(main).filter(([opts])=>!(kind==="server"&&opts.includes("initial_state("))&&
    !(kind==="supervisor"&&opts.includes("strategy("))&&!(kind==="statechart"&&opts.includes("src_uri(")));
  const specific={
    toplevel:[["[session(_)]","instantiation_error"],["[session(maybe)]","type_error(boolean,maybe)"],
      ["[session(true),session(1)]","type_error(boolean,1)"],
      ["[time_limit(_)]","instantiation_error"],["[time_limit(0)]","domain_error(time_limit,0)"],
      ["[time_limit(1),time_limit(-1)]","domain_error(time_limit,-1)"],
      ["[idle_limit(_)]","instantiation_error"],["[idle_limit(0)]","domain_error(idle_limit,0)"],
      ["[idle_limit(fast)]","type_error(number,fast)"],["[trace(true)]","domain_error(spawn_option,trace(true))"]],
    server:[["[session(true)]","domain_error(spawn_option,session(true))"],
      ["[initial_state(a,b)]","domain_error(spawn_option,initial_state(a,b))"]],
    supervisor:[["[strategy(_)]","instantiation_error"],["[strategy(random)]","domain_error(supervisor_strategy,random)"],
      ["[strategy(one_for_one),strategy(random)]","domain_error(supervisor_strategy,random)"],
      ["[intensity(_)]","instantiation_error"],["[intensity(-1)]","type_error(nonneg,-1)"],
      ["[intensity(1.5)]","type_error(nonneg,1.5)"],["[period(_)]","instantiation_error"],
      ["[period(0)]","domain_error(supervisor_period,0)"],["[period(fast)]","type_error(number,fast)"],
      ["[period(0.5),period(-1)]","domain_error(supervisor_period,-1)"]],
    statechart:[["[trace(_)]","instantiation_error"],["[trace(maybe)]","type_error(boolean,maybe)"],
      ["[trace(true),trace(1)]","type_error(boolean,1)"],["[src_uri(_)]","instantiation_error"],
      ["[src_uri(42)]","type_error(atom_or_string,42)"],
      ["[src_uri('https://example.org/chart.xml'),unknown(1)]","domain_error(spawn_option,unknown(1))"],
      ["[src_text('<invalid/>'),trace(maybe)]","type_error(boolean,maybe)"],
      ["[src_text('<invalid/>'),src_text(42)]","type_error(atom_or_string,42)"]]
  }[kind];
  return cases.concat(specific,specific.map(([opts,err])=>["[node('https://example.org')|"+opts+"]",err]));
}
function invalidWrapperGoal(kind,[options,error]) {
  return "(Opts="+options+",term_variables(Opts,Vars),catch(("+wrapperCall(kind)+",Status=accepted),error(Formal,context("+wrapperKinds[kind]+",_)),Status=rejected),Status==rejected,nonvar(Formal),Formal="+error+",var(Pid),var(State),maplist(var,Vars))";
}
const simpleChart='<statechart version="0.2" initial="s"><state id="s"/></statechart>';
function wrapperWorkerReplies(W) {
  spawnOptionWorkerReplies(W);const previous=W.control.reply;
  W.control.reply=m=>{
    if(m.action==="remote_toplevel_spawn")return {result:"8800000000@'https://example.org'"};
    if(m.action==="statechart_spawn")return {result:"7300000000@localhost"};
    return previous(m);
  };
}
async function loadCompatibilityStatecharts(engine) {
  engine.FS.mkdir("/wasm");
  for(const name of ["sxml_schema.pl","statechart_wasm_runtime.pl","statechart_wasm_model.pl","statechart_wasm_exec.pl","statechart_wasm.pl"])
    engine.FS.writeFile("/wasm/"+name,fs.readFileSync(path.join(ROOT,"prolog/web_prolog/wasm",name),"utf8"));
  return !!engine.prolog.query("use_module('/wasm/statechart_wasm.pl')").once();
}

function clientOptionCases() {
  const cases=[];
  for(const kind of ["rpc","promise","yield"]){
    const common=[
      ["_","instantiation_error"], ["[unknown(1)]","domain_error("+kind+"_option,unknown(1))"],
      ["[timeout(0)|_]","instantiation_error"], ["[timeout(0)|bad]","type_error(list,_)"],
      ["[_]","instantiation_error"], ["[timeout]","domain_error("+kind+"_option,timeout)"],
      ["[timeout(1,2)]","domain_error("+kind+"_option,timeout(1,2))"],
      ["[timeout(_)]","instantiation_error"], ["[timeout(fast)]","type_error(number,fast)"]
    ];
    for(const [options,error] of common)cases.push({kind,options,error});
    if(kind!=="yield")for(const [options,error] of [
      ["[limit(0)]","type_error(positive_integer,0)"], ["[limit(1.5)]","type_error(positive_integer,1.5)"],
      ["[limit(2),limit(0)]","type_error(positive_integer,0)"], ["[limit(_)]","instantiation_error"],
      ["[once(maybe)]","domain_error(boolean,maybe)"], ["[once(_)]","instantiation_error"],
      ["[http_timeout(fast)]","type_error(number,fast)"], ["[http_timeout(_)]","instantiation_error"],
      ["[src_text(p(a))]","type_error(atom_or_string,p(a))"],
      ["[src_text([112,46])]","type_error(atom_or_string,[112,46])"],
      ["[src_uri(42)]","type_error(atom_or_string,42)"], ["[src_uri(_)]","instantiation_error"],
      ["[src_list(bad)]","type_error(list,bad)"], ["[src_list([p|_])]","instantiation_error"],
      ["[src_predicates([p])]","type_error(predicate_indicator,p)"],
      ["[src_predicates([p/(-1)])]","type_error(nonneg,-1)"],
      ["[src_predicates([P/1])]","instantiation_error"],
      ["[authorization(bearer(token))]","domain_error("+kind+"_option,authorization(bearer(token)))"],
      ["[request_header('X-Test'=value)]","domain_error("+kind+"_option,request_header('X-Test'=value))"],
      ["[user_agent(test)]","domain_error("+kind+"_option,user_agent(test))"],
      ["[src_uri('https://example.org/source.pl'),unknown(1)]","domain_error("+kind+"_option,unknown(1))"]
    ])cases.push({kind,options,error});
  }
  cases.push(
    {kind:"rpc",options:"[template(_)]",error:"domain_error(rpc_option,template(_))"},
    {kind:"rpc",options:"[offset(1)]",error:"domain_error(rpc_option,offset(1))"},
    {kind:"promise",options:"[offset(-1)]",error:"type_error(nonneg,-1)"},
    {kind:"promise",options:"[offset(1.5)]",error:"type_error(nonneg,1.5)"},
    {kind:"promise",options:"[offset(_)]",error:"instantiation_error"},
    {kind:"yield",options:"[on_timeout(42)]",error:"type_error(callable,42)"},
    {kind:"yield",options:"[on_timeout(_)]",error:"instantiation_error"},
    {kind:"yield",options:"[once(true)]",error:"domain_error(yield_option,once(true))"},
    {kind:"yield",options:"[timeout(none)]",error:"type_error(number,none)"}
  );
  return cases;
}
function invalidClientGoal(c) {
  const pi=c.kind==="promise" ? "promise/4" : c.kind+"/3";
  const call=c.kind==="yield" ? "yield(42,_,Opts)" : c.kind+"('https://example.org',p"+(c.kind==="promise"?",_":"")+",Opts)";
  return "(Opts="+c.options+",term_variables(Opts,Vars),catch(("+call+",State=accepted),error(Formal,context("+pi+",_)),State=rejected),State==rejected,nonvar(Formal),Formal="+c.error+",maplist(var,Vars))";
}
function compatibilityClientHarness() {
  const calls={rpc:[],source:[],promise:[],wait:0};
  const host={next:1234500000,makeBrowserPromiseRef:()=>String(host.next++)};
  global.self.encodeURIComponent=encodeURIComponent;
  global.self.swiResolveRpcBase=()=>"https://example.org";
  global.self.swiResolveRpcLoadUri=uri=>String(uri);
  global.self.swiEnsureFinalFullStop=text=>String(text).replace(/\.?$/,'.');
  global.self.swiRpcGet=url=>{calls.source.push(url);return "uri_fact(ok).";};
  global.self.swiRpcGetAsync=url=>{calls.rpc.push(url);return Promise.resolve("success([v(ok)],false)");};
  global.self._swiPromiseStore={items:{}};
  const text=html.slice(html.indexOf("            window.swiPromiseStart = function"),html.indexOf('            var el = document.createElement("script");',html.indexOf("            window.swiPromiseStart = function")));
  const fetchMock=(url,options)=>{
    calls.promise.push({url,options});
    if(calls.hold)return new Promise(resolve=>{calls.complete=()=>resolve({text:()=>Promise.resolve("success([done],false)")});});
    return Promise.resolve({text:()=>Promise.resolve("success([-(ok,ok)],false)")});
  };
  Function("self","window","fetch",text)(host,global.self,fetchMock);
  const wait=global.self.swiPromiseWait;
  global.self.swiPromiseWait=(...args)=>{calls.wait++;return wait(...args);};
  return calls;
}

// ---------------------------------------------------------------- scenarios

const scenarios = {












  async supervisor_restart_policy(W, check) {
    wrapperWorkerReplies(W);await startToplevel(W);
    async function run(goal){const n=W.sends.length;deliver(W,"'$call'(("+goal+"->R=checked;R=wrong),[template(R)])");const m=await nSends(W,n+1);return /\[checked\],false\)/.test(m[n]||"");}
    await supervisorRestartPolicyContract(run,()=>W.posted.filter(m=>m.type==="request"&&m.action==="spawn").length,check);
  },
  async compatibility_supervisor_restart_policy(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_restart_policy.pl",source);
    check(!!engine.prolog.query("use_module('/compat_restart_policy.pl')").once(),"main supervisor policy engine loaded");
    const calls=spawnOptionMainHarness();
    async function run(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
    await supervisorRestartPolicyContract(run,()=>calls.filter(m=>m.action==="spawn").length,check);
  },

  async child_spec_supervisor_loop(W, check) {
    await startToplevel(W);
    deliver(W,"'$call'((swi_wasm_actor_bridge:wasm_supervisor_loop(sup(one_for_one,1,5,[],[])),R=stopped),[template(R)])");
    deliver(W,"'$sup'("+CLIENT+"@localhost,901,start_child(child(a,[])))");
    deliver(W,"'$sup'("+CLIENT+"@localhost,902,start_child(child(a,[start(start_sub_supervisor([child(b,[])],[]))])))");
    deliver(W,"'$sup'("+CLIENT+"@localhost,903,count_children)");
    deliver(W,"'$sup_stop'("+CLIENT+"@localhost)");
    const m=await nSends(W,5);
    check(m.some(x=>/^-\(901,error\(error\(missing_start_option\(a\)/.test(x)),"malformed request delivers a validation error: "+JSON.stringify(m));
    check(m.some(x=>/^-\(902,error\(error\(missing_start_option\(b\)/.test(x)),"nested invalid request delivers a validation error");
    check(m.includes("-(903,counts(0,0))"),"supervisor remains responsive with no children after invalid requests");
    check(m.some(x=>/\[stopped\],false\)/.test(x)),"supervisor loop stops normally after invalid additions");
    check(!W.posted.some(x=>x.type==="request"&&["spawn","reserve_pid","monitor"].includes(x.action)),"invalid additions start no children");
  },
  async child_spec_validation(W, check) {
    wrapperWorkerReplies(W);await startToplevel(W);
    async function run(goal){const n=W.sends.length;deliver(W,"'$call'(("+goal+"->R=checked;R=wrong),[template(R)])");const m=await nSends(W,n+1);return /\[checked\],false\)/.test(m[n]||"");}
    await childSpecContract(run,check,()=>W.posted.filter(m=>m.type==="request"&&!["send","receive","make_ref"].includes(m.action)).length,false);
    const spawn=W.posted.filter(m=>m.action==="spawn");
    check(spawn.some(m=>m.goal.includes("sup(one_for_one,1,5")),"worker default supervisor settings preserved");
    check(spawn.some(m=>m.name==="first"),"worker nested server option precedence preserved");
    check(spawn.some(m=>m.goal.includes("sup(rest_for_one,0,0.25")),"worker nested supervisor settings preserved");
  },

  async compatibility_query_exception_display(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    // Use the terminal's actual query runner and display formatter. Only UI
    // rendering and paging input are substituted; Prolog executes normally.
    const helpers=Function(html.slice(html.indexOf("function splitTopLevelArgs"),html.indexOf("function isDollarVarStartChar"))+
      "\nreturn {exceptionDisplayTerm, normalizeErrorText, normalizeRuntimeErrorMessage};")();
    Object.assign(global,helpers);
    const displayed=[],solutions=[],dets=[];
    const noop=()=>{};
    let completed;
    const host={swiWasmProlog:engine.prolog,swiWasmModule:engine,
      swiWasmRpcProlog:()=>source,currentLoadText:()=>"",swiWasmGoalNeedsStatechart:()=>false,
      pauseTerm:noop,recordSessionEvent:noop,clipText:x=>x,log:noop,
      startSwiWasmOutputStreaming:noop,stopSwiWasmOutputStreaming:noop,drainSwiWasmStatechartEventQueue:noop,
      echoSwiWasmOutput:(_,text)=>displayed.push(text),terminal:{},
      formatDisplayText:x=>x,formatErrorDisplay:Function("return (function(message) {"+html.split("formatErrorDisplay: function(message) {")[1].split("protocolLogFieldOrder:")[0].replace(/},\s*$/, "")+"})")(),
      presentSwiWasmSolution:(_,answer,det)=>{solutions.push(answer);dets.push(det);if(det){host.swiWasmFinalized=true;completed();}},
      finishError:(_,text)=>displayed.push(host.formatErrorDisplay(text)),
      finishFailure:()=>displayed.push("false"),resumeTerm:()=>completed(),
      resetQueryState:noop,appendQueryCompletionSpacing:noop};
    // Extract the production recorder instead of recreating its behavior.
    const recorder=html.slice(html.indexOf("window.swiWasmNoteException = function(text) {"),html.indexOf("window.swiWasmNoteDet = function(detText) {"));
    Function("self","window",recorder)(host,global.self);
    global.self.swiWasmNoteDet=text=>{host.swiWasmLastDet=String(text);return true;};
    global.self.swiWasmAwaitMore=()=>Promise.resolve("more");
    const run=workbenchMethod("runSwiWasmQuery","presentSwiWasmSolution");
    async function query(goal,mode="exception"){
      displayed.length=0;solutions.length=0;dets.length=0;
      host.activeGoal=goal;host.errorMessageDetail=mode;
      const end=new Promise(resolve=>{completed=resolve;});run.call(host,null);
      await end;await sleep(0);return displayed.slice();
    }
    check((await query("supervisor_spawn([child(a,[])],_)"))[0]==="error(missing_start_option(a),_)","main terminal honors exception-term setting for missing start");
    check((await query("supervisor_spawn([child(a,[start(true)]),child(a,[start(true)])],_)"))[0]==="error(permission_error(duplicate,supervisor_child_id,a),_)","main terminal preserves duplicate-id exception term");
    check((await query("spawn(true,_,[monitor(maybe)])"))[0]==="error(type_error(boolean,maybe),_)","other wrapper exceptions use the same setting");
    const concise=await query("spawn(true,_,[monitor(maybe)])","concise");
    check(concise.length===1&&concise[0].includes("Type error:")&&!concise[0].startsWith("error("),"unchecked setting still produces concise diagnostics");
    check((await query("throw(custom('a b', '$VAR'(1)))"))[0]==="custom('a b','$VAR'(1))","arbitrary thrown terms preserve quoting and literal $VAR data");
    check((await query("catch(throw(internal),internal,true)")).length===0&&solutions.length===1&&host.swiWasmQueryException===null,"caught exceptions and subsequent successes do not reuse stale errors");
    check(dets[0]===true,"deterministic success remains deterministic through exception capture");
    await query("(X=first;throw(error(test_later,context(test/0,detail))))");
    check(solutions.length===1&&solutions[0].X==="first"&&dets[0]===false&&displayed[0]==="error(test_later,_)","paged answer is preserved before a later exception");
    check((await query("fail"))[0]==="false"&&host.swiWasmQueryException===null,"failure clears the preceding query exception");
  },

  async compatibility_child_spec_validation(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_children.pl",source);
    check(!!engine.prolog.query("use_module('/compat_children.pl')").once(),"main child validation engine loaded");
    const calls=spawnOptionMainHarness();
    async function run(goal){
      // Keep cyclic test inputs inside Prolog rather than serialising query bindings.
      engine.prolog.query("assertz((user:browser_child_case :- ("+goal+")))").once();
      try {let n=0;await engine.prolog.forEach("user:browser_child_case",()=>n++);return n===1;}
      finally {engine.prolog.query("retractall(user:browser_child_case)").once();}
    }
    await childSpecContract(run,check,()=>calls.length,true);
    check(calls.some(m=>m.action==="spawn"&&m.args[1].includes("sup(one_for_one,1,5")),"main default supervisor settings preserved");
    check(calls.some(m=>m.action==="register"&&m.args.includes("first")),"main nested server option precedence preserved");
    const mailbox=["'$sup'(caller,901,start_child(child(a,[])))","'$sup'(caller,902,count_children)","'$sup_stop'(caller)"];
    const replies=[];
    global.self.swiWasmActorReceive=()=>Promise.resolve(mailbox.shift()||null);
    global.self.swiWasmActorSend=(pid,msg)=>{replies.push(msg);return Promise.resolve(true);};
    check(await run("swi_wasm_actor_bridge:wasm_supervisor_loop(sup(one_for_one,1,5,[],[]))"),"main supervisor loop survives malformed addition and stops normally");
    check(replies.some(x=>/^-\(901,error\(error\(missing_start_option\(a\)/.test(x))&&replies.includes("-(902,counts(0,0))"),"main loop replies with validation error and unchanged child count: "+JSON.stringify(replies));

    check(calls.some(m=>m.action==="spawn"&&m.args[1].includes("sup(rest_for_one,0,0.25")),"main nested supervisor settings preserved");
  },

  async wrapper_option_validation(W, check) {
    wrapperWorkerReplies(W);await startToplevel(W);
    for(const kind of Object.keys(wrapperKinds)) {
      for(const c of wrapperOptionCases(kind)) {
        const n=W.sends.length;deliver(W,"'$call'(("+invalidWrapperGoal(kind,c)+"->R=checked;R=wrong),[template(R)])");
        const m=await nSends(W,n+1);
        check(/\[checked\],false\)/.test(m[n]||""),kind+" rejects "+c[0]+" without binding inputs: "+m[n]);
      }
      const n=W.sends.length;
      deliver(W,"'$call'((Opts=[link(true)|Opts],catch("+wrapperCall(kind)+",error(type_error(list,_),context("+wrapperKinds[kind]+",_)),R=checked)),[template(R)])");
      const m=await nSends(W,n+1);check(/\[checked\],false\)/.test(m[n]||""),kind+" rejects cyclic options");
    }
    const n=W.sends.length;
    deliver(W,"'$call'((catch((swi_wasm_actor_bridge:wasm_child_start(start_sub_supervisor([],[period(0)]),child,[],_),fail),error(domain_error(supervisor_period,0),context(supervisor_spawn/3,_)),R=checked)),[template(R)])");
    const m=await nSends(W,n+1);check(/\[checked\],false\)/.test(m[n]||""),"nested supervisor reaches the same public validation before startup");
    check(!W.posted.some(m=>m.type==="request"&&["reserve_pid","spawn","remote_spawn","remote_toplevel_spawn","statechart_spawn","monitor","register","src_uri"].includes(m.action)),"worker wrapper validation precedes all creation, source, registration and monitor side effects");
  },
  async wrapper_valid_options(W, check) {
    wrapperWorkerReplies(W);await startToplevel(W);
    async function succeeds(goal,label){const n=W.sends.length;deliver(W,"'$call'(("+goal+"->R=checked;R=wrong),[template(R)])");const m=await nSends(W,n+1);check(/\[checked\],false\)/.test(m[n]||""),label+": "+m[n]);}
    await succeeds("toplevel_spawn(_,[session(true),session(false),time_limit(0.5),idle_limit(infinite),target(client),name(ptcp_test),monitor(true)])","worker valid toplevel settings");
    let req=W.posted.find(m=>m.action==="spawn");
    check(req.goal.includes("ptcp_options(true,0.5,infinite)")&&req.goal.includes("client"),"worker toplevel first session and fractional limit retained");
    await succeeds("toplevel_spawn(_,[node('https://example.org'),session(false),time_limit(infinite),idle_limit(0.25)])","worker remote toplevel supported settings");
    req=W.posted.find(m=>m.action==="remote_toplevel_spawn");
    check(req.session==="false"&&req.timeLimit==="infinite"&&req.idleLimit==="0.25","worker remote lifecycle settings serialized unchanged");
    await succeeds(wrapperSetup+"server_spawn(spawn_callback,Explicit,_,[initial_state(Other),src_list([fact(Explicit,Other)])]),var(Explicit),var(Other)","worker server compatibility metadata keeps arbitrary shared variables");
    await succeeds("supervisor_spawn([],_,[strategy(rest_for_one),strategy(one_for_all),intensity(0),period(0.25)])","worker supervisor zero intensity and fractional period");
    check(W.posted.some(m=>m.action==="spawn"&&m.goal.includes("sup(rest_for_one,0,0.25")),"worker supervisor first strategy retained");
    const chart="'"+simpleChart+"'";
    await succeeds("statechart_spawn(_,[src_uri('https://example.org/chart.xml'),trace(false),trace(true),src_list([support(ok)]),name(chart_test),monitor(true)])","worker statechart URI and duplicate trace remain supported");
    req=W.posted.filter(m=>m.action==="statechart_spawn").at(-1);
    check(req.sourceKind==="uri"&&req.source==="https://example.org/chart.xml"&&req.trace===false&&req.supportSource.includes("support(ok)"),"worker URI selection, supplemental source and first trace preserved");
    await succeeds("statechart_spawn(_,[src_uri('https://example.org/ignored.xml'),src_text("+chart+"),src_text('<ignored/>'),trace(true)])","worker multiple valid sources retain text-first selection");
    req=W.posted.filter(m=>m.action==="statechart_spawn").at(-1);
    check(req.sourceKind==="text"&&req.source===simpleChart,"worker first text source wins even after URI");
    await succeeds("statechart_spawn(_,[node('https://example.org'),src_uri('https://example.org/remote.xml'),trace(false),io_target(client)])","worker remote statechart URI still accepted");
    req=W.posted.filter(m=>m.action==="remote_spawn").at(-1);
    check(req.goal.includes("interpret_trace(false")&&req.goal.includes("remote.xml")&&req.goal.includes("with_io_target(client"),"worker remote statechart goal and routing unchanged");
  },

  async compatibility_statechart_routing(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_routing.pl",source);
    check(!!engine.prolog.query("use_module('/compat_routing.pl')").once(),"compatibility runtime loaded");
    check(await loadCompatibilityStatecharts(engine),"real statechart parser/interpreter loaded");
    const calls=spawnOptionMainHarness();
    global.self.swiResolveAssetUrl=uri=>{calls.push({action:"resolve",uri});return uri;};
    global.self.swiRpcGet=uri=>{calls.push({action:"get",uri});return simpleChart;};
    let next=7400000000;
    global.self.swiWasmStatechartSpawnWorker=(...args)=>{
      // The real main-engine coordinator currently returns a bare local id.
      // Monitor references retain that handle; down/3 qualifies its pid field.
      const pid=String(next++);
      calls.push({action:"statechart",args,pid});
      return Promise.resolve("statechart_spawn_ok("+JSON.stringify(pid)+")");
    };
    async function succeeds(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
    const chart="'"+simpleChart+"'";
    const sourceOption=kind=>kind==="text" ? "src_text("+chart+")" : "src_uri('https://example.org/chart.xml')";
    const outgoing=items=>items.filter(m=>["remote","statechart","spawn","reserve","remote_toplevel"].includes(m.action));
    try {
      for(const kind of ["text","uri"]) {
        check(await succeeds("statechart_wasm:statechart_stop"),kind+" begins without a local chart");
        let start=calls.length;
        check(await succeeds("statechart_spawn(Pid,["+sourceOption(kind)+",trace(false),trace(true),io_target(client),name(root_chart),src_list([routing_support("+kind+")])]),Pid=statechart,statechart_wasm:statechart_in(s),statechart_wasm:routing_support("+kind+"),statechart_wasm:trace_disabled,swi_wasm_actor_bridge:io_target(client)"),kind+" local root runs in main engine with source, first trace and I/O settings");
        let items=calls.slice(start);
        check(outgoing(items).length===0,kind+" root creates no worker and sends no remote request");
        check(items.filter(m=>m.action==="get").length===(kind==="uri"?1:0),kind+" root fetches URI only when selected");
        check(items.some(m=>m.action==="register"&&m.args[1]==="root_chart"&&m.args[2]==="statechart"),kind+" root retains name registration");

        start=calls.length;
        check(await succeeds("statechart_wasm:statechart_configuration(Before),statechart_spawn(Pid,[node(localhost),"+sourceOption(kind)+",trace(false),trace(true),name(nested_chart),link(false),io_target(child_client),monitor(true),src_list([child_support("+kind+")])]),Pid\\==statechart,statechart_wasm:statechart_configuration(After),Before==After,statechart_wasm:routing_support("+kind+")"),kind+" nested local chart preserves the running parent");
        items=calls.slice(start);let req=items.find(m=>m.action==="statechart");
        check(outgoing(items).length===1&&!!req,kind+" nested chart uses worker path exclusively");
        check(!!req&&req.args[0]===kind&&req.args[1]===(kind==="text"?simpleChart:"https://example.org/chart.xml")&&req.args[2].includes("child_support("+kind+")")&&req.args[3]==="nested_chart"&&req.args[4]==="false"&&req.args[5]==="child_client"&&req.args[6]==="false",kind+" nested worker receives source, name, link, I/O and first trace");
        check(!items.some(m=>m.action==="get"),kind+" nested source is passed to worker without main-engine fetching");
        check(!!req&&items.some(m=>m.action==="monitor"&&m.args[0]===req.pid&&m.args[1]===req.pid),kind+" nested spawn monitor targets worker pid");

        for(const running of [true,false]) {
          if(!running)check(await succeeds("statechart_wasm:statechart_stop"),kind+" stops parent before remote-only case");
          start=calls.length;
          const stateCheck=running?"statechart_wasm:statechart_in(s),statechart_wasm:routing_support("+kind+"),statechart_wasm:trace_disabled,swi_wasm_actor_bridge:io_target(client)":"\\+ statechart_wasm:statechart_running";
          check(await succeeds("statechart_wasm:statechart_configuration(Before),statechart_spawn(Pid,[node('https://example.org'),"+sourceOption(kind)+",trace(false),trace(true),io_target(remote_client),name(remote_chart),monitor(true),src_list([remote_support("+kind+")])]),Pid=8800000000@'https://example.org',statechart_wasm:statechart_configuration(After),Before==After,"+stateCheck),kind+" explicit remote node preserves local state (running="+running+")");
          items=calls.slice(start);req=items.find(m=>m.action==="remote");
          check(outgoing(items).length===1&&!!req,kind+" remote uses remote path exclusively (running="+running+")");
          check(!!req&&req.args[0].includes("https://example.org")&&req.args[1].includes(kind==="text"?"interpret_text_trace(false":"interpret_trace(false")&&req.args[1].includes(kind==="text"?simpleChart:"https://example.org/chart.xml")&&req.args[1].includes("with_io_target(remote_client")&&req.args[2].includes("remote_support("+kind+")"),kind+" remote node receives source, support, I/O and first trace (running="+running+")");
          check(!items.some(m=>m.action==="get"),kind+" remote URI remains for remote node to fetch (running="+running+")");
          check(items.some(m=>m.action==="register"&&m.args[1]==="remote_chart"&&m.args[2].includes("8800000000"))&&items.some(m=>m.action==="monitor"&&m.args[0].includes("8800000000")&&m.args[1]===m.args[0]),kind+" remote name and caller-side monitor retained (running="+running+")");
        }
      }
    } finally { await succeeds("statechart_wasm:statechart_stop"); }
  },

  async compatibility_wrapper_options(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_wrapper_options.pl",source);
    check(!!engine.prolog.query("use_module('/compat_wrapper_options.pl')").once(),"main wrapper engine loaded");
    const calls=spawnOptionMainHarness();
    global.self.swiWasmBehaviourSource=()=>{calls.push({action:"behaviour"});return behaviourSource;};
    global.self.swiWasmRemoteToplevelSpawn=(...args)=>{calls.push({action:"remote_toplevel",args});return Promise.resolve("8800000000@'https://example.org'");};
    global.self.swiWasmStatechartSpawnWorker=(...args)=>{calls.push({action:"statechart",args});return Promise.resolve('statechart_spawn_ok("7400000000@localhost")');};
    global.self.swiResolveAssetUrl=uri=>{calls.push({action:"resolve",uri});return uri;};
    global.self.swiRpcGet=uri=>{calls.push({action:"get",uri});return simpleChart;};
    async function succeeds(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
    for(const kind of Object.keys(wrapperKinds)) {
      for(const c of wrapperOptionCases(kind,true))check(await succeeds(invalidWrapperGoal(kind,c)),"main "+kind+" rejects "+c[0]+" without binding inputs");
      engine.prolog.query("assertz((user:wrapper_cycle_"+kind+" :- (Opts=[link(true)|Opts],catch(("+wrapperCall(kind)+",fail),error(type_error(list,_),context("+wrapperKinds[kind]+",_)),true))))").once();
      check(await succeeds("user:wrapper_cycle_"+kind),"main "+kind+" rejects cyclic options");
    }
    check(await succeeds("catch((swi_wasm_actor_bridge:wasm_child_start(start_sub_supervisor([],[period(0)]),child,[],_),fail),error(domain_error(supervisor_period,0),context(supervisor_spawn/3,_)),true)"),"main nested supervisor reaches public validation before startup");
    check(calls.length===0,"main validates before behaviour/source collection, reservation, dispatch, monitor and registration");
    check(await succeeds("toplevel_spawn(_,[session(true),session(false),time_limit(0.5),idle_limit(infinite),target(client),name(ptcp_test),monitor(true)])"),"main valid toplevel settings");
    let req=calls.find(m=>m.action==="spawn");
    check(req.args[1].includes("ptcp_options(true,0.5,infinite)")&&req.args[1].includes("client"),"main first session and fractional limit preserved");
    check(await succeeds("toplevel_spawn(_,[node('https://example.org'),session(false),time_limit(infinite),idle_limit(0.25),src_uri('https://example.org/support.pl')])"),"main remote toplevel with URI source");
    req=calls.find(m=>m.action==="remote_toplevel");
    check(req.args[2]==="false"&&req.args[3]==="infinite"&&req.args[4]==="0.25","main remote toplevel lifecycle preserved");
    check(await succeeds(wrapperSetup+"server_spawn(spawn_callback,Explicit,_,[initial_state(Other),src_list([fact(Explicit,Other)])]),var(Explicit),var(Other)"),"main server state and compatibility metadata stay unbound");
    check(await succeeds("supervisor_spawn([],_,[strategy(rest_for_one),strategy(one_for_all),intensity(0),period(0.25)])"),"main supervisor supports zero intensity and fractional periods");
    check(calls.some(m=>m.action==="spawn"&&m.args[1].includes("sup(rest_for_one,0,0.25")),"main first supervisor strategy retained");
    check(await loadCompatibilityStatecharts(engine),"main real statechart interpreter loaded");
    const chart="'"+simpleChart+"'";
    // Source-selection checks complement the separate three-path routing regression.
    check(await succeeds("statechart_spawn(_,[src_uri('https://example.org/ignored.xml'),src_text("+chart+"),src_text('<ignored/>'),trace(false),trace(true),src_list([support(ok)])])"),"main chart accepts duplicate sources/trace and supplemental source");
    check(!calls.some(m=>m.action==="get"),"main text selection does not fetch preceding URI");
    check(await succeeds("swi_wasm_actor_bridge:statechart_spawn_source([src_uri('https://example.org/ignored.xml'),src_text("+chart+"),src_text('<ignored/>')],text,"+chart+")"),"main first text source wins even after URI");
    check(await succeeds("statechart_wasm:statechart_stop,statechart_spawn(Pid,[src_uri('https://example.org/chart.xml'),trace(false)]),Pid=statechart,statechart_wasm:statechart_in(s)"),"main statechart URI accepted through local dispatch");
    check(await succeeds("statechart_spawn(_,[node('https://example.org'),src_text("+chart+"),trace(false)]),statechart_wasm:statechart_stop"),"main explicit-node chart settings accepted through existing dispatch");
    check(await succeeds("statechart_spawn(_,[node('https://example.org'),src_uri('https://example.org/chart.xml'),trace(false)]),statechart_wasm:statechart_stop"),"main explicit-node URI settings accepted through existing dispatch");
    check(calls.some(m=>m.action==="get"&&m.uri.includes("chart.xml")),"main existing URI-loading path retained");
  },

  async spawn_option_validation(W, check) {
    spawnOptionWorkerReplies(W);await startToplevel(W);
    for(const c of spawnOptionCases()) {
      const n=W.sends.length;deliver(W,"'$call'(("+invalidSpawnGoal(c)+"->R=checked;R=wrong),[template(R)])");
      const m=await nSends(W,n+1);
      check(/\[checked\],false\)/.test(m[n]||""),"worker rejects "+c[0]+" before setup, leaving variables untouched: "+m[n]);
    }
    const n=W.sends.length;
    deliver(W,"'$call'((Opts=[link(true)|Opts],catch(spawn(true,_,Opts),error(type_error(list,_),context(spawn/3,_)),R=checked)),[template(R)])");
    const m=await nSends(W,n+1);check(/\[checked\],false\)/.test(m[n]||""),"worker rejects cyclic options");
    check(!W.posted.some(m=>m.type==="request"&&["reserve_pid","spawn","remote_spawn","monitor","src_uri"].includes(m.action)),"worker invalid options create no pid, worker, remote request, monitor or source fetch");
  },
  async spawn_valid_options_and_wrappers(W, check) {
    spawnOptionWorkerReplies(W);await startToplevel(W);
    async function succeeds(goal,label){const n=W.sends.length;deliver(W,"'$call'(("+goal+"->R=checked;R=wrong),[template(R)])");const m=await nSends(W,n+1);check(/\[checked\],false\)/.test(m[n]||""),label+": "+m[n]);}
    await succeeds("assertz(user:spawn_fact(ok)),spawn(X=Pid,Pid,"+validSpawnOptions+"),var(X),var(T)","worker local spawn preserves goal/pid sharing and option variables");
    let spawns=W.posted.filter(m=>m.type==="request"&&m.action==="spawn");const first=spawns[0];
    check(first.name==="first"&&first.link===false,"worker first duplicate name/link wins");
    check(first.goal.includes(first.pid),"worker binds goal's shared pid before serialization");
    check(["first(a)","second(b)","list_fact(ok)","spawn_fact(ok)"].every(x=>first.source.includes(x)),"worker repeated and mixed sources retained");
    check(W.posted.some(m=>m.action==="monitor"&&m.target===first.pid+"@localhost"&&m.ref===m.target),"worker first monitor(true) installs spawn monitor");
    await succeeds("spawn(true,Pid,[node('https://example.org'),link(false),monitor(true),src_text('remote_fact(ok).')]),Pid=8800000000@'https://example.org'","worker remote dispatch and monitor retained");
    check(W.posted.some(m=>m.action==="remote_spawn"&&m.source.includes("remote_fact(ok)")),"worker remote source forwarded");
    await succeeds(wrapperSetup+"server_spawn(spawn_callback,S,_,[initial_state(S),name(test_server)]),var(S)","worker server wrapper removes initial_state without binding state");
    await succeeds("supervisor_spawn([],_,[strategy(one_for_one),strategy(one_for_all),intensity(2),period(5),name(test_sup)])","worker supervisor wrapper keeps its own options");
    spawns=W.posted.filter(m=>m.action==="spawn");
    check(spawns.some(m=>m.goal.includes("sup(one_for_one,2,5")),"worker supervisor first-occurrence settings reach its state");
    await succeeds("swi_wasm_actor_bridge:wasm_start_child(child(child_actor,[start(true),restart(temporary),shutdown(5),type(worker),significant(false),link(false)]),sup(one_for_one,1,5,[],[]),sup(one_for_one,1,5,[child(child_actor,_,child(child_actor,Original))],[])),memberchk(start(true),Original),memberchk(restart(temporary),Original)","worker child metadata retained in original spec, separated from spawn");
    await succeeds("swi_wasm_actor_bridge:wasm_child_start(server(spawn_callback,[initial_state([])]),child_server,[link(false)],_)","worker server child settings remain supported");
    await succeeds("swi_wasm_actor_bridge:wasm_child_start(start_sub_supervisor([],[strategy(one_for_one),intensity(1),period(5)]),child_sup,[link(false)],_)","worker nested supervisor settings remain supported");
    await succeeds("swi_wasm_actor_bridge:browser_wrapper_spawn_options([initial_state],[initial_state(X),src_list([fact(X)]),unknown(X)],Filtered),Filtered=[src_list([fact(Y)]),unknown(Z)],X==Y,Y==Z,var(X)","wrapper separation preserves sharing and does not hide unknown options");
  },
  async compatibility_spawn_options(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_spawn_options.pl",source);
    check(!!engine.prolog.query("use_module('/compat_spawn_options.pl')").once(),"main engine loaded");
    const calls=spawnOptionMainHarness();
    async function succeeds(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
    for(const c of spawnOptionCases(true))check(await succeeds(invalidSpawnGoal(c)),"main rejects "+c[0]+" without binding options or pid");
    engine.prolog.query("assertz((user:spawn_option_cycle_test :- (Opts=[link(true)|Opts],catch((spawn(true,_,Opts),fail),error(type_error(list,_),context(spawn/3,_)),true))))").once();
    check(await succeeds("user:spawn_option_cycle_test"),"main rejects cyclic options");
    check(calls.length===0,"main invalid options allocate no pid, spawn, remote request, monitor or source fetch");
    check(await succeeds("assertz(user:spawn_fact(ok)),spawn(X=Pid,Pid,"+validSpawnOptions+"),var(X),var(T)"),"main valid spawn retains variable sharing");
    const first=calls.find(m=>m.action==="spawn").args;
    check(first[3]==="first"&&first[4]==="false"&&first[1].includes(first[0]),"main first name/link and shared goal pid preserved");
    check(["first(a)","second(b)","list_fact(ok)","spawn_fact(ok)"].every(x=>first[2].includes(x)),"main repeated and mixed source transfer retained");
    check(calls.some(m=>m.action==="monitor"&&m.args[0]===first[0]+"@localhost"&&m.args[1]===m.args[0]),"main first monitor(true) retained");
    check(await succeeds("spawn(true,Pid,[node('https://example.org'),link(false),monitor(true),src_uri('https://example.org/source.pl')]),Pid=8800000000@'https://example.org'"),"main remote spawn and URI source retained");
    check(calls.some(m=>m.action==="remote"&&m.args[2].includes("uri_fact(ok)")),"main source URI fetched and passed to remote spawn");
    check(await succeeds(wrapperSetup+"server_spawn(spawn_callback,S,_,[initial_state(S),name(test_server)]),var(S)"),"main server wrapper preserves state sharing");
    check(await succeeds("supervisor_spawn([],_,[strategy(one_for_one),strategy(one_for_all),intensity(2),period(5),name(test_sup)])"),"main supervisor wrapper preserves settings");
    check(calls.some(m=>m.action==="spawn"&&m.args[1].includes("sup(one_for_one,2,5")),"main supervisor first-occurrence settings preserved");
    check(await succeeds("swi_wasm_actor_bridge:wasm_start_child(child(child_actor,[start(true),restart(temporary),shutdown(5),type(worker),significant(false),link(false)]),sup(one_for_one,1,5,[],[]),sup(one_for_one,1,5,[child(child_actor,_,child(child_actor,Original))],[])),memberchk(start(true),Original),memberchk(restart(temporary),Original)"),"main child metadata retained in supervisor state");
    check(await succeeds("swi_wasm_actor_bridge:wasm_child_start(server(spawn_callback,[initial_state([])]),child_server,[link(false)],_)"),"main server child settings remain supported");
    check(await succeeds("swi_wasm_actor_bridge:wasm_child_start(start_sub_supervisor([],[strategy(one_for_one),intensity(1),period(5)]),child_sup,[link(false)],_)"),"main nested supervisor settings remain supported");
    check(await succeeds("swi_wasm_actor_bridge:browser_wrapper_spawn_options([initial_state],[initial_state(X),src_list([fact(X)]),unknown(X)],Filtered),Filtered=[src_list([fact(Y)]),unknown(Z)],X==Y,Y==Z,var(X)"),"main wrapper separation preserves sharing and unknown options");
  },

  async rpc_client_option_validation(W, check) {
    W.control.reply=m=>({result:m.action==="src_uri" ? "p." : m.action==="rpc" ? "success([v(ok)],false)" : true});
    let starts=0,waits=0;
    const start=W.S.actorPromiseStart,wait=W.S.actorPromiseWait;
    W.S.actorPromiseStart=(...a)=>{starts++;return start(...a);};
    W.S.actorPromiseWait=(...a)=>{waits++;return wait(...a);};
    await startToplevel(W);
    for(const c of clientOptionCases()){
      const n=W.sends.length;
      deliver(W,"'$call'(("+invalidClientGoal(c)+"->R=checked;R=wrong),[template(R)])");
      const m=await nSends(W,n+1);
      check(/\[checked\],false\)/.test(m[n]||""),c.kind+" rejects "+c.options+" without binding option variables: "+m[n]);
    }
    const n=W.sends.length;
    deliver(W,"'$call'((Opts=[limit(2)|Opts],catch(rpc('https://example.org',p,Opts),error(type_error(list,_),context(rpc/3,_)),R=checked)),[template(R)])");
    const m=await nSends(W,n+1);
    check(/\[checked\],false\)/.test(m[n]||""),"cyclic option list rejected");
    check(starts===0&&waits===0,"invalid options allocate no promise and start no wait");
    check(!W.posted.some(m=>m.type==="request"&&["rpc","src_uri"].includes(m.action)),"invalid options trigger no RPC or source fetch");
  },

  async rpc_client_valid_options_and_retry(W, check) {
    const requests=[];
    W.control.reply=m=>{
      if(m.action==="rpc"){requests.push(m);return {result:"success([-(ok,ok)],false)"};}
      return {result:m.action==="src_uri" ? "uri_fact(ok)." : true};
    };
    await startToplevel(W);
    deliver(W,"'$call'((assertz(user:client_fact(ok)),promise('https://example.org',p(X),Ref,[template(X-X),template(ignored),offset(2),offset(9),limit(3),limit(8),once(false),once(true),timeout(-2),http_timeout(-3),src_text('first(a).'),src_text(\"second(b).\"),src_list([list_fact(ok)]),src_uri('https://example.org/source.pl'),src_predicates([client_fact/1])]),var(X),yield(Ref,Answer),var(X)),[template(Answer)])");
    let m=await nSends(W,1);
    check(/success\(\[-\(ok,ok\)\],false\)/.test(m[0]||""),"promise template keeps variable sharing: "+m[0]);
    const req=requests[0]||{};
    check(req.offset===2&&req.limit===3&&req.once===false,"first occurrence of duplicate options still wins");
    check(req.remoteTimeout===0&&req.httpTimeout===0,"negative transport timeouts retain normalization");
    check(["first(a)","second(b)","list_fact(ok)","uri_fact(ok)","client_fact(ok)"].every(part=>(req.loadText||"").includes(part)),"repeated and mixed source options remain additive");
    const variable=/p\(([_A-Za-z][A-Za-z0-9_]*)\)/.exec(req.goal||"");
    check(!!variable&&req.template==="-("+variable[1]+","+variable[1]+")","serialized goal and template share the same variable");
    const before=W.sends.length;
    deliver(W,"'$call'(promise('https://example.org',p,Ref,[timeout(none),http_timeout(none)]),[template(Ref)])");
    await nSends(W,before+1);
    check(requests[1].remoteTimeout===-1&&requests[1].httpTimeout===-1,"worker unspecified-timeout sentinel preserved");
    W.control.hold=["rpc"];
    const next=W.sends.length;
    deliver(W,"'$call'((promise('https://example.org',p,Ref),assertz(user:client_ref(Ref)),catch(yield(Ref,R,[timeout(0),on_timeout(R=bad),unknown(1)]),error(domain_error(yield_option,unknown(1)),_),true),var(R),yield(Ref,Early,[timeout(0),on_timeout(Early=waiting)])),[template(Early)])");
    m=await nSends(W,next+1);
    check(/\[waiting\],false\)/.test(m[next]||""),"invalid yield neither consumes pending promise nor runs callback: "+m[next]);
    const callbackQuery=W.sends.length;
    deliver(W,"'$call'((assertz(client_options_cb:answer(chosen)),user:client_ref(Ref),yield(Ref,R,client_options_cb:[timeout(0),on_timeout(answer(R))])),[template(R)])");
    m=await nSends(W,callbackQuery+1);
    check(/\[chosen\],false\)/.test(m[callbackQuery]||""),"qualified callback retains its caller module and answer variable");
    const held=W.control.held.shift();
    W.S.onmessage({data:{command:"reply",id:held.id,ok:true,result:"success([done],false)"}});
    const last=W.sends.length;
    deliver(W,"'$call'((user:client_ref(Ref),catch(yield(Ref,_,[timeout(bad)]),error(type_error(number,bad),_),true),yield(Ref,Answer)),[template(Answer)])");
    m=await nSends(W,last+1);
    check(/success\(\[done\],false\)/.test(m[last]||""),"invalid yield preserves a ready promise for a valid retry: "+m[last]);
  },

  async compatibility_rpc_client_options(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_options.pl",source);
    check(!!engine.prolog.query("use_module('/compat_options.pl')").once(),"compatibility client loads");
    const calls=compatibilityClientHarness();
    const workerText=fs.readFileSync(path.join(ROOT,"web/swi_wasm_actor_worker.js"),"utf8");
    const generated=workerText.split("\n").filter(x=>x.startsWith('      "')).map(x=>{try{return JSON.parse(x.trim().replace(/,$/,""));}catch(_){return "";}}).join("\n");
    const schema=(text,end)=>text.slice(text.indexOf("% Inspect the original options"),text.indexOf(end)).trim();
    check(schema(source,"rpc(URL, Goal) :-")===schema(generated,"rpc(Node, Goal) :-"),"both browser engines use the same validation schema");
    async function succeeds(goal){let count=0;await engine.prolog.forEach(goal,()=>count++);return count===1;}
    for(const c of clientOptionCases())check(await succeeds(invalidClientGoal(c)),c.kind+" rejects "+c.options+" before side effects");
    // Keep the cyclic term inside Prolog; the WASM answer converter cannot
    // serialize rational trees as JavaScript query bindings.
    engine.prolog.query("assertz((user:client_option_cycle_test :- (Opts=[limit(1)|Opts],catch((rpc('https://example.org',p,Opts),fail),error(type_error(list,_),context(rpc/3,_)),true))))").once();
    check(await succeeds("user:client_option_cycle_test"),"main-engine rejects cyclic option list");
    check(calls.rpc.length===0&&calls.source.length===0&&calls.promise.length===0&&calls.wait===0,"invalid options cause no network, promise creation or waiting");
    check(await succeeds("assertz(user:client_fact(ok)),promise('https://example.org',p(X),Ref,[template(X-X),template(ignored),offset(2),offset(9),limit(3),limit(8),once(false),once(true),timeout(-2),http_timeout(-3),src_text('first(a).'),src_text(\"second(b).\"),src_list([list_fact(ok)]),src_uri('https://example.org/source.pl'),src_predicates([client_fact/1])]),var(X),yield(Ref,success([ok-ok],false)),var(X)"),"main-engine valid promise retains template sharing");
    const url=new URL(calls.promise[0].url),load=url.searchParams.get("src_text")||"";
    check(url.searchParams.get("offset")==="2"&&url.searchParams.get("limit")==="3"&&!url.searchParams.has("once")&&url.searchParams.get("timeout")==="0","main-engine precedence and timeout normalization preserved");
    check(["first(a)","second(b)","list_fact(ok)","uri_fact(ok)","client_fact(ok)"].every(part=>load.includes(part)),"main-engine additive sources unchanged");
    check(await succeeds("catch((rpc('https://example.org',p,[timeout(none)]),fail),error(type_error(number,none),context(rpc/3,_)),true)"),"main-engine numeric timeout convention unchanged");
    calls.hold=true;
    check(await succeeds("promise('https://example.org',p,Ref),assertz(user:client_ref(Ref)),catch(yield(Ref,R,[timeout(0),on_timeout(R=bad),unknown(1)]),error(domain_error(yield_option,unknown(1)),_),true),var(R),yield(Ref,Early,[timeout(0),on_timeout(Early=waiting)]),Early==waiting"),"main-engine invalid yield preserves pending reference and callback sharing");
    check(await succeeds("assertz(client_options_cb:answer(chosen)),user:client_ref(Ref),yield(Ref,R,client_options_cb:[timeout(0),on_timeout(answer(R))]),R==chosen"),"main-engine qualified callback preserves context and sharing");
    calls.complete();await sleep(0);
    check(await succeeds("user:client_ref(Ref),catch(yield(Ref,_,[timeout(bad)]),error(type_error(number,bad),_),true),yield(Ref,success([done],false))"),"main-engine invalid yield preserves ready answer for retry");
    check(Object.keys(global.self._swiPromiseStore.items).length===0,"valid final yield consumes the promise normally");
  },

  async compatibility_worker_scopes(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const dummy={S:{onmessage:()=>{}},control:{}};
    const host=scopedWorkerCoordinator(dummy,"main");
    try {
      const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
      engine.FS.writeFile("/compat_scopes.pl",source);
      check(!!engine.prolog.query("use_module('/compat_scopes.pl')").once(),"main-engine runtime loaded");
      host.swiWasmActorMainMailbox=[];host.swiWasmActorMainWaiters=[];
      host.deliverSwiWasmMainActorMessage=workbenchMethod("deliverSwiWasmMainActorMessage","deliverSwiWasmRemoteResult");
      host.receiveSwiWasmActorMessage=workbenchMethod("receiveSwiWasmActorMessage","cancelSwiWasmMainActorWaiters");
      host.cancelSwiWasmMainActorWaiters=workbenchMethod("cancelSwiWasmMainActorWaiters","resetSwiWasmActorWorkers");
      dummy.S.onmessage=({data})=>{if(data.command==="deliver")host.deliverSwiWasmMainActorMessage(data.message);};
      global.self.setTimeout=setTimeout;global.self.clearTimeout=clearTimeout;
      const scopeFns=html.slice(html.indexOf("            window.swiWasmWorkerScopeOpen ="),html.indexOf("            window.swiWasmActorSpawnWithPid ="));
      Function("self","window",scopeFns)(host,global.self);
      global.self.swiWasmActorReceive=timeout=>host.receiveSwiWasmActorMessage(timeout);
      global.self.workerTestError=error=>error.message;
      async function succeeds(goal) {let count=0;await engine.prolog.forEach(goal,()=>count++);return count===1;}
      check(await succeeds("parallel([(sleep(0.1),X=slow),Y=fast]),X=slow,Y=fast"),"main-engine parallel results and variable sharing");
      check(await until(()=>host.scopeCount()===0&&host.live().length===0),"main-engine successful workers reclaimed");
      check(await succeeds("first_solution(X,[(sleep(1),X=slow),X=fast]),X=fast"),"main-engine first-solution winner preserved");
      check(host.scopeCount()===0&&host.live().length===0,"main-engine losing workers reclaimed before return");
      host.options.failAt=host.calls+2;
      let startupError;
      await engine.prolog.forEach("catch((parallel([receive({never->true}),true]),fail),E,term_string(E,Text))",answer=>{startupError=answer.Text;});
      check(String(startupError).includes("startup_original"),"main-engine startup error preserved");
      check(await until(()=>host.scopeCount()===0&&host.live().length===0),"main-engine partial startup reclaimed");
      host.options.failAt=0;
      // Drain the prior cleanup's private mailbox barrier before parking a new query.
      check(await succeeds("receive({never->true},[timeout(0)])"),"main-engine private barriers drain normally");
      host.swiWasmProlog=engine.prolog;host.swiWasmQueryPending=true;
      host.setPendingCompletionMessage=()=>{};host.recordSessionEvent=()=>{};
      host.abortSwiWasmQuery=workbenchMethod("abortSwiWasmQuery","abortSwiWasm2Query");
      let abortCalls=0;
      const originalAbort=engine.prolog.abort;
      engine.prolog.abort=function(){abortCalls++;return originalAbort.apply(this,arguments);};
      for(const startup of [false,true]) {
        host.options.holdReady=startup;host.heldReady=null;
        const running=succeeds("parallel([receive({never->true}),receive({never->true})])").then(()=>false,()=>true);
        check(await until(()=>startup ? !!host.heldReady : host.swiWasmActorMainWaiters.length>0,10000),startup?"main-engine startup suspended":"main-engine collection suspended");
        host.abortSwiWasmQuery(null);
        check(await running,"main-engine Stop unwinds suspended query");
        check(host.scopeCount()===0&&host.live().length===0&&host.swiWasmActorMonitors.length===0,"main-engine Stop reclaims scoped resources");
        check(await succeeds("true"),"main-engine remains usable after Stop");
        check(await succeeds("receive({never->true},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_scope_worker(_,R),[]),findall(T,swi_wasm_actor_bridge:closing_worker_scope(T),[])"),"main-engine retirement filters drain");
      }
      check(abortCalls===0,"no pending abort is left to kill the next query");
    } finally {await host.stop();}
  },


  async worker_scope_ui_hard_abort(W, check) {
    const dummy={S:{onmessage:()=>{}},control:{}};
    const host=scopedWorkerCoordinator(dummy);
    try {
      // Use an actual shell Worker and the actual UI hard-reset handler. The
      // cooperative abort helper used elsewhere does not exercise this path.
      delete host.swiWasmActorWorkers[PID];
      dummy.S.onmessage=({data})=>{
        const entry=host.swiWasmActorWorkers[PID];
        if(entry&&entry.worker)entry.worker.postMessage(data);
      };
      host.isSwiWasm2Mode=true;host.swiWasm2ShellPid=PID;
      host.terminal=null;host.fetchExamplesIndex=()=>{};
      host.toplevelSpawnOptionsText=()=>"[session(true)]";
      host.currentSwiWasm2LoadText=()=>"";
      host.pauseTerm=()=>{};
      const notices=[],results=[];
      host.finishError=(_,text)=>notices.push(text);
      host.handleSwiWasm2ToplevelMessage=(_,message)=>{
        if(!["success","failure","error","timeout","abort","output","prompt"].includes(message.type))return false;
        results.push(message);return true;
      };
      host.abortSwiWasm2Query=workbenchMethod("abortSwiWasm2Query","abortBoundActor");
      const shellGoal="swi_wasm_actor_bridge:ptcp("+PID+",terminal,true)";
      host.spawnSwiWasmWorkerActor(shellGoal,"",PID,"","shell_toplevel");
      check(await until(()=>host.swiWasm2ShellReady,10000),"UI shell is ready");
      const ordinary=await host.spawnSwiWasmWorkerActorReady("receive({stop->true})","","7999999999","","actor",{parentPid:PID,linked:true});
      host.monitorSwiWasmActor(PID,ordinary,"8999999999");
      for(const [goal,startup] of [
        ["parallel([receive({never->true}),receive({never->true})])",false],
        ["first_solution(X,[receive({never->true}),receive({never->true})])",false],
        ["parallel([receive({never->true}),true])",true]
      ]) {
        host.options.holdReady=startup;host.heldReady=null;
        const oldWorker=host.swiWasmActorWorkers[PID].worker;
        oldWorker.postMessage({command:"toplevel_call",goal:goal,options:"[]"});
        check(await until(()=>startup ? !!host.heldReady : host.swiWasmActorMonitors.length===3,10000),startup?"UI startup wait is active":"UI result wait is active");
        host.abortSwiWasm2Query(null);
        check(host.scopeCount()===0,"UI hard Abort closes the discarded shell's scopes");
        check(host.live().length===1&&host.live()[0]===ordinary,"UI hard Abort stops scoped workers and preserves ordinary actor");
        check(host.swiWasmActorMonitors.length===1&&host.swiWasmActorMonitors[0].ref==="8999999999","UI hard Abort preserves unrelated monitor");
        check(notices[notices.length-1]==="Computation aborted. 1 SWI-WASM actor remains running: "+ordinary+".","survivor notice lists only the ordinary actor: "+notices[notices.length-1]);
        check(oldWorker.onmessage===null,"queued old-shell messages cannot reopen scopes after replacement");
        if(host.scopeCount()>0)return; // report the original regression without hanging the next shell
        host.options.holdReady=false;
        check(await until(()=>host.swiWasm2ShellReady,10000),"replacement UI shell becomes ready");
        const before=results.length;
        host.swiWasmActorWorkers[PID].worker.postMessage({command:"toplevel_call",goal:"(actors(A),sort(A,L),sort(["+PID+"@localhost,"+ordinary+"@localhost],L))",options:"[]"});
        check(await until(()=>results.slice(before).some(m=>["success","failure","error"].includes(m.type)),10000),"replacement shell answers actors/1");
        check(results.slice(before).some(m=>m.type==="success"),"actors/1 matches the original shell and ordinary actor only");
      }
      host.exitSwiWasmActor(ordinary,"kill");
      host.swiWasmActorWorkers[PID].worker.postMessage({command:"toplevel_call",goal:"parallel([receive({never->true}),receive({never->true})])",options:"[]"});
      check(await until(()=>host.swiWasmActorMonitors.length===2,10000),"UI wait without ordinary survivors is active");
      host.abortSwiWasm2Query(null);
      check(host.live().length===0&&host.scopeCount()===0&&notices[notices.length-1]==="Computation aborted.","UI hard Abort leaves no extra actors when none should survive");
      check(await until(()=>host.swiWasm2ShellReady,10000),"replacement shell ready after clean abort");
      const before=results.length;
      host.swiWasmActorWorkers[PID].worker.postMessage({command:"toplevel_call",goal:"actors(["+PID+"@localhost])",options:"[]"});
      check(await until(()=>results.slice(before).some(m=>m.type==="success"),10000),"actors/1 contains only the replacement shell, matching the UI baseline");
    } finally {await host.stop();}
  },

  async worker_scope_results(W, check) {
    const host=scopedWorkerCoordinator(W);
    try {
      await startToplevel(W);
      const queries=[
        ["parallel([(sleep(0.1),X=slow),Y=fast])","X-Y","[-(slow,fast)]"],
        ["first_solution(X,[(sleep(1),X=slow),X=fast])","X","[fast]"],
        ["first_solution(X,[exit(killed),(sleep(0.1),X=ok)],[on_error(continue)])","X","[ok]"],
        ["(parallel([fail,receive({never->true})])->X=bad;X=failed)","X","[failed]"],
        ["catch(parallel([throw(original),receive({never->true})]),X,true)","X","[original]"],
        ["(parallel([X=a,X=b])->R=bad;R=mismatch)","R","[mismatch]"],
        ["first_solution(X,[fail,X=ok])","X","[ok]"],
        ["(parallel([]),\\+first_solution(_,[]),R=empty)","R","[empty]"]
      ];
      for(const [goal,template,expected] of queries){
        const before=W.sends.length;
        deliver(W,"'$call'("+goal+",[template("+template+")])");
        const m=await nSends(W,before+1,15000);
        check((m[before]||"").includes(expected+",false)"),"public combinator result: "+m[before]);
        check(await until(()=>host.scopeCount()===0&&host.live().length===0),"scope and workers reclaimed");
        check(host.swiWasmActorMonitors.length===0,"no leftover worker monitors");
      }
    } finally {await host.stop();}
  },

  async worker_scope_partial_startup(W, check) {
    const host=scopedWorkerCoordinator(W);
    try {
      await startToplevel(W);
      // Unrelated actor and explicit monitor must survive failed startup.
      const unrelated=await host.spawnSwiWasmWorkerActorReady("receive({stop->true})","","7999999999","","actor",{});
      host.monitorSwiWasmActor(PID,unrelated,"unrelated_ref");
      for(const name of ["parallel([receive({never->true}),true])","first_solution(X,[receive({never->true}),X=ok])"]){
        host.options.failAt=host.calls+2;
        host.options.extraAt=host.calls+1;
        deliver(W,"unrelated_payload");
        const before=W.sends.length;
        deliver(W,"'$call'(catch("+name+",E,(R := workerTestError(#E))),[template(R)])");
        const m=await nSends(W,before+1,15000);
        check((m[before]||"").includes("[startup_original],false)"),"original startup error preserved: "+m[before]);
        check(await until(()=>host.scopeCount()===0&&host.live().length===1),"earlier and partially started workers stopped");
        check(host.live()[0]===unrelated&&host.swiWasmActorMonitors.length===1,"unrelated actor and monitor survive");
        check(Object.keys(host.swiWasmReservedWorkerActorPids).length===0,"no abandoned pid reservation");
        const next=W.sends.length;
        deliver(W,"'$call'((receive({unrelated_payload->true}),receive({down("+host.extraPid+"@localhost,"+host.extraRef+",_)->Seen=kept},[timeout(1),on_timeout(Seen=lost)])),[template(Seen)])");
        const replies=await nSends(W,next+1);
        check(/\[kept\],false\)/.test(replies[next]||""),"unrelated payload and explicit monitor on a scoped worker survive cleanup");
      }
    } finally {await host.stop();}
  },

  async worker_scope_abort_startup(W, check) {
    const host=scopedWorkerCoordinator(W);
    try {
      await startToplevel(W);host.options.holdReady=true;
      deliver(W,"'$call'(parallel([receive({never->true}),true]),[])");
      check(await until(()=>!!host.heldReady,10000),"startup is waiting for readiness");
      abort(W);
      const m=await nSends(W,1);
      check(/^abort\(/.test(m[0]||""),"abort during startup acknowledged");
      check(await until(()=>host.live().length===0&&host.scopeCount()===0),"in-flight startup worker reclaimed");
      check(host.swiWasmActorMonitors.length===0,"late readiness cannot install a monitor");
      host.handleSwiWasmWorkerActorMessage(host.created[0],{data:host.heldReady});
      await sleep(20);
      check(host.live().length===0&&host.swiWasmActorMonitors.length===0,"late ready event cannot resurrect a withdrawn worker");
      host.options.holdReady=false;
      deliver(W,"'$call'(X=ok,[template(X)])");
      const all=await nSends(W,2);
      check(/\[ok\],false\)/.test(all[1]||""),"persistent caller remains usable");
    } finally {await host.stop();}
  },


  async worker_scope_abandoned_reservation_and_cut(W, check) {
    const host=scopedWorkerCoordinator(W);
    try {
      await startToplevel(W);
      host.options.holdReservation=true;
      deliver(W,"'$call'(parallel([true]),[])");
      check(await until(()=>!!host.heldReservation),"reservation recorded before its reply is delivered");
      abort(W);
      await nSends(W,1);
      check(await until(()=>host.scopeCount()===0),"scope closes during reservation wait");
      check(Object.keys(host.swiWasmReservedWorkerActorPids).length===0&&host.created.length===0,"unlaunched reservation reclaimed without starting a worker");
      host.options.holdReservation=false;
      W.S.onmessage({data:host.heldReservation});
      deliver(W,"'$call'(once(swi_wasm_actor_bridge:with_worker_scope(S,(swi_wasm_actor_bridge:spawn_scoped_worker(S,receive({never->true}),_),member(X,[a,b])))),[template(X)])");
      const m=await nSends(W,2,15000);
      check(/\[a\],false\)/.test(m[1]||""),"cut preserves the selected alternative: "+m[1]);
      check(await until(()=>host.scopeCount()===0&&host.live().length===0),"cut closes the scope and stops its worker");
    } finally {await host.stop();}
  },

  async worker_scope_abort_wait(W, check) {
    const host=scopedWorkerCoordinator(W);
    try {
      await startToplevel(W);
      for(const goal of ["parallel([receive({never->true}),receive({never->true})])","first_solution(X,[receive({never->true}),receive({never->true})])"]){
        const before=W.sends.length;
        deliver(W,"'$call'("+goal+",[])");
        check(await until(()=>host.swiWasmActorMonitors.length===2,10000),"workers started and result wait active");
        abort(W);
        const m=await nSends(W,before+1);
        check(/^abort\(/.test(m[before]||""),"wait abort acknowledged");
        check(await until(()=>host.scopeCount()===0&&host.live().length===0),"abandoned workers stopped");
        check(host.swiWasmActorMonitors.length===0,"abandoned worker monitors removed");
      }
    } finally {await host.stop();}
  },


  async remote_monitor_reference_wire(W, check) {
    // Feed actual native response JSON into the unchanged browser matcher.
    const node="http://monitor.test:3053",pid="123@'"+node+"'";
    const responseFile=path.join(ROOT,"prolog/web_prolog/node_response.pl").replace(/'/g,"''");
    const goal="use_module('"+responseFile+"'),node_runtime_state:register_node_runtime(-77124,_{url:'"+node+"'}),node_runtime_state:with_node_port_context(-77124,findall(JSON,(member(Ref,[@(123,'"+node+"'),456,9007199254740993]),node_response:answer_to_json(down(@(123,'"+node+"'),Ref,true),JSON)),Frames)),http_json:atom_json_dict(Text,Frames,[]),writeln(Text)";
    const result=spawnSync(process.env.SWIPL||"swipl",["-q","-g",goal,"-t","halt"],{encoding:"utf8",timeout:10000});
    if(result.status!==0)throw new Error("native reference fixture failed: "+(result.stderr||result.error));
    const frames=JSON.parse(result.stdout.trim());
    check(frames.every(frame=>frame.pid===123),"native actor pid retains local integer representation");
    check(frames[0].ref===pid,"native pid-shaped reference retains full node");
    check(frames[1].ref===456&&frames[2].ref==="9007199254740993","ordinary and large integer references retain their wire conventions");
    const host=serverMonitorCoordinator(()=>{});
    host.parseSwiWasmRemoteActorPid=text=>text===pid ? {node,pid:123}:null;
    host.takeSwiWasmRemoteMonitor=workbenchMethod("takeSwiWasmRemoteMonitor","monitorSwiWasmActor");
    host.swiWasmActorMonitors=[{watcher:"main",pid,ref:pid},{watcher:"worker",pid,ref:"456"}];
    check(!host.takeSwiWasmRemoteMonitor(node,123,"123")&&host.swiWasmActorMonitors.length===2,"shortened stale reference cannot select a different monitor");
    check(!host.takeSwiWasmRemoteMonitor("http://other.test",123,frames[0].ref),"monitor remains restricted to its connection");
    const first=host.takeSwiWasmRemoteMonitor(node,frames[0].pid,frames[0].ref);
    check(first&&first.watcher==="main"&&host.swiWasmActorMonitors.length===1,"spawn reference matches and removes only its own monitor");
    check(!host.takeSwiWasmRemoteMonitor(node,frames[0].pid,frames[0].ref)&&host.swiWasmActorMonitors.length===1,"late notification for removed reference leaves other monitor intact");
    const second=host.takeSwiWasmRemoteMonitor(node,frames[1].pid,String(frames[1].ref));
    check(second&&second.watcher==="worker"&&host.swiWasmActorMonitors.length===0,"independent monitor on same actor still matches and cleans up");
  },

  async server_monitor_pending_install(W, check) {
    const messages=[], wire=[];
    const host=serverMonitorCoordinator(text=>messages.push(text));
    let connect;
    const connected=new Promise(resolve=>{connect=resolve;});
    host.parseSwiWasmRemoteActorPid=pid=>pid==="remote" ? {node:"remote_node",pid:123} : null;
    host.ensureSwiWasmRemoteActorConnection=()=>connected;
    const installing=host.monitorSwiWasmActor("main","remote","8765432100");
    host.swiWasmActorMonitors.push({watcher:"main",pid:"other",ref:"unrelated"});
    host.cleanupSwiWasmServerMonitor("main","8765432100");
    check(messages.length===1 && messages[0]==="'$server_monitor_cleaned'(8765432100)","cleanup acknowledges local removal without waiting for connection");
    connect({socket:{send:text=>wire.push(JSON.parse(text))}});
    check(await installing===false,"withdrawn monitor is not installed when connection finishes");
    await Promise.resolve();
    check(!wire.some(m=>m.command==="monitor"),"no remote monitor is recreated after cleanup");
    check(host.swiWasmActorMonitors.length===1 && host.swiWasmActorMonitors[0].ref==="unrelated","unrelated monitor retained");
    const demonitor=host.demonitorSwiWasmActor;
    host.demonitorSwiWasmActor=function(w,r) { demonitor.call(this,w,r); return Promise.reject(new Error("transport_failed")); };
    host.cleanupSwiWasmServerMonitor("main","unrelated");
    await new Promise(resolve=>setImmediate(resolve));
    check(host.swiWasmActorMonitors.length===0 && messages.length===2,"transport rejection is handled after local cleanup");
    host.takeSwiWasmRemoteMonitor=workbenchMethod("takeSwiWasmRemoteMonitor","monitorSwiWasmActor");
    host.swiWasmActorMonitors=[{watcher:"main",pid:"remote",ref:"remaining"}];
    check(!host.takeSwiWasmRemoteMonitor("remote_node",123,"retired"),"late down for retired ref cannot consume another monitor on the same actor");
    check(host.swiWasmActorMonitors.length===1,"other reference remains installed after late down");
    check(!host.takeSwiWasmRemoteMonitor("different_node",123,"remaining"),"remote down is restricted to its connection");
    check(!!host.takeSwiWasmRemoteMonitor("remote_node",123,"remaining") && host.swiWasmActorMonitors.length===0,"matching remote down still retires its own monitor");
  },

  async server_monitor_scopes(W, check) {
    const host = installServerMonitorCoordinator(W);
    await startToplevel(W);
    // A timed-out callback retains alternatives until cut/exhaustion. Cleanup
    // discards both deferred down messages and host-mailbox messages for its ref.
    deliver(W, "'$call'((monitor(server,M),monitor(other,U),self(S),send(S,down(other,U,keep)),findall(X,server_yield(42,M,X,[timeout(0),on_timeout((member(X,[a,b]),assertz(swi_wasm_actor_bridge:deferred(down(server,M,old)))))]),Xs),receive({down(other,U,keep)->true}),receive({down(server,M,_) -> Stale=yes},[timeout(0),on_timeout(Stale=no)]),swi_wasm_actor_bridge:receive({never->true},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_server_monitor(R),Retired)),[template(Xs-Stale-Retired)])");
    const m = await nSends(W, 1);
    check(/\[-\(-\(\[a,b\],no\),\[\]\)\],false\)/.test(m[0] || ""), "callback alternatives, flush and barrier: " + m[0]);
    check(host.cleaned.length === 1, "one monitor cleanup for the completed wait");
    check(host.swiWasmActorMonitors.length === 1 && host.swiWasmActorMonitors[0].pid === "other", "unrelated monitor remains installed");
    const tests = [
      ["(monitor(server,M),self(S),send(S,42-wrong),(server_yield(42,M,wanted,[])->R=bad;R=mismatch))", "mismatch"],
      ["(monitor(server,M),(server_yield(42,M,_,[timeout(0),on_timeout(fail)])->R=bad;R=failed))", "failed"],
      ["(monitor(server,M),catch(server_yield(42,M,_,[timeout(0),on_timeout(throw(original))]),R,true))", "original"],
      ["(monitor(server,M),self(S),send(S,down(server,M,dead)),catch(server_yield(42,M,_,[]),R,true))", "server_down(dead)"],
      ["(monitor(server,M),once(server_yield(42,M,R,[timeout(0),on_timeout(member(R,[first,second]))])))", "first"],
      ["(monitor(server,M),assertz(swi_wasm_actor_bridge:deferred(down(other,_,application))),server_yield(42,M,_,[timeout(0)]),clause(swi_wasm_actor_bridge:deferred(down(other,V,application)),true),var(V),R=preserved)", "preserved"]
    ];
    for (const [goal, result] of tests) {
      const before = W.sends.length, cleaned = host.cleaned.length;
      deliver(W,"'$call'("+goal+",[template(R)])");
      const replies = await nSends(W,before+1);
      check((replies[before] || "").includes("["+result+"],false)"),"wait outcome preserved: "+replies[before]);
      check(host.cleaned.length===cleaned+1 && host.swiWasmActorMonitors.length===1,"only the wait's monitor removed");
    }
  },

  async server_promise_setup_cleanup(W, check) {
    const host = installServerMonitorCoordinator(W);
    await startToplevel(W);
    W.control.sendError = "send_original";
    W.S.serverTestErrorMessage = error => error.message;
    const demonitor = host.demonitorSwiWasmActor;
    host.demonitorSwiWasmActor = function(watcher, ref) {
      demonitor.call(this, watcher, ref);
      throw new Error("cleanup_must_not_replace_original");
    };
    deliver(W,"'$call'(catch(server_promise(server,request,_,_),E,(Text := serverTestErrorMessage(#E))),[template(Text)])");
    let m = await nSends(W, 2); // request send + toplevel answer
    check(/send_original/.test(m[m.length-1] || ""),"send exception preserved: "+m.join(" | "));
    check(host.cleaned.length===1 && host.swiWasmActorMonitors.length===0,"setup/send exception withdraws monitor");
    W.control.sendError = null;
    // Force plain failure after installation by using a prebound request reference.
    deliver(W,"'$call'((server_promise(server,request,not_a_number,_)->R=bad;R=failed),[template(R)])");
    m = await nSends(W, 3);
    check(/\[failed\],false\)/.test(m[m.length-1] || ""),"setup failure remains failure: "+m[m.length-1]);
    check(host.cleaned.length===2 && host.swiWasmActorMonitors.length===0,"setup failure withdraws monitor");
    deliver(W,"'$call'(server_promise(server,request,Ref,M),[template(Ref-M)])");
    await until(()=>host.swiWasmActorMonitors.length===1);
    check(host.swiWasmActorMonitors.length===1 && host.cleaned.length===2,"successful promise retains its monitor");
    W.control.monitorError = "install_original";
    const before=W.sends.length;
    deliver(W,"'$call'(catch(server_promise(server,request,_,_),E,(Text := serverTestErrorMessage(#E))),[template(Text)])");
    const all=await nSends(W,before+1);
    check((all[before] || "").includes("[install_original],false)"),"monitor-install exception preserved");
    check(host.cleaned.length===3 && host.swiWasmActorMonitors.length===1,"failed installation removes only its own monitor");
  },

  async server_request_reply_cleanup(W, check) {
    const host=installServerMonitorCoordinator(W);
    W.control.serverReply=true;
    await startToplevel(W);
    deliver(W,"'$call'(server_request(server,request,Reply,[]),[template(Reply)])");
    const m=await nSends(W,2);
    check(/\[ok\],false\)/.test(m[1] || ""),"successful request still returns the server reply: "+m.join(" | "));
    check(host.cleaned.length===1 && host.swiWasmActorMonitors.length===0,"successful reply withdraws the request monitor");
    check(!W.posted.some(x=>x.action==="exit"),"cleanup does not cancel the server");
  },

  async server_wait_abort_cleanup(W, check) {
    const host = installServerMonitorCoordinator(W);
    await startToplevel(W);
    deliver(W,"'$call'((monitor(other,U),monitor(server,M),server_yield(42,M,_,[])),[])");
    check(await until(()=>host.swiWasmActorMonitors.length===2),"both monitors installed before abort");
    abort(W);
    const m = await nSends(W,1);
    check(/^abort\(/.test(m[0] || ""),"abort acknowledgement preserved: "+m[0]);
    check(await until(()=>host.cleaned.length===1),"interrupted wait initiates cleanup");
    check(host.swiWasmActorMonitors.length===1 && host.swiWasmActorMonitors[0].pid==="other","abort preserves unrelated monitor");
    deliver(W,"'$call'((receive({never->true},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_server_monitor(R),Rs)),[template(Rs)])");
    const replies=await nSends(W,2);
    check(/\[\[\]\],false\)/.test(replies[1] || ""),"retirement bookkeeping cleared after barrier: "+replies[1]);
  },

  async compatibility_server_monitor_cleanup(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compat_server.pl",source);
    check(!!engine.prolog.query("use_module('/compat_server.pl')").once(),"compatibility runtime loaded");
    const queue=[];
    const host=serverMonitorCoordinator(text=>queue.push(text));
    let next=8765432100;
    global.self.swiWasmActorMakeRef=()=>String(next++);
    global.self.swiWasmActorMonitor=(pid,ref)=>Promise.resolve(host.monitorSwiWasmActor("main",pid,ref));
    global.self.swiWasmServerMonitorCleanup=ref=>{
      host.cleaned.push(ref);
      queue.push("down(server,"+ref+",queued)");
      host.cleanupSwiWasmServerMonitor("main",ref);
      return true;
    };
    global.self.swiWasmActorReceive=()=>Promise.resolve(queue.length ? queue.shift() : null);
    global.self.swiWasmActorSend=()=>Promise.resolve(true);
    async function succeeds(goal) { let count=0; await engine.prolog.forEach(goal,()=>count++); return count===1; }
    check(await succeeds("(monitor(server,M),monitor(other,U),findall(X,server_yield(42,M,X,[timeout(0),on_timeout((member(X,[a,b]),assertz(swi_wasm_actor_bridge:deferred(down(server,M,old)))))]),[a,b]),receive({down(server,M,_)->fail},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_server_monitor(R),[]))"),"compatibility callbacks, deferred/queued flush and barrier");
    check(host.cleaned.length===1 && host.swiWasmActorMonitors.length===1 && host.swiWasmActorMonitors[0].pid==="other","compatibility preserves unrelated monitor");
    for (const goal of [
      "(monitor(server,M),assertz(swi_wasm_actor_bridge:deferred(42-wrong)),\\+server_yield(42,M,wanted,[]))",
      "(monitor(server,M),\\+server_yield(42,M,_,[timeout(0),on_timeout(fail)]))",
      "(monitor(server,M),catch((server_yield(42,M,_,[timeout(0),on_timeout(throw(original))]),fail),original,true))",
      "(monitor(server,M),once(server_yield(42,M,first,[timeout(0),on_timeout(member(first,[first,second]))])))"
    ]) {
      const before=host.cleaned.length;
      check(await succeeds(goal),"compatibility wait outcome preserved");
      check(host.cleaned.length===before+1 && host.swiWasmActorMonitors.length===1,"compatibility cleanup after wait");
    }
    global.self.swiWasmActorSend=()=>Promise.reject(new Error("original_send"));
    const before=host.cleaned.length;
    global.self.serverTestErrorMessage=error=>error.message;
    check(await succeeds("catch((server_promise(server,request,_,_),fail),E,(M := serverTestErrorMessage(#E), M == original_send))"),"compatibility original send exception propagates");
    check(host.cleaned.length===before+1 && host.swiWasmActorMonitors.length===1,"compatibility setup exception cleanup");
    global.self.swiWasmActorSend=(pid,text)=>{
      const ref=/,(\d{10}),request\)$/.exec(text)[1];
      queue.push(ref+"-ok");
      return Promise.resolve(true);
    };
    check(await succeeds("server_request(server,request,ok,[])"),"compatibility successful request returns its reply");
    check(host.cleaned.length===before+2 && host.swiWasmActorMonitors.length===1,"compatibility successful reply cleanup");
  },

  async compatibility_rpc_and_yield(W, check) {
    const body = html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source = Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine = await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    engine.FS.writeFile("/compatibility.pl",source);
    check(!!engine.prolog.query("use_module('/compatibility.pl')").once(), "compatibility runtime loads");
    const offsets = [];
    global.self.encodeURIComponent = encodeURIComponent;
    global.self.swiRpcGetAsync = url => {
      offsets.push(Number(/offset=(\d+)/.exec(url)[1]));
      return Promise.resolve(offsets.length===1 ? "success([v(a),v(b)],true)" : "success([v(c)],false)");
    };
    // Call the paging predicate directly to isolate paging from URL/source setup.
    async function succeeds(goal) {
      let count = 0;
      await engine.prolog.forEach(goal,()=>{count++;});
      return count === 1;
    }
    check(await succeeds("findall(X,swi_wasm_actor_bridge:web_rpc_page(v(X),0,5,'https://example.org',p,'v(X)',[],-1,false,-1),[a,b,c])"),"compatibility paging retains short-page answers");
    check(JSON.stringify(offsets)==="[0,2]","compatibility paging uses actual length: "+offsets);
    global.self.swiPromiseStart = () => "1234567891";
    global.self.swiResolveRpcBase = () => "https://example.org";
    check(await succeeds("promise('https://example.org',p,1234567891)"),"compatibility promise reference converts from JavaScript atom");
    global.self.swiPromiseWait = () => Promise.resolve(null);
    check(await succeeds("yield(1234567891,timeout,[timeout(0)])"),"compatibility default timeout answer");
    check(await succeeds("yield(1234567891,R,[timeout(0),on_timeout(R=custom)]),R=custom"),"compatibility callback binds answer");
    check(await succeeds("catch((yield(1234567891,_,[timeout(0),on_timeout(fail)]),fail),error(timeout_callback_failed(1234567891),_),true)"),"compatibility failing callback errors");
    global.self.swiPromiseWait = () => Promise.resolve("missing_promise");
    check(await succeeds("catch((yield(42,_),fail),error(existence_error(promise,42),_),true)"),"compatibility missing reference rejected");
    global.self.swiPromiseWait = () => Promise.resolve("error(rpc_error(fetch_failed)).");
    check(await succeeds("yield(1234567891,error(rpc_error(fetch_failed)))"),"compatibility failure is an answer term");
    // Both generated collectors must keep the same rules. Worker scenarios below
    // exercise those rules against real selective receive and cleanup requests.
    const workerText = fs.readFileSync(path.join(ROOT,"web/swi_wasm_actor_worker.js"),"utf8");
    const collectorLines = workerText.split("\n").filter(x=>/^      \"/.test(x)).map(x=>{try{return JSON.parse(x.trim().replace(/,$/,""));}catch(_){return "";}}).join("\n");
    const block = text => text.slice(text.indexOf("parallel(QualifiedGoals) :-"),text.indexOf("worker_drain(Pid) :-")).replace(/(?:swiWasm|actor)WorkerScope/g,"WorkerScope").replace(/actor_await/g,"await");
    check(block(source)===block(collectorLines),"compatibility and worker collector implementations agree");
  },

  async rpc_short_pages(W, check) {
    const offsets = [];
    W.control.reply = m => {
      if (m.action !== "rpc") return {result:true};
      offsets.push(m.offset);
      return {result: offsets.length === 1 ? "success([v(a),v(b)],true)" : "success([v(c)],false)"};
    };
    await startToplevel(W);
    deliver(W, "'$call'(findall(X,rpc('https://example.org',p(X),[limit(5)]),Xs),[template(Xs)])");
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
    const m = await nSends(W, 1);
    check(/\[-\(mismatch,empty\)\],false\)/.test(m[m.length-1] || ""), "reply selected and workers cleaned before output mismatch: " + m.join(" | "));
    check(W.posted.some(x=>x.action==="exit"), "cleanup requested before failure");
  },

  async server_yield_reply_mismatch_consumed(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,42-wrong),(server_yield(42,wanted)->R=unexpected;R=mismatch),receive({42-_ -> Left=leftover},[timeout(0),on_timeout(Left=empty)])),[template(R-Left)])");
    const m = await nSends(W, 1);
    check(/\[-\(mismatch,empty\)\],false\)/.test(m[m.length-1] || ""), "server reply consumed before mismatch: " + m.join(" | "));
  },

  async worker_exit_policy(W, check) {
    installCleanupReplies(W);
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,down(worker,r,killed)),catch(swi_wasm_actor_bridge:wait_first([worker],_,continue,stop),E,true)),[template(E)])");
    const m = await nSends(W, 1);
    check(/worker_exit\(worker,killed\)/.test(m[m.length-1] || ""), "unexplained first-solution exit is an error: " + m.join(" | "));
    deliver(W, "'$call'((self(S),send(S,down(worker,r,killed)),send(S,other-ok),swi_wasm_actor_bridge:wait_first([worker,other],R,continue,continue)),[template(R)])");
    const n = W.sends.length;
    await until(()=>messages(W).some(x=>/\[ok\],false\)/.test(x)));
    check(messages(W).some(x=>/\[ok\],false\)/.test(x)), "on_error(continue) accepts a later winner: " + messages(W).slice(n-1).join(" | "));
    deliver(W, "'$call'((self(S),send(S,down(worker,r,true)),catch(swi_wasm_actor_bridge:par_yield([worker],worker,_),E,true)),[template(E)])");
    await until(()=>messages(W).some(x=>/worker_exit\(worker,true\)/.test(x)));
    check(messages(W).some(x=>/worker_exit\(worker,true\)/.test(x)), "normal exit without an answer is an error");
    deliver(W, "'$call'((self(S),send(S,down(worker,r,exception(original))),catch(swi_wasm_actor_bridge:wait_first([worker],_,continue,stop),E,true)),[template(E)])");
    await until(()=>messages(W).some(x=>/\[original\],false\)/.test(x)));
    check(messages(W).some(x=>/\[original\],false\)/.test(x)), "worker exceptions preserve their original term");
  },

  async parallel_out_of_order_and_post_answer_exit(W, check) {
    await startToplevel(W);
    deliver(W, "'$call'((self(S),send(S,later-[b]),send(S,down(later,r,true)),send(S,first-[a]),send(S,down(first,r,killed)),swi_wasm_actor_bridge:par_yield([first,later],first,A),swi_wasm_actor_bridge:par_yield([first,later],later,B)),[template(A-B)])");
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
