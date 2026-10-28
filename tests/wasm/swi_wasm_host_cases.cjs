// Demonstrator presentation cases; runtime assertions live in swi-wasm-node.
'use strict';
const fs=require('node:fs'),path=require('node:path');
const demoHtml=fs.readFileSync(path.join(__dirname,'../../web/demonstrator.html'),'utf8');
const html=demoHtml;
module.exports.method=function(name,next) {
 const start=html.indexOf('          '+name+': function')+('          '+name+': ').length;
 const tail=html.slice(start),boundary=new RegExp('\\n[ \\t]+'+next+': function').exec(tail);
 if(!boundary)throw new Error('Missing demonstrator host method '+name);
 const chunk=tail.slice(0,boundary.index),closing='\n          }';
 return Function('return ('+chunk.slice(0,chunk.lastIndexOf(closing+',')+closing.length)+')')();
};
module.exports.cases=function({CLIENT,NATIVE_ROOT,PID,QPID,ROOT,WASM_DIR,abort,asynchronousAnswerContract,behaviourBody,behaviourSource,behaviourWarningContract,booleanLanguageCases,bootWorker,childSpecContract,clientOptionCases,compatibilityClientHarness,deliver,done,fs,installCleanupReplies,installServerMonitorCoordinator,invalidChildSpecs,invalidClientGoal,invalidSpawnGoal,invalidWrapperGoal,isolatedPromiseEngine,loadCompatibilityStatecharts,mainOutputOrdering,messages,nSends,namedCreationContract,path,portableMain,portableTextCases,portableWorker,promiseEngineIsolationContract,remoteAliasCleanupContract,remoteNamedCreationContract,remoteNamingPeer,remoteSynchronousContract,remoteSynchronousInterruptProbe,remoteSynchronousPeer,runExternalContractCases,runOne,runtime,runtimeSource,scopedWorkerCoordinator,serverMonitorCoordinator,shutdownInterruptProbe,shutdownProbeSource,simpleChart,sleep,spawnOptionCases,spawnOptionMainHarness,spawnOptionWorkerReplies,spawnSync,startActor,startToplevel,startupFaultSource,statechartMonitorContract,supervisorExhaustionContract,supervisorHaltContract,supervisorHaltInterruptProbe,supervisorNotificationContract,supervisorOrderContract,supervisorRestartContract,supervisorRestartPolicyContract,supervisorShutdownContract,supervisorStartupContract,supervisorWaitContract,supervisorWaitInterruptProbe,synchronousToplevelContract,synchronousWaitInterruptProbe,until,uriLanguageCases,validSpawnOptions,workbenchMethod,wrapperCall,wrapperKinds,wrapperOptionCases,wrapperSetup,wrapperWorkerReplies}) {
 const html=demoHtml+'\n'+runtimeSource;
 return {
  async compatibility_supervisor_shutdown(W,check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const dummy={S:{onmessage:()=>{}},control:{}};
    const host=scopedWorkerCoordinator(dummy,"main");
    try {
      const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
      engine.FS.writeFile("/compat_shutdown.pl",source);engine.prolog.query("use_module('/compat_shutdown.pl')").once();
      host.swiWasmActorMainMailbox=[];host.swiWasmActorMainWaiters=[];
      host.deliverSwiWasmMainActorMessage=workbenchMethod("deliverSwiWasmMainActorMessage","deliverSwiWasmRemoteResult");
      host.receiveSwiWasmActorMessage=workbenchMethod("receiveSwiWasmActorMessage","cancelSwiWasmMainActorWaiters");
      dummy.S.onmessage=({data})=>{if(data.command==="deliver")host.deliverSwiWasmMainActorMessage(data.message);};
      host.swiWasmStatechartOwnsActorTraffic=()=>false;
      workbenchMethod("installSwiWasmActorBridge","randomSwiIdentity").call(host);
      global.self.swiWasmBehaviourSource=()=>behaviourSource;
      global.self.setTimeout=setTimeout;global.self.clearTimeout=clearTimeout;
      global.self.workerTestError=e=>e.message;
      async function run(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
      await supervisorShutdownContract(run,host,check);
      await supervisorExhaustionContract(run,host,check);
      host.cancelSwiWasmMainActorWaiters=workbenchMethod("cancelSwiWasmMainActorWaiters","resetSwiWasmActorWorkers");
      host.abortSwiWasmQuery=workbenchMethod("abortSwiWasmQuery","abortSwiWasm2Query");
      host.swiWasmProlog=engine.prolog;host.swiWasmQueryPending=true;
      host.setPendingCompletionMessage=()=>{};host.recordSessionEvent=()=>{};
      const probe=shutdownInterruptProbe(host);
      try {
        const running=run(probe.goal).then(()=>false,()=>true);
        check(await until(()=>host.shutdownStopSeen&&host.swiWasmActorMainWaiters.length>0),"main shutdown wait is suspended");
        host.abortSwiWasmQuery(null);
        check(await running&&host.swiWasmActorMonitors.length===0,"main interruption withdraws the shutdown monitor");
        check(await run("receive({never->true},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_supervisor_shutdown(R),[]),user:shutdown_wait_pid(P),exit(P,kill)"),"main interruption drains private reply filters and leaves engine usable");
      } finally {probe.restore();}
    } finally {await host.stop();}
  },
  async remote_synchronous_main(W,check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const dummy={S:{onmessage:()=>{}},control:{}};
    const host=scopedWorkerCoordinator(dummy,"main");host.testOwner="main";let peer;
    try {
      const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
      engine.FS.writeFile("/compat_shutdown.pl",source);engine.prolog.query("use_module('/compat_shutdown.pl')").once();
      host.swiWasmActorMainMailbox=[];host.swiWasmActorMainWaiters=[];
      host.deliverSwiWasmMainActorMessage=workbenchMethod("deliverSwiWasmMainActorMessage","deliverSwiWasmRemoteResult");
      host.receiveSwiWasmActorMessage=workbenchMethod("receiveSwiWasmActorMessage","cancelSwiWasmMainActorWaiters");
      dummy.S.onmessage=({data})=>{if(data.command==="deliver")host.deliverSwiWasmMainActorMessage(data.message);};
      host.swiWasmStatechartOwnsActorTraffic=()=>false;
      workbenchMethod("installSwiWasmActorBridge","randomSwiIdentity").call(host);
      global.self.swiWasmBehaviourSource=()=>behaviourSource;
      global.self.setTimeout=setTimeout;global.self.clearTimeout=clearTimeout;
      global.self.workerTestError=e=>e.message;
      async function run(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
      peer=await remoteSynchronousContract(run,host,check);
      host.cancelSwiWasmMainActorWaiters=workbenchMethod("cancelSwiWasmMainActorWaiters","resetSwiWasmActorWorkers");
      host.abortSwiWasmQuery=workbenchMethod("abortSwiWasmQuery","abortSwiWasm2Query");
      host.swiWasmProlog=engine.prolog;host.swiWasmQueryPending=true;
      host.setPendingCompletionMessage=()=>{};host.recordSessionEvent=()=>{};
      for(const makeProbe of [remoteSynchronousInterruptProbe]) {
      host.swiWasmQueryPending=true;
      const probe=makeProbe(host);
      try {
        const running=run(probe.goal).then(()=>false,()=>true);
        check(await until(()=>host.shutdownStopSeen&&host.swiWasmActorMainWaiters.length>0),"main supervisor request wait is suspended");
        host.abortSwiWasmQuery(null);
        check(await running&&host.swiWasmActorMonitors.length===0,"main interruption withdraws the supervisor request monitor");
        check(await run("receive({never->true},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_server_monitor(R),[]),user:remote_sync_pid(P),toplevel_halt(P)"),"main interruption drains private reply filters and leaves engine usable");
      } finally {probe.restore();}
      }
    } finally {if(peer)peer.restore();await host.stop();}
  },
  async compatibility_supervisor_request_wait(W,check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const dummy={S:{onmessage:()=>{}},control:{}};
    const host=scopedWorkerCoordinator(dummy,"main");
    try {
      const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
      engine.FS.writeFile("/compat_shutdown.pl",source);engine.prolog.query("use_module('/compat_shutdown.pl')").once();
      host.swiWasmActorMainMailbox=[];host.swiWasmActorMainWaiters=[];
      host.deliverSwiWasmMainActorMessage=workbenchMethod("deliverSwiWasmMainActorMessage","deliverSwiWasmRemoteResult");
      host.receiveSwiWasmActorMessage=workbenchMethod("receiveSwiWasmActorMessage","cancelSwiWasmMainActorWaiters");
      dummy.S.onmessage=({data})=>{if(data.command==="deliver")host.deliverSwiWasmMainActorMessage(data.message);};
      host.swiWasmStatechartOwnsActorTraffic=()=>false;
      workbenchMethod("installSwiWasmActorBridge","randomSwiIdentity").call(host);
      global.self.swiWasmBehaviourSource=()=>behaviourSource;
      global.self.setTimeout=setTimeout;global.self.clearTimeout=clearTimeout;
      global.self.workerTestError=e=>e.message;
      async function run(goal){let n=0;await engine.prolog.forEach(goal,()=>n++);return n===1;}
      await synchronousToplevelContract(run,host,check);
      await supervisorWaitContract(run,host,check);
      await supervisorHaltContract(run,host,check);
      host.cancelSwiWasmMainActorWaiters=workbenchMethod("cancelSwiWasmMainActorWaiters","resetSwiWasmActorWorkers");
      host.abortSwiWasmQuery=workbenchMethod("abortSwiWasmQuery","abortSwiWasm2Query");
      host.swiWasmProlog=engine.prolog;host.swiWasmQueryPending=true;
      host.setPendingCompletionMessage=()=>{};host.recordSessionEvent=()=>{};
      for(const makeProbe of [supervisorWaitInterruptProbe,supervisorHaltInterruptProbe,synchronousWaitInterruptProbe]) {
      host.swiWasmQueryPending=true;
      const probe=makeProbe(host);
      try {
        const running=run(probe.goal).then(()=>false,()=>true);
        check(await until(()=>host.shutdownStopSeen&&host.swiWasmActorMainWaiters.length>0),"main supervisor request wait is suspended");
        host.abortSwiWasmQuery(null);
        check(await running&&host.swiWasmActorMonitors.length===0,"main interruption withdraws the supervisor request monitor");
        check(await run("receive({never->true},[timeout(0)]),findall(R,swi_wasm_actor_bridge:retiring_server_monitor(R),[]),user:shutdown_wait_pid(P),exit(P,kill)"),"main interruption drains private reply filters and leaves engine usable");
      } finally {probe.restore();}
      }
    } finally {await host.stop();}
  },
  async compatibility_query_exception_display(W, check) {
    const body=html.split("swiWasmRpcProlog: function() {")[1].split("\n          },")[0];
    const source=Function(body).call({swiWasmBehaviourProlog:()=>behaviourSource});
    const engine=await require(path.join(ROOT,"web/swipl-bundle.js"))({arguments:["-q","--nosignals"]});
    // Use the terminal's actual query runner and display formatter. Only UI
    // rendering and paging input are substituted; Prolog executes normally.
    const helpers=Function("SwiWasmNode",html.slice(html.indexOf("var splitTopLevelArgs ="),html.indexOf("function isDollarVarStartChar"))+
      "\nreturn {exceptionDisplayTerm, normalizeErrorText, normalizeRuntimeErrorMessage};")(runtime);
    Object.assign(global,helpers);
    const displayed=[],solutions=[],dets=[];
    const noop=()=>{};
    let completed;
    const host={swiWasmProlog:engine.prolog,swiWasmModule:engine,
      loadSwiWasmMainSource:runtime.methods.loadSwiWasmMainSource,
      driveSwiWasmMainQuery:runtime.methods.driveSwiWasmMainQuery,
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
  async statechart_monitors_main(W,check) { await statechartMonitorContract(W,check,true); },
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
  }
 };
};

module.exports.synchronousTutorial=async function(run,check) {
  const tutorial=fs.readFileSync(path.join(__dirname,'../../web/actor-profile-tutorial.html'),"utf8");
  const example=tutorial.match(/<pre id="toplevel-synchronous-pages">([\s\S]*?)<\/pre>/)[1]
    .replace(/^\?\-\s*/,"").trim().replace(/\.$/,"");
  check(await run(example+",First==success(Top,[a,b],true),Last==success(Top,[c],false),var(X)"),
    "tutorial synchronous paging example returns both pages and keeps caller variables independent");

};
