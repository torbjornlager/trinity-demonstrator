(function() {
  "use strict";

  var selfPidText = "";
  var mailbox = [];
  var waiters = [];
  var outputBuffer = "";
  var started = false;
  var nextRequestId = 1;
  var nextRefId = 1;
  var pendingRequests = {};
  var pendingRpcPromises = {};
  var Prolog = null;
  var Module = null;
  var exitReason = null;
  var abortRequested = false;
  var currentGoalText = "";
  var inheritedSource = "";
  var behaviourSource = "";
  var workerRole = "actor";
  var statechartTimers = {};

  if (typeof self.window === "undefined") {
    self.window = self;
  }

  function post(type, fields) {
    var message = fields || {};
    message.type = type;
    if (selfPidText && !Object.prototype.hasOwnProperty.call(message, "pid")) {
      message.pid = selfPidText;
    }
    self.postMessage(message);
  }

  function flushOutput(force) {
    var index;
    var chunk;
    while ((index = outputBuffer.indexOf("\n")) >= 0) {
      chunk = outputBuffer.slice(0, index + 1);
      outputBuffer = outputBuffer.slice(index + 1);
      post("output", { output: chunk });
    }
    if (force && outputBuffer) {
      post("output", { output: outputBuffer });
      outputBuffer = "";
    }
  }

  function deliver(messageText) {
    var text = String(messageText);
    if (waiters.length > 0) {
      waiters.shift().resolve(text);
      return;
    }
    mailbox.push(text);
  }

  function actorReceive(timeoutSeconds) {
    if (mailbox.length > 0) {
      return Promise.resolve(mailbox.shift());
    }
    return new Promise(function(resolve) {
      var waiter = { resolve: resolve, timer: null };
      var timeout = Number(timeoutSeconds);
      if (isFinite(timeout) && timeout >= 0) {
        waiter.timer = setTimeout(function() {
          var index = waiters.indexOf(waiter);
          if (index >= 0) {
            waiters.splice(index, 1);
          }
          resolve(null);
        }, timeout * 1000);
      }
      waiter.resolve = function(value) {
        if (waiter.timer !== null) {
          clearTimeout(waiter.timer);
        }
        resolve(value);
      };
      waiters.push(waiter);
    });
  }

  var REQUEST_TIMEOUT_MS = 30000;

  function actorRequest(action, fields) {
    var id = "worker_request(" + (nextRequestId++) + ")";
    return new Promise(function(resolve, reject) {
      // Without a timeout a lost coordinator reply would wedge the actor
      // (the Prolog await/2 never returns); reject so it surfaces as an
      // ordinary error instead.
      // User input is intentionally open-ended.  The coordinator presents a
      // non-blocking dialog, so a person taking more than 30 seconds must not
      // turn input/2 into a spurious request failure.
      var timer = action === "input" ? null : setTimeout(function() {
        if (pendingRequests[id]) {
          delete pendingRequests[id];
          reject(new Error("actor request timed out: " + action));
        }
      }, REQUEST_TIMEOUT_MS);
      pendingRequests[id] = {
        resolve: function(value) { if (timer) clearTimeout(timer); resolve(value); },
        reject: function(error) { if (timer) clearTimeout(timer); reject(error); }
      };
      post("request", Object.assign({ id: id, action: action }, fields || {}));
    });
  }

  function actorMakeRef() {
    return "ref(" + selfPidText + "," + (nextRefId++) + ")";
  }

  function actorSend(toText, messageText) {
    var to = String(toText);
    var message = String(messageText);
    if (to === selfPidText || to === "self") {
      deliver(message);
      return Promise.resolve(true);
    }
    return actorRequest("send", {
      to: to,
      message: message,
      // The coordinator turns this local pid into a connection-scoped
      // virtual recipient when the destination is remote.
      from: selfPidText
    });
  }

  function actorSendDelayed(toText, messageText, delaySeconds, idText) {
    return actorRequest("send_delayed", {
      to: String(toText),
      message: String(messageText),
      delay: Number(delaySeconds),
      id: String(idText)
    });
  }

  function actorCancel(idText) {
    return actorRequest("cancel", { id: String(idText) });
  }

  function actorSpawn(goalText, sourceText) {
    return actorRequest("spawn", {
      goal: String(goalText || "true"),
      source: String(sourceText || "")
    });
  }

  function actorReservePid() {
    return actorRequest("reserve_pid", {});
  }

  function actorSpawnWithPid(targetPidText, goalText, sourceText, nameText) {
    return actorRequest("spawn", {
      pid: String(targetPidText || ""),
      goal: String(goalText || "true"),
      source: String(sourceText || ""),
      name: String(nameText || "")
    });
  }

  function actorRemoteSpawn(nodeText, goalText, sourceText) {
    return actorRequest("remote_spawn", {
      node: String(nodeText || ""),
      goal: String(goalText || "true"),
      source: String(sourceText || "")
    });
  }

  function actorRemoteToplevelSpawn(nodeText, sourceText, sessionText) {
    return actorRequest("remote_toplevel_spawn", {
      node: String(nodeText || ""),
      source: String(sourceText || ""),
      session: String(sessionText || "false")
    });
  }

  function actorRpc(nodeText, goalText, templateText, offset, limit, loadText) {
    return actorRequest("rpc", {
      node: String(nodeText || ""),
      goal: String(goalText || "true"),
      template: String(templateText || "true"),
      offset: Number(offset || 0),
      limit: Number(limit || 10000),
      loadText: String(loadText || "")
    });
  }

  function actorPromiseStart(nodeText, goalText, templateText, offset, limit, loadText) {
    var ref = nextRefId++;
    // Attach a rejection handler immediately so an HTTP failure cannot become
    // an unhandled promise rejection while Prolog is doing other work.
    pendingRpcPromises[ref] = actorRpc(
      nodeText, goalText, templateText, offset, limit, loadText
    ).then(function(value) {
      return { ok: true, value: value };
    }, function(error) {
      return { ok: false, error: error && error.message ? error.message : String(error) };
    });
    return ref;
  }

  function actorPromiseWait(refValue, timeoutSeconds) {
    var ref = Number(refValue);
    var pending = pendingRpcPromises[ref];
    var timeout = Number(timeoutSeconds);
    if (!pending) return Promise.resolve(null);
    var timeoutMarker = {};
    var waited = pending;
    if (isFinite(timeout) && timeout >= 0) {
      waited = new Promise(function(resolve) {
        var timer = setTimeout(function() { resolve(timeoutMarker); }, timeout * 1000);
        pending.then(function(outcome) {
          clearTimeout(timer);
          resolve(outcome);
        });
      });
    }
    return waited.then(function(outcome) {
      if (outcome === timeoutMarker) return null;
      delete pendingRpcPromises[ref];
      if (!outcome.ok) throw new Error(outcome.error);
      return outcome.value;
    });
  }

  function actorStatechartSpawn(sourceKind, sourceText, traceText) {
    return actorRequest("statechart_spawn", {
      sourceKind: String(sourceKind || ""),
      source: String(sourceText || ""),
      trace: String(traceText || "false") === "true"
    });
  }

  function actorActors() {
    return actorRequest("actors", {});
  }

  function actorRegister(kind, nameText, targetPidText) {
    return actorRequest("register", {
      kind: String(kind || "actor"),
      name: String(nameText || ""),
      pid: String(targetPidText || selfPidText)
    });
  }

  function actorUnregister(kind, nameText) {
    return actorRequest("unregister", {
      kind: String(kind || "actor"),
      name: String(nameText || "")
    });
  }

  function actorWhereis(kind, nameText) {
    return actorRequest("whereis", {
      kind: String(kind || "actor"),
      name: String(nameText || "")
    });
  }

  function actorMonitor(targetText, refText) {
    return actorRequest("monitor", {
      target: String(targetText),
      ref: String(refText)
    });
  }

  function actorDemonitor(refText) {
    return actorRequest("demonitor", { ref: String(refText) });
  }

  function actorExit(targetText, reasonText) {
    var target = String(targetText || selfPidText);
    var reason = String(reasonText || "true");
    if (target === selfPidText || target === "self") {
      exitReason = reason;
      post("exit", { pid: selfPidText, reason: reason });
      return Promise.resolve(true);
    }
    return actorRequest("exit", {
      pid: target,
      reason: reason
    });
  }

  function actorAbort(targetText) {
    var target = String(targetText || selfPidText);
    if (target === selfPidText || target === "self") {
      return Promise.resolve(abortCurrentGoal());
    }
    return actorRequest("abort", { pid: target });
  }

  function abortCurrentGoal() {
    abortRequested = true;
    if (Prolog && typeof Prolog.abort === "function") {
      Prolog.abort();
      return true;
    }
    return false;
  }

  function actorTerminalOutput(text) {
    post("output", { output: String(text) + "\n" });
    return true;
  }

  function actorShellEvent(value, text) {
    var eventValue = value;
    try {
      eventValue = JSON.parse(JSON.stringify(value));
    } catch (_) {
    }
    // Publish a final non-newline fragment before its query answer.
    flushOutput(true);
    post("shell_event", { event: eventValue, text: String(text || "") });
    return true;
  }

  function actorSetDoneReason(reasonText) {
    exitReason = String(reasonText || "true");
    return true;
  }

  function actorInput(promptText) {
    return actorRequest("input", { prompt: String(promptText || "") });
  }

  self.actorMakeRef = actorMakeRef;
  self.actorReceive = actorReceive;
  self.actorSend = actorSend;
  self.actorSendDelayed = actorSendDelayed;
  self.actorCancel = actorCancel;
  self.actorSpawn = actorSpawn;
  self.actorReservePid = actorReservePid;
  self.actorSpawnWithPid = actorSpawnWithPid;
  self.actorRemoteSpawn = actorRemoteSpawn;
  self.actorRemoteToplevelSpawn = actorRemoteToplevelSpawn;
  self.actorRpc = actorRpc;
  self.actorPromiseStart = actorPromiseStart;
  self.actorPromiseWait = actorPromiseWait;
  self.actorStatechartSpawn = actorStatechartSpawn;
  self.actorActors = actorActors;
  self.actorRegister = actorRegister;
  self.actorUnregister = actorUnregister;
  self.actorWhereis = actorWhereis;
  self.actorMonitor = actorMonitor;
  self.actorDemonitor = actorDemonitor;
  self.actorExit = actorExit;
  self.actorAbort = actorAbort;
  self.actorTerminalOutput = actorTerminalOutput;
  self.actorShellEvent = actorShellEvent;
  self.actorSetDoneReason = actorSetDoneReason;
  self.actorInput = actorInput;
  self.swiWasmBehaviourSource = function() { return behaviourSource; };
  // A parent passes its complete runtime source to the coordinator when
  // spawning a child.  Treat that inherited source as the child program;
  // adding it as both behaviour and user source would duplicate clauses.
  self.swiWasmBehaviourSource = function() { return ""; };

  self.wasmStatechartTrace = function(text) {
    post("statechart_trace", { trace: String(text || "") });
    return true;
  };
  self.wasmStatechartSchedule = function(eventText, delaySeconds, idText) {
    var id = String(idText || "");
    var delay = Number(delaySeconds);
    if (!id || !isFinite(delay) || delay < 0) return false;
    self.wasmStatechartCancel(id);
    statechartTimers[id] = setTimeout(function() {
      delete statechartTimers[id];
      deliver(String(eventText || "timeout"));
    }, delay * 1000);
    return true;
  };
  self.wasmStatechartCancel = function(idText) {
    var id = String(idText || "");
    if (statechartTimers[id] !== undefined) {
      clearTimeout(statechartTimers[id]);
      delete statechartTimers[id];
    }
    return true;
  };
  self.wasmStatechartCancelAll = function() {
    Object.keys(statechartTimers).forEach(function(id) { clearTimeout(statechartTimers[id]); });
    statechartTimers = {};
    return true;
  };
  self.swiWasmStatechartMonitor = actorMonitor;
  self.swiWasmStatechartDemonitor = actorDemonitor;

  function consultSource(sourceText, fileName) {
    if (!sourceText || !Module || !Module.FS) {
      return;
    }
    var path = String(fileName || "/worker_user_code.pl");
    Module.FS.writeFile(path, String(sourceText));
    Prolog.query("consult(" + JSON.stringify(path) + ")").once();
  }

  function installActorPredicates() {
    var bridgeSource = [
      ":- use_module(library(wasm)).",
      ":- use_module(library(option)).",
      ":- op(800, xfx, !).",
      ":- op(200, xfx, @).",
      ":- op(1000, xfy, if).",
      ":- meta_predicate spawn(:), spawn(:, -), spawn(:, -, +), toplevel_call(+, :), toplevel_call(+, :, +), receive(:), receive(:, +), with_io_target(+, 0).",
      ":- dynamic deferred/1, io_target/1.",
      workerRole === "shell_toplevel" ? "shell_toplevel_role." : "shell_toplevel_role :- fail.",
      "",
      "self(" + selfPidText + ").",
      "",
      "spawn(Goal) :- spawn(Goal, _).",
      "",
      "spawn(Goal, Pid) :- spawn(Goal, Pid, []).",
      "",
      "spawn(Goal, Pid, Options) :-",
      "    option(node(Node), Options, localhost),",
      "    (   Node == localhost",
      "    ->  collect_spawn_source(Options, ExtraSource),",
      "        PidPromise := actorReservePid(),",
      "        await(PidPromise, PidText),",
      "        term_string(Pid, PidText),",
      "        term_string(Goal, GoalText),",
      "        ( option(name(Name), Options) -> term_string(Name, NameText) ; NameText = \"\" ),",
      "        Promise := actorSpawnWithPid(#PidText, #GoalText, #ExtraSource, #NameText),",
      "        await(Promise, SpawnedText),",
      "        SpawnedText == PidText",
      "    ;   collect_spawn_source(Options, ExtraSource),",
      "        term_string(Node, NodeText),",
      "        term_string(Goal, GoalText),",
      "        Promise := actorRemoteSpawn(#NodeText, #GoalText, #ExtraSource),",
      "        await(Promise, PidText),",
      "        term_string(Pid, PidText)",
      "    ),",
      "    install_spawn_monitor(Pid, Options).",
      "",
      "spawn_worker_actor(Goal, Pid) :- spawn(Goal, Pid).",
      "",
      "statechart_spawn(Pid) :- statechart_spawn(Pid, []).",
      "statechart_spawn(Pid, Options) :-",
      "    ( member(load_text(Source), Options) -> SourceKind = text",
      "    ; member(load_uri(Source), Options) -> SourceKind = uri",
      "    ; throw(error(domain_error(statechart_source_option, load_text_or_load_uri), statechart_spawn/2))",
      "    ),",
      "    ( option(trace(true), Options) -> Trace = true ; Trace = false ),",
      "    Promise := actorStatechartSpawn(#SourceKind, #Source, #Trace),",
      "    await(Promise, PidText),",
      "    term_string(Pid, PidText).",
      "",
      "statechart_halt(Pid, Reply) :- statechart_halt(Pid, Reply, 5).",
      "statechart_halt(Pid, Reply, Timeout) :-",
      "    self(Self),",
      "    send(Pid, '$statechart_stop'(Self)),",
      "    receive({reply(Reply) -> true}, [timeout(Timeout), on_timeout(Reply = timeout)]).",
      "",
      "collect_spawn_source(Options, Source) :-",
      "    findall(Text, spawn_source_option(Options, Text), Texts),",
      "    atomic_list_concat(Texts, '\\n', Source).",
      "",
      "spawn_source_option(Options, Text) :-",
      "    member(load_text(Text), Options).",
      "spawn_source_option(Options, Text) :-",
      "    member(load_list(Terms), Options),",
      "    findall(ClauseText, (member(Term, Terms), clause_source_text(Term, ClauseText)), ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "spawn_source_option(Options, Text) :-",
      "    member(load_predicates(Indicators), Options),",
      "    findall(ClauseText,",
      "            ( member(Name/Arity, Indicators),",
      "              functor(Head, Name, Arity),",
      "              catch(clause(Head, Body), _, fail),",
      "              (Body == true -> Clause = Head ; Clause = (Head :- Body)),",
      "              clause_source_text(Clause, ClauseText)",
      "            ),",
      "            ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "",
      "clause_source_text(Clause, Text) :-",
      "    copy_term(Clause, Copy),",
      "    numbervars(Copy, 0, _, [singletons(true)]),",
      "    with_output_to(string(Body), write_term(Copy, [quoted(true), numbervars(true)])),",
      "    string_concat(Body, '.', Text).",
      "",
      "rpc(Node, Goal) :- rpc(Node, Goal, []).",
      "",
      "rpc(Node, Goal, Options) :-",
      "    term_variables(Goal, Variables),",
      "    Template =.. [v|Variables],",
      "    term_string(Node, NodeText),",
      "    term_to_atom(Goal, GoalText),",
      "    term_to_atom(Template, TemplateText),",
      "    option(offset(Offset), Options, 0),",
      "    option(limit(Limit), Options, 10000),",
      "    collect_rpc_load_text(Options, LoadText),",
      "    worker_rpc_page(NodeText, GoalText, TemplateText, Template, Offset, Limit, LoadText).",
      "",
      "worker_rpc_page(NodeText, GoalText, TemplateText, Template, Offset, Limit, LoadText) :-",
      "    Promise := actorRpc(#NodeText, #GoalText, #TemplateText, #Offset, #Limit, #LoadText),",
      "    await(Promise, ResponseText),",
      "    (   catch(term_string(Response, ResponseText), _, fail)",
      "    ->  true",
      "    ;   throw(rpc_error(parse_failed))",
      "    ),",
      "    (   Response = success(Slice, true)",
      "    ->  ( member(Bound, Slice), Template = Bound",
      "        ; NextOffset is Offset + Limit,",
      "          worker_rpc_page(NodeText, GoalText, TemplateText, Template, NextOffset, Limit, LoadText)",
      "        )",
      "    ;   Response = success(Slice, false)",
      "    ->  member(Bound, Slice), Template = Bound",
      "    ;   Response = failure",
      "    ->  fail",
      "    ;   Response = error(Error)",
      "    ->  throw(rpc_error(Error))",
      "    ;   throw(rpc_error(unexpected_response))",
      "    ).",
      "",
      "promise(Node, Goal, Ref) :- promise(Node, Goal, Ref, []).",
      "",
      "promise(Node, Goal, Ref, Options) :-",
      "    option(template(Template), Options, Goal),",
      "    term_string(Node, NodeText),",
      "    term_to_atom(Goal, GoalText),",
      "    term_to_atom(Template, TemplateText),",
      "    option(offset(Offset), Options, 0),",
      "    option(limit(Limit), Options, 10000000000),",
      "    collect_rpc_load_text(Options, LoadText),",
      "    Ref := actorPromiseStart(#NodeText, #GoalText, #TemplateText, #Offset, #Limit, #LoadText).",
      "",
      "yield(Ref, Message) :- yield(Ref, Message, []).",
      "",
      "yield(Ref, Message, Options) :-",
      "    option(timeout(Timeout), Options, -1),",
      "    Promise := actorPromiseWait(#Ref, #Timeout),",
      "    await(Promise, ResponseText),",
      "    (   ResponseText = null",
      "    ->  option(on_timeout(OnTimeout), Options, true),",
      "        call(OnTimeout)",
      "    ;   catch(term_string(Message, ResponseText), _, throw(rpc_error(parse_failed)))",
      "    ).",
      "",
      "collect_rpc_load_text(Options, LoadText) :-",
      "    findall(Text, rpc_load_text(Options, Text), Texts),",
      "    atomic_list_concat(Texts, '\\n', LoadText).",
      "",
      "rpc_load_text(Options, Text) :-",
      "    member(load_text(Source), Options),",
      "    ( atom(Source) -> atom_string(Source, Text0) ; string(Source) -> Text0 = Source ; term_string(Source, Text0) ),",
      "    ( sub_string(Text0, _, _, 0, '.') -> Text = Text0 ; string_concat(Text0, '.', Text) ).",
      "rpc_load_text(Options, Text) :-",
      "    member(load_list(Terms), Options),",
      "    findall(ClauseText, (member(Term, Terms), clause_source_text(Term, ClauseText)), ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "rpc_load_text(Options, Text) :-",
      "    member(load_predicates(Indicators), Options),",
      "    findall(ClauseText,",
      "            ( member(Name/Arity, Indicators),",
      "              functor(Head, Name, Arity),",
      "              catch(user:clause(Head, Body), _, fail),",
      "              (Body == true -> Clause = Head ; Clause = (Head :- Body)),",
      "              clause_source_text(Clause, ClauseText)",
      "            ),",
      "            ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "",
      "install_spawn_monitor(Pid, Options) :-",
      "    option(monitor(true), Options, false),",
      "    !,",
      "    term_string(Pid, PidText),",
      "    Promise := actorMonitor(#PidText, #PidText),",
      "    await(Promise, _).",
      "install_spawn_monitor(_, _).",
      "",
      "actors(Pids) :-",
      "    Promise := actorActors(),",
      "    await(Promise, PidsText),",
      "    term_string(Pids, PidsText).",
      "",
      "make_ref(Ref) :-",
      "    RefText := actorMakeRef(),",
      "    term_string(Ref, RefText).",
      "",
      "canonical_pid(Pid, Pid).",
      "",
      "Pid ! Message :- send(Pid, Message).",
      "",
      "shell_event_text(error(_, Error), Text) :- !, term_string(Error, Text).",
      "shell_event_text(Message, Text) :- term_string(Message, Text).",
      "",
      "send(terminal, Message) :-",
      "    shell_toplevel_role, !,",
      "    catch(flush_output(user_output), _, true),",
      "    catch(flush_output(user_error), _, true),",
      "    shell_event_text(Message, Text),",
      "    _ := actorShellEvent(#Message, #Text).",
      "",
      "send(Pid, Message) :-",
      "    term_string(Pid, PidText),",
      "    term_string(Message, MessageText),",
      "    Promise := actorSend(#PidText, #MessageText),",
      "    await(Promise, Sent),",
      "    (   Sent == true",
      "    ->  true",
      "    ;   throw(error(existence_error(actor, Pid), send/2))",
      "    ).",
      "",
      "send(Pid, Message, Options) :-",
      "    option(delay(Delay), Options),",
      "    !,",
      "    delayed_send_id(Options, Id),",
      "    term_string(Pid, PidText),",
      "    term_string(Message, MessageText),",
      "    term_string(Id, IdText),",
      "    Promise := actorSendDelayed(#PidText, #MessageText, #Delay, #IdText),",
      "    await(Promise, Sent),",
      "    Sent == true.",
      "send(Pid, Message, _) :- send(Pid, Message).",
      "",
      "delayed_send_id(Options, Id) :-",
      "    (   member(id(Id0), Options)",
      "    ->  (var(Id0) -> make_ref(Id0) ; true),",
      "        Id = Id0",
      "    ;   make_ref(Id)",
      "    ).",
      "",
      "cancel(Id) :-",
      "    term_string(Id, IdText),",
      "    Promise := actorCancel(#IdText),",
      "    await(Promise, Cancelled),",
      "    Cancelled == true.",
      "",
      "monitor(Pid, Ref) :-",
      "    make_ref(Ref),",
      "    term_string(Pid, PidText),",
      "    term_string(Ref, RefText),",
      "    Promise := actorMonitor(#PidText, #RefText),",
      "    await(Promise, Monitored),",
      "    Monitored == true.",
      "",
      "demonitor(Ref) :- demonitor(Ref, []).",
      "",
      "demonitor(Ref, Options) :-",
      "    term_string(Ref, RefText),",
      "    Promise := actorDemonitor(#RefText),",
      "    await(Promise, _),",
      "    (   member(flush, Options)",
      "    ->  flush_down(Ref)",
      "    ;   true",
      "    ).",
      "",
      "flush_down(Ref) :-",
      "    receive({down(Ref, _, _) -> flush_down(Ref)}, [timeout(0)]),",
      "    !.",
      "flush_down(_).",
      "",
      "exit(Reason) :-",
      "    throw('$actor_exit'(Reason)).",
      "",
      "exit(Pid, Reason) :-",
      "    (   ( Pid == self ; self(Pid) )",
      "    ->  throw('$actor_exit'(Reason))",   // abort own goal, like exit/1 (desktop: thread_signal(exit))
      "    ;   term_string(Pid, PidText),",
      "        term_string(Reason, ReasonText),",
      "        Promise := actorExit(#PidText, #ReasonText),",
      "        await(Promise, Exited),",
      "        Exited == true",
      "    ).",
      "",
      "register(Name, Pid) :- register_name(actor, Name, Pid).",
      "register_service(Name, Pid) :- register_name(service, Name, Pid).",
      "",
      "register_name(Kind, Name, Pid) :-",
      "    term_string(Name, NameText),",
      "    term_string(Pid, PidText),",
      "    Promise := actorRegister(#Kind, #NameText, #PidText),",
      "    await(Promise, Registered),",
      "    (   Registered == true",
      "    ->  true",
      "    ;   throw(error(permission_error(register, actor_name, Name), register/2))",
      "    ).",
      "",
      "unregister(Name) :- unregister_name(actor, Name).",
      "unregister_service(Name) :- unregister_name(service, Name).",
      "",
      "unregister_name(Kind, Name) :-",
      "    term_string(Name, NameText),",
      "    Promise := actorUnregister(#Kind, #NameText),",
      "    await(Promise, _).",
      "",
      "whereis(Name, Pid) :- whereis_name(actor, Name, Pid).",
      "whereis_service(Name, Pid) :- whereis_name(service, Name, Pid).",
      "",
      "whereis_name(Kind, Name, Pid) :-",
      "    term_string(Name, NameText),",
      "    Promise := actorWhereis(#Kind, #NameText),",
      "    await(Promise, PidText),",
      "    PidText \\== \"undefined\",",
      "    term_string(Pid, PidText).",
      "",
      "respond(Pid, Answer) :-",
      "    self(Self),",
      "    send(Pid, '$input'(Self, Answer)).",
      "",
      "toplevel_spawn(Pid) :- toplevel_spawn(Pid, []).",
      "",
      "toplevel_spawn(Pid, Options) :-",
      "    option(node(Node), Options, localhost),",
      "    option(session(Session), Options, false),",
      "    collect_spawn_source(Options, ExtraSource),",
      "    (   Node == localhost",
      "    ->  self(Self),",
      "        option(target(Target), Options, Self),",
      "        PidPromise := actorReservePid(),",
      "        await(PidPromise, PidText),",
      "        term_string(Pid, PidText),",
      "        term_string(ptcp(Pid, Target, Session), GoalText),",
      "        Promise := actorSpawnWithPid(#PidText, #GoalText, #ExtraSource),",
      "        await(Promise, SpawnedText),",
      "        SpawnedText == PidText",
      "    ;   term_string(Node, NodeText),",
      "        term_string(Session, SessionText),",
      "        Promise := actorRemoteToplevelSpawn(#NodeText, #ExtraSource, #SessionText),",
      "        await(Promise, PidText),",
      "        term_string(Pid, PidText)",
      "    ),",
      "    install_spawn_monitor(Pid, Options),",
      "    maybe_register_toplevel_name(Options, Pid).",
      "",
      "maybe_register_toplevel_name(Options, Pid) :-",
      "    (   option(name(Name), Options)",
      "    ->  register(Name, Pid)",
      "    ;   true",
      "    ).",
      "",
      "ptcp(Pid, Target, Session) :-",
      "    catch(state_1(Pid, Target, Session), '$abort_goal', ptcp(Pid, Target, Session)).",
      "",
      "state_1(Pid, Target0, Session) :-",
      "    Control = control(continue),",
      "    receive({",
      "        '$call_text'(GoalText, Limit0, Offset, Once) ->",
      "            term_string(Goal, GoalText, [variable_names(Bindings)]),",
      "            dict_create(Template, bindings, Bindings),",
      "            Options = [template(Template), limit(Limit0), offset(Offset), once(Once)],",
      "            toplevel_run_call(Goal, Options, Target0, Pid) ;",
      "        '$call'(Goal, Options) ->",
      "            toplevel_run_call(Goal, Options, Target0, Pid) ;",
      "        '$reload' ->",
      "            catch(consult('/worker_user_code.pl'), Error, send(Target0, error(Pid, Error))) ;",
      "        '$halt'(From) ->",
      "            send(From, reply(true)),",
      "            nb_setarg(1, Control, halt)",
      "        }),",
      "    (   arg(1, Control, halt)",
      "    ->  true",
      "    ;   Session == false",
      "    ->  true",
      "    ;   state_1(Pid, Target0, Session)",
      "    ).",
      "",
      "toplevel_run_call(Goal, Options, Target0, Pid) :-",
      "            option(template(Template0), Options, Goal),",
      "            strip_module(Template0, _, Template),",
      "            option(offset(Offset), Options, 0),",
      "            option(limit(Limit0), Options, 10000000000),",
      "            option(once(Once), Options, false),",
      "            option(target(Target1), Options, Target0),",
      "            Limit = count(Limit0),",
      "            Target = target(Target1),",
      "            state_2(Goal, Template, Offset, Limit, Once, Target, Pid, Answer),",
      "            arg(1, Target, Out),",
      "            send(Out, Answer),",
      "            (   arg(3, Answer, true)",
      "            ->  state_3(Limit, Target)",
      "            ;   true",
      "            ).",
      "",
      "state_2(Goal0, Template, Offset, Limit, Once, TargetBox, Pid, Answer) :-",
      "    strip_module(Goal0, _, PlainGoal),",
      "    arg(1, TargetBox, Target),",
      "    with_io_target(Target,",
      "        (   Once == true",
      "        ->  once(answer(PlainGoal, Template, Offset, Limit, Answer0))",
      "        ;   answer(PlainGoal, Template, Offset, Limit, Answer0)",
      "        )),",
      "    apply_once_answer(Once, Answer0, Answer1),",
      "    add_pid(Answer1, Pid, Answer).",
      "",
      "state_3(Limit, Target) :-",
      "    receive({",
      "        '$next'(Options2) ->",
      "            (   option(limit(NewLimit), Options2)",
      "            ->  nb_setarg(1, Limit, NewLimit)",
      "            ;   true",
      "            ),",
      "            (   option(target(NewTarget), Options2)",
      "            ->  nb_setarg(1, Target, NewTarget)",
      "            ;   true",
      "            ),",
      "            fail ;",
      "        '$stop' -> true",
      "    }).",
      "",
      "answer(Goal, Template, Offset, Limit, Answer) :-",
      "    catch(call_cleanup(slice(Goal, Template, Offset, Limit, Slice), Det = true), Error, true),",
      "    (   nonvar(Error), Error == '$abort_goal'",
      "    ->  throw('$abort_goal')",
      "    ;   Slice == []",
      "    ->  Answer = failure",
      "    ;   nonvar(Error)",
      "    ->  Answer = error(Error)",
      "    ;   var(Det)",
      "    ->  Answer = success(Slice, true)",
      "    ;   Det == true",
      "    ->  Answer = success(Slice, false)",
      "    ).",
      "",
      "slice(Goal, Template, Offset, count(Limit), Slice) :-",
      "    findnsols(Limit, Template, offset(Offset, Goal), Slice).",
      "",
      "apply_once_answer(true, success(Slice, _), success(Slice, false)) :- !.",
      "apply_once_answer(_, Answer, Answer).",
      "",
      "add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).",
      "add_pid(failure, Pid, failure(Pid)).",
      "add_pid(error(Term), Pid, error(Pid, Term)).",
      "",
      "toplevel_call(Pid, Goal) :- toplevel_call(Pid, Goal, []).",
      "toplevel_call(Pid, Goal, Options) :- send(Pid, '$call'(Goal, Options)).",
      "",
      "toplevel_next(Pid) :- toplevel_next(Pid, []).",
      "toplevel_next(Pid, Options) :- send(Pid, '$next'(Options)).",
      "",
      "toplevel_halt(Pid, Reply) :-",
      "    self(Self),",
      "    send(Pid, '$halt'(Self)),",
      "    receive({reply(Reply) -> true}).",
      "",
      "toplevel_stop(Pid) :- send(Pid, '$stop').",
      "",
      "toplevel_abort(Pid) :-",
      "    term_string(Pid, PidText),",
      "    Promise := actorAbort(#PidText),",
      "    await(Promise, Aborted),",
      "    Aborted == true.",
      "",
      "output(Term) :- output(Term, []).",
      "",
      "output(Term, Options) :-",
      "    self(Self),",
      "    (   option(target(Target), Options)",
      "    ->  send(Target, output(Self, Term))",
      "    ;   io_target(Target)",
      "    ->  send(Target, output(Self, Term))",
      "    ;   terminal_output(Term)",
      "    ).",
      "",
      "terminal_output(Term) :- terminal_output(Term, []).",
      "",
      "terminal_output(Term, Options) :-",
      "    self(Self),",
      "    (   option(target(Target), Options)",
      "    ->  send(Target, terminal_output(Self, Term))",
      "    ;   io_target(Target)",
      "    ->  send(Target, terminal_output(Self, Term))",
      "    ;   terminal_output_direct(Term)",
      "    ).",
      "",
      "terminal_output_direct(Term) :-",
      "    (   string(Term)",
      "    ->  Text = Term",
      "    ;   term_string(Term, Text)",
      "    ),",
      "    _ := actorTerminalOutput(#Text).",
      "",
      "input(Prompt, Answer) :- input(Prompt, Answer, []).",
      "",
      "input(Prompt, Answer, Options) :-",
      "    self(Self),",
      "    (   option(target(Target), Options)",
      "    ->  send(Target, prompt(Self, Prompt)),",
      "        receive({'$input'(_, Answer) -> true})",
      "    ;   io_target(Target)",
      "    ->  send(Target, prompt(Self, Prompt)),",
      "        receive({'$input'(_, Answer) -> true})",
      "    ;   term_string(Prompt, PromptText),",
      "        Promise := actorInput(#PromptText),",
      "        await(Promise, AnswerText),",
      "        AnswerText \\== null,",
      "        term_string(Answer, AnswerText)",
      "    ).",
      "",
      "with_io_target(Target, Goal) :-",
      "    asserta(io_target(Target), Ref),",
      "    call_cleanup(call(Goal), erase(Ref)).",
      "",
      "flush :-",
      "    receive({Message ->",
      "        term_to_atom(Message, Atom),",
      "        atomics_to_string(['Shell got ', Atom], MessageString),",
      "        terminal_output(MessageString),",
      "        flush",
      "    }, [timeout(0)]).",
      "",
      "receive(Clauses) :- receive(Clauses, []).",
      "",
      "receive(Clauses, Options) :-",
      "    (   receive_plain_var(Clauses)",
      "    ->  throw(error(instantiation_error, receive/1))",
      "    ;   clause(deferred(Msg), true, Ref),",
      "        select_body(Clauses, Msg, Module, Body)",
      "    ->  erase(Ref),",
      "        call(Module:Body)",
      "    ;   receive_loop(Clauses, Options)",
      "    ).",
      "",
      "receive_plain_var(_:Var) :- var(Var), !.",
      "receive_plain_var({Var}) :- var(Var), !.",
      "receive_plain_var(Var) :- var(Var).",
      "",
      "receive_loop(Clauses, Options) :-",
      "    receive_timeout(Options, Timeout),",
      "    Promise := actorReceive(#Timeout),",
      "    await(Promise, MessageText),",
      "    (   MessageText = null",
      "    ->  option(on_timeout(Goal), Options, true),",
      "        clauses_module(Clauses, Module),",
      "        call(Module:Goal)",
      "    ;   term_string(Msg, MessageText),",
      "        (   select_body(Clauses, Msg, Module, Body)",
      "        ->  call(Module:Body)",
      "        ;   assertz(deferred(Msg)),",
      "            receive_loop(Clauses, Options)",
      "        )",
      "    ).",
      "",
      "receive_timeout(Options, Timeout) :-",
      "    (   option(timeout(Timeout0), Options)",
      "    ->  Timeout = Timeout0",
      "    ;   Timeout = -1",
      "    ).",
      "",
      "clauses_module(M:_, M) :- !.",
      "clauses_module(_, user).",
      "",
      "select_body(M:{Clauses}, Message, M, Body) :- !,",
      "    select_body_aux(Clauses, Message, M, Body).",
      "select_body(M:Clauses, Message, M, Body) :- !,",
      "    select_body_aux(Clauses, Message, M, Body).",
      "select_body({Clauses}, Message, user, Body) :- !,",
      "    select_body_aux(Clauses, Message, user, Body).",
      "select_body(Clauses, Message, user, Body) :-",
      "    select_body_aux(Clauses, Message, user, Body).",
      "",
      "select_body_aux(Head, Message, _, true) :-",
      "    var(Head),",
      "    !,",
      "    Head = Message.",
      "",
      "select_body_aux((Clause ; Clauses), Message, Module, Body) :-",
      "    (   select_body_aux(Clause, Message, Module, Body)",
      "    ;   select_body_aux(Clauses, Message, Module, Body)",
      "    ).",
      "select_body_aux((Head -> Body), Message, Module, Body) :-",
      "    (   subsumes_term(if(Pattern, Guard), Head)",
      "    ->  if(Pattern, Guard) = Head,",
      "        subsumes_term(Pattern, Message),",
      "        Pattern = Message,",
      "        catch(once(Module:Guard), _, fail)",
      "    ;   subsumes_term(Head, Message),",
      "        Head = Message",
      "    )."
    ].join("\n");
    Prolog.query("use_module(library(wasm))").once();
    Prolog.query("use_module(library(option))").once();
    try { Prolog.query("use_module(library(lists))").once(); } catch (_) {}
    try { Prolog.query("use_module(library(apply))").once(); } catch (_) {}
    Module.FS.writeFile("/worker_actor_bridge.pl", bridgeSource);
    Prolog.query("consult('/worker_actor_bridge.pl')").once();
  }

  function runGoal(goalText) {
    started = true;
    post("started", {});
    outputBuffer = "";
    currentGoalText = String(goalText || "true");
    abortRequested = false;
    return Prolog.forEach(
      "term_string(Goal, GoalText), catch(catch((call(Goal) -> Outcome = true ; Outcome = false), '$actor_exit'(Reason), Outcome = Reason), Error, Outcome = exception(Error)), term_string(Outcome, OutcomeText), _ := actorSetDoneReason(#OutcomeText)",
      { GoalText: currentGoalText },
      function(answer) {
        flushOutput(true);
        post("answer", { answer: answer || {} });
      },
      { heartbeat: 10000 }
    ).then(function() {
      flushOutput(true);
      if (abortRequested && /^ptcp\(/.test(currentGoalText)) {
        abortRequested = false;
        exitReason = null;
        post("aborted", {});
        return runGoal(currentGoalText);
      }
      post("done", { reason: exitReason || "true" });
    }).catch(function(error) {
      flushOutput(true);
      if (abortRequested && /^ptcp\(/.test(currentGoalText)) {
        abortRequested = false;
        exitReason = null;
        post("aborted", { error: String(error) });
        return runGoal(currentGoalText);
      }
      post("error", { error: String(error) });
    });
  }

  function installStatechartRuntime(message) {
    var names = [
      "statechart_wasm_runtime.pl",
      "statechart_wasm_model.pl",
      "statechart_wasm_exec.pl",
      "statechart_wasm.pl"
    ];
    try { Module.FS.mkdir("/wasm"); } catch (_) {}
    return Promise.all(names.map(function(name) {
      return fetch("/wasm/" + name, { cache: "no-store" }).then(function(response) {
        if (!response.ok) throw new Error("HTTP " + response.status + " for /wasm/" + name);
        return response.text().then(function(source) {
          return { name: name, source: source.replace(/swi_wasm_actor_bridge:/g, "user:") };
        });
      });
    })).then(function(files) {
      files.forEach(function(file) {
        Module.FS.writeFile("/wasm/" + file.name, file.source);
      });
      if (!Prolog.query("use_module('/wasm/statechart_wasm.pl')").once()) {
        throw new Error("use_module('/wasm/statechart_wasm.pl') failed");
      }
      Module.FS.writeFile("/statechart.xml", String(message.statechartXml || ""));
      consultSource([
        ":- use_module(library(readutil)).",
        "statechart_trace_hook(Event) :- term_to_atom(Event, Text), _ := wasmStatechartTrace(#Text).",
        "statechart_actor_loop :-",
        "    read_file_to_string('/statechart.xml', XML, []),",
        "    statechart_wasm:statechart_start(text(XML)),",
        "    statechart_actor_wait.",
        "statechart_actor_wait :-",
        "    ( statechart_wasm:statechart_running ->",
        "        receive({",
        "            '$statechart_stop'(From) ->",
        "                statechart_wasm:statechart_stop,",
        "                send(From, reply(stopped))",
        "        ;   Event ->",
        "                statechart_wasm:statechart_send(Event),",
        "                statechart_actor_wait",
        "        })",
        "    ; true",
        "    )."
      ].join("\n"), "/worker_statechart_actor.pl");
      if (message.statechartTrace === true) {
        Prolog.query("statechart_wasm:set_trace_hook(user:statechart_trace_hook)").once();
      }
    });
  }

  function start(message) {
    if (started) {
      post("error", { error: "worker actor already started" });
      return;
    }
    selfPidText = String(message.pid || "");
    workerRole = String(message.role || "actor");
    exitReason = null;
    if (!/^[1-9][0-9]{9}$/.test(selfPidText)) {
      post("error", { error: "invalid worker actor pid" });
      return;
    }
    importScripts("/swipl-bundle.js");
    SWIPL({
      arguments: ["-q", "--nosignals"],
      on_output: function(text) {
        outputBuffer += String(text);
        flushOutput(false);
      }
    }).then(function(module) {
      Module = module;
      Prolog = module.prolog;
      installActorPredicates();
      inheritedSource = String(message.source || "");
      behaviourSource = String(message.behaviourSource || "");
      consultSource(behaviourSource, "/worker_behaviour.pl");
      consultSource(inheritedSource, "/worker_user_code.pl");
      return (workerRole === "statechart_actor" ? installStatechartRuntime(message) : Promise.resolve()).then(function() {
        post("ready", {});
        return runGoal(message.goal || "true");
      });
    }).catch(function(error) {
      flushOutput(true);
      post("error", { error: String(error) });
    });
  }

  self.onmessage = function(event) {
    var message = event && event.data ? event.data : {};
    if (message.command === "start") {
      start(message);
      return;
    }
    if (message.command === "deliver") {
      deliver(message.message || "true");
      return;
    }
    if (message.command === "shell_load" && workerRole === "shell_toplevel") {
      inheritedSource = String(message.source || "");
      if (Module && Module.FS) {
        Module.FS.writeFile("/worker_user_code.pl", inheritedSource);
      }
      deliver("'$reload'");
      return;
    }
    if (message.command === "shell_call" && workerRole === "shell_toplevel") {
      deliver("'$call_text'(" + JSON.stringify(String(message.goal || "true")) + "," +
              Number(message.limit || 1) + "," + Number(message.offset || 0) + "," +
              (message.once === true ? "true" : "false") + ")");
      return;
    }
    if (message.command === "shell_next" && workerRole === "shell_toplevel") {
      deliver("'$next'([limit(" + Number(message.limit || 1) + ")])");
      return;
    }
    if (message.command === "shell_stop" && workerRole === "shell_toplevel") {
      deliver("'$stop'");
      return;
    }
    if (message.command === "shell_input" && workerRole === "shell_toplevel") {
      // Mirror the main-thread reader: an empty line is end_of_file; otherwise
      // strip a single trailing '.' (the read/1 terminator) and parenthesise
      // the answer so the whole line is ONE argument term.  Without the
      // parentheses a bare comma or operator (e.g. read of `a, b.`) would turn
      // the message into '$input'/3 and the shell's receive({'$input'(_, A)})
      // would never match, hanging the prompt.
      var inputLine = message.answer == null ? "" : String(message.answer);
      var inputBody = inputLine.replace(/\.[ \t]*$/, "");
      var inputArg = inputBody.trim() === "" ? "end_of_file" : "(" + inputBody + ")";
      deliver("'$input'(terminal," + inputArg + ")");
      return;
    }
    if (message.command === "reply") {
      var pending = pendingRequests[String(message.id || "")];
      if (!pending) {
        return;
      }
      delete pendingRequests[String(message.id || "")];
      if (message.ok) {
        pending.resolve(message.result);
      } else {
        pending.reject(new Error(String(message.error || "actor request failed")));
      }
      return;
    }
    if (message.command === "abort") {
      abortCurrentGoal();
      return;
    }
    if (message.command === "terminate") {
      self.close();
    }
  };
}());
