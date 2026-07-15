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

  // A shell goal is parsed once more in the worker's private Prolog engine.
  // Thus source passed to load_text/1 is nested inside a quoted literal in
  // that goal.  A natural `\\+` in the source would otherwise be treated as
  // SWI's undefined `\\+` character escape before load_text/1 sees it.
  // Protect only an unescaped backslash before `+` inside a quoted literal;
  // an already escaped `\\\\+` and an ordinary `\\+` goal operator remain
  // unchanged.
  function escapeNestedPrologNegation(text) {
    var source = String(text || "");
    var output = "";
    var quote = "";
    var index = 0;

    while (index < source.length) {
      var character = source.charAt(index);
      if (!quote) {
        if (character === "'" || character === '"') {
          quote = character;
        }
        output += character;
        index += 1;
        continue;
      }
      if (character !== "\\") {
        output += character;
        if (character === quote) {
          quote = "";
        }
        index += 1;
        continue;
      }

      var start = index;
      while (index < source.length && source.charAt(index) === "\\") {
        index += 1;
      }
      var slashCount = index - start;
      output += source.slice(start, index);
      if (source.charAt(index) === "+" && slashCount % 2 === 1) {
        output += "\\";
      }
      // An odd run escapes a matching quote, so it cannot close the literal.
      if (source.charAt(index) === quote && slashCount % 2 === 1) {
        output += source.charAt(index);
        index += 1;
      }
    }
    return output;
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
    return actorRequest("make_ref", {});
  }

  function qualifyLocalPid(pidText) {
    var text = String(pidText || "").trim();
    return /^[1-9][0-9]{9}$/.test(text) ? text + "@localhost" : text;
  }

  function localizePid(pidText) {
    var text = String(pidText || "").trim();
    var match = /^([1-9][0-9]{9})\s*@\s*'?localhost'?$/.exec(text);
    return match ? match[1] : text;
  }

  function actorSend(toText, messageText) {
    var to = localizePid(toText);
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
      from: qualifyLocalPid(selfPidText)
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

  function actorEnsureFinalFullStop(text) {
    var source = String(text);
    return /\.\s*$/.test(source) ? source : source + ".";
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

  function actorLoadUri(uriText) {
    return actorRequest("load_uri", { uri: String(uriText || "") });
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
    var target = localizePid(targetText || selfPidText);
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
    var target = localizePid(targetText || selfPidText);
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
  self.actorEnsureFinalFullStop = actorEnsureFinalFullStop;
  self.actorRpc = actorRpc;
  self.actorPromiseStart = actorPromiseStart;
  self.actorLoadUri = actorLoadUri;
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
  // A parent passes its complete runtime source to the coordinator when
  // spawning a child. The behaviour runtime is already installed in the
  // bridge module, so it must not also be copied into the user program.
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
    Prolog.query("swi_wasm_actor_bridge:load_private_source(" + JSON.stringify(path) + ")").once();
  }

  function installSharedDatabase() {
    if (!Module || !Module.FS) {
      return Promise.reject(new Error("SWI-WASM shared database requires the virtual filesystem"));
    }
    return fetch("/wasm/shared_db.pl", { cache: "no-store" }).then(function(response) {
      if (!response.ok) {
        throw new Error("HTTP " + response.status + " for /wasm/shared_db.pl");
      }
      return response.text();
    }).then(function(sourceText) {
      // Shared node code gets the same actor API and operators as ordinary
      // Web Prolog actor modules.  Keep this loader concern out of the shared
      // source so users can write receive/1 and Pid ! Message naturally.
      Module.FS.writeFile("/worker_shared_db.pl",
        ":- use_module('/worker_actor_bridge.pl').\n" + sourceText);
      Prolog.query("use_module(library(modules))").once();
      Prolog.query("load_files('/worker_shared_db.pl',[module(wasm_shared_db),silent(true)])").once();
      Prolog.query("add_import_module(user,wasm_shared_db,start)").once();
    });
  }

  function installActorPredicates() {
    var bridgeSource = [
      ":- module(swi_wasm_actor_bridge, [",
      "    op(800, xfx, !),",
      "    op(200, xfx, @),",
      "    op(1000, xfy, if),",
      "    self/1,",
      "    spawn/1, spawn/2, spawn/3, spawn_worker_actor/2,",
      "    actors/1, make_ref/1, canonical_pid/2,",
      "    send/2, send/3, (!)/2, cancel/1,",
      "    monitor/2, demonitor/1, demonitor/2,",
      "    exit/1, exit/2,",
      "    register/2, register_service/2,",
      "    unregister/1, unregister_service/1,",
      "    whereis/2, whereis_service/2,",
      "    respond/2,",
      "    toplevel_spawn/1, toplevel_spawn/2,",
      "    toplevel_call/2, toplevel_call/3,",
      "    toplevel_next/1, toplevel_next/2,",
      "    toplevel_halt/2, toplevel_stop/1, toplevel_abort/1,",
      "    statechart_spawn/2, statechart_halt/2, statechart_halt/3,",
      "    output/1, output/2, terminal_output/1, terminal_output/2,",
      "    input/2, input/3, with_io_target/2, flush/0,",
      "    receive/1, receive/2,",
      "    server_spawn/3, server_spawn/4, server_request/3, server_request/4,",
      "    server_promise/3, server_promise/4, server_yield/2, server_yield/3, server_yield/4,",
      "    server_upgrade/2, server_upgrade/3, server_halt/2, server_stop/2,",
      "    supervisor_spawn/2, supervisor_spawn/3, supervisor_spawn_child/3,",
      "    supervisor_terminate_child/3, supervisor_delete_child/3, supervisor_respawn_child/3,",
      "    supervisor_which_children/2, supervisor_count_children/2, supervisor_halt/1, supervisor_stop/1,",
      "    parallel/1, first_solution/2, first_solution/3,",
      "    rpc/2, rpc/3, promise/3, promise/4, yield/2, yield/3",
      "]).",
      ":- use_module(library(wasm)).",
      ":- use_module(library(apply)).",
      ":- use_module(library(error)).",
      ":- use_module(library(lists)).",
      ":- use_module(library(option)).",
      ":- op(800, xfx, !).",
      ":- op(200, xfx, @).",
      ":- op(1000, xfy, if).",
      ":- meta_predicate spawn(:), spawn(:, -), spawn(:, -, +), toplevel_call(+, :), toplevel_call(+, :, +), receive(:), receive(:, +), with_io_target(+, 0), parallel(:), first_solution(?, :), first_solution(?, :, +).",
      ":- dynamic deferred/1, io_target/1.",
      ":- dynamic suppress_shared_override_warnings/0.",
      ":- multifile user:message_hook/3.",
      workerRole === "shell_toplevel" ? "shell_toplevel_role." : "shell_toplevel_role :- fail.",
      "",
      "self(" + qualifyLocalPid(selfPidText) + ").",
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
      "        term_string(LocalPid, PidText),",
      "        Pid = LocalPid@localhost,",
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
      "parallel(QualifiedGoals) :-",
      "    strip_module(QualifiedGoals, Module, Goals0),",
      "    must_be(list, Goals0),",
      "    maplist(qualify_actor_goal(Module), Goals0, Goals),",
      "    maplist(par_solve, Goals, Pids),",
      "    maplist(par_yield(Pids), Pids, Goals).",
      "",
      "qualify_actor_goal(Module, Goal, Module:Goal).",
      "",
      "par_solve(Goal, Pid) :-",
      "    self(Self),",
      "    spawn((call(Goal), send(Self, Pid-Goal)), Pid, [monitor(true)]).",
      "",
      "par_yield(Pids, Pid, Goal) :-",
      "    receive({",
      "        Pid-Goal -> receive({down(_, Pid, true) -> true}) ;",
      "        down(_, FailedPid, false) if memberchk(FailedPid, Pids) ->",
      "            worker_tidy_all(Pids), !, fail ;",
      "        down(_, FailedPid, exception(Error)) if memberchk(FailedPid, Pids) ->",
      "            worker_tidy_all(Pids), throw(Error)",
      "    }).",
      "",
      "first_solution(Solution, QualifiedGoals) :-",
      "    first_solution_(Solution, QualifiedGoals, [on_fail(continue), on_error(stop)]).",
      "first_solution(Solution, QualifiedGoals, Options) :-",
      "    first_solution_(Solution, QualifiedGoals, Options).",
      "",
      "first_solution_(Solution, QualifiedGoals, Options) :-",
      "    must_be(list, Options),",
      "    maplist(valid_first_solution_option, Options),",
      "    option(on_fail(OnFail), Options, continue),",
      "    option(on_error(OnError), Options, stop),",
      "    must_be(oneof([stop, continue]), OnFail),",
      "    must_be(oneof([stop, continue]), OnError),",
      "    strip_module(QualifiedGoals, Module, Goals0),",
      "    must_be(list, Goals0),",
      "    maplist(qualify_actor_goal(Module), Goals0, Goals),",
      "    maplist(first_solve(Solution), Goals, Pids),",
      "    wait_first(Pids, Solution, OnFail, OnError).",
      "",
      "valid_first_solution_option(on_fail(_)) :- !.",
      "valid_first_solution_option(on_error(_)) :- !.",
      "valid_first_solution_option(Option) :-",
      "    throw(error(domain_error(first_solution_option, Option), first_solution/3)).",
      "",
      "first_solve(Solution, Goal, Pid) :-",
      "    self(Self),",
      "    spawn((call(Goal), send(Self, Pid-Solution)), Pid, [monitor(true)]).",
      "",
      "wait_first([], _, _, _) :- !, fail.",
      "wait_first(Pids, Solution, OnFail, OnError) :-",
      "    receive({",
      "        Winner-Solution if memberchk(Winner, Pids) ->",
      "            worker_tidy_all(Pids) ;",
      "        down(_, FailedPid, false) if memberchk(FailedPid, Pids) ->",
      "            ( OnFail == continue -> selectchk(FailedPid, Pids, Rest),",
      "              wait_first(Rest, Solution, OnFail, OnError)",
      "            ; worker_tidy_all(Pids), !, fail ) ;",
      "        down(_, FailedPid, exception(Error)) if memberchk(FailedPid, Pids) ->",
      "            ( OnError == continue -> selectchk(FailedPid, Pids, Rest),",
      "              wait_first(Rest, Solution, OnFail, OnError)",
      "            ; worker_tidy_all(Pids), throw(Error) )",
      "    }).",
      "",
      "worker_tidy_all(Pids) :- maplist(worker_tidy, Pids).",
      "worker_tidy(Pid) :-",
      "    demonitor(Pid, [flush]),",
      "    monitor(Pid, CleanupRef),",
      "    exit(Pid, kill),",
      "    receive({down(CleanupRef, Pid, _) -> true}),",
      "    worker_drain(Pid).",
      "worker_drain(Pid) :-",
      "    receive({",
      "        Pid-_ -> worker_drain(Pid) ;",
      "        down(_, Pid, _) -> worker_drain(Pid)",
      "    }, [timeout(0)]).",
      "",
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
      "    monitor(Pid, Ref),",
      "    send(Pid, '$statechart_stop'(Self)),",
      "    receive({",
      "        reply(Reply) ->",
      "            demonitor(Ref) ;",
      "        down(Ref, Pid, _Reason) ->",
      "            Reply = killed",
      "    }, [timeout(Timeout), on_timeout((",
      "            exit(Pid, kill),",
      "            receive({down(Ref, Pid, _) -> Reply = killed})",
      "        ))]).",
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
      "              catch(user:clause(Head, Body), _, fail),",
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
      "    Text := actorEnsureFinalFullStop(#Text0).",
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
      "rpc_load_text(Options, Text) :-",
      "    member(load_uri(URI), Options),",
      "    term_string(URI, URIText),",
      "    Promise := actorLoadUri(#URIText),",
      "    await(Promise, Text),",
      "    (Text = null -> throw(rpc_error(fetch_failed)) ; true).",
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
      "    Promise := actorMakeRef(),",
      "    await(Promise, RefText),",
      "    term_string(Ref, RefText).",
      "",
      "canonical_pid(Pid@localhost, Pid@localhost) :- integer(Pid), !.",
      "canonical_pid(Pid, Pid@localhost) :- integer(Pid), !.",
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
      "        term_string(LocalPid, PidText),",
      "        Pid = LocalPid@localhost,",
      "        term_string(swi_wasm_actor_bridge:ptcp(Pid, Target, Session), GoalText),",
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
      "            term_string(PlainGoal, GoalText, [variable_names(Bindings)]),",
      "            Goal = user:PlainGoal,",
      "            dict_create(Template, bindings, Bindings),",
      "            Options = [template(Template), limit(Limit0), offset(Offset), once(Once)],",
      "            toplevel_run_call(Goal, Options, Target0, Pid) ;",
      "        '$call'(Goal, Options) ->",
      "            toplevel_run_call(Goal, Options, Target0, Pid) ;",
      "        '$reload' ->",
      "            catch(load_private_source('/worker_user_code.pl'), Error, send(Target0, error(Pid, Error))) ;",
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
      "    strip_module(Goal0, GoalModule, PlainGoal),",
      "    Goal = GoalModule:PlainGoal,",
      "    arg(1, TargetBox, Target),",
      "    with_io_target(Target,",
      "        (   Once == true",
      "        ->  once(answer(Goal, Template, Offset, Limit, Answer0))",
      "        ;   answer(Goal, Template, Offset, Limit, Answer0)",
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
      "    ;   ( atom(Prompt) -> atom_string(Prompt, PromptText)",
      "        ; string(Prompt) -> PromptText = Prompt",
      "        ; term_string(Prompt, PromptText)",
      "        ),",
      "        Promise := actorInput(#PromptText),",
      "        await(Promise, AnswerText),",
      "        AnswerText \\== null,",
      "        term_string(Answer, AnswerText)",
      "    ).",
      "",
      "load_private_source(File) :-",
      "    setup_call_cleanup(",
      "        asserta(suppress_shared_override_warnings, Ref),",
      "        user:consult(File),",
      "        erase(Ref)",
      "    ),",
      "    restore_shared_db_imports.",
      "",
      "user:message_hook(redefined_procedure(_, _), warning, Lines) :-",
      "    suppress_shared_override_warnings,",
      "    member(url(File:_), Lines),",
      "    atom(File),",
      "    sub_atom(File, _, _, 0, 'worker_shared_db.pl').",
      "",
      "restore_shared_db_imports :-",
      "    ( current_module(wasm_shared_db)",
      "    -> forall(shadowing_empty_dynamic(Name, Arity), abolish(user:Name/Arity))",
      "    ; true",
      "    ).",
      "",
      "shadowing_empty_dynamic(Name, Arity) :-",
      "    current_predicate(user:Name/Arity),",
      "    atom(Name),",
      "    functor(Head, Name, Arity),",
      "    predicate_property(user:Head, dynamic),",
      "    \\+ predicate_property(user:Head, imported_from(_)),",
      "    predicate_property(user:Head, number_of_clauses(0)),",
      "    predicate_property(wasm_shared_db:Head, number_of_clauses(_)),",
      "    \\+ predicate_property(wasm_shared_db:Head, imported_from(_)).",
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
    ].concat(behaviourSource.split("\n")).join("\n");
    Prolog.query("use_module(library(wasm))").once();
    Prolog.query("use_module(library(option))").once();
    try { Prolog.query("use_module(library(lists))").once(); } catch (_) {}
    try { Prolog.query("use_module(library(apply))").once(); } catch (_) {}
    Module.FS.writeFile("/worker_actor_bridge.pl", bridgeSource);
    Prolog.query("use_module('/worker_actor_bridge.pl')").once();
    if (workerRole === "shell_toplevel") {
      Module.FS.writeFile("/worker_read_shim.pl",
        ":- catch(redefine_system_predicate(read(_)), _, true).\n" +
        ":- catch(redefine_system_predicate(read_term(_, _)), _, true).\n" +
        "read(Term) :- swi_wasm_actor_bridge:input(\"|:\", Term).\n" +
        "read_term(Term, _) :- swi_wasm_actor_bridge:input(\"|:\", Term).\n");
      Prolog.query("consult('/worker_read_shim.pl')").once();
    }
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
          var adapted = source.replace(/swi_wasm_actor_bridge:/g, "user:");
          adapted = adapted.replace(/self\(statechart\)\./g, "self(" + qualifyLocalPid(selfPidText) + ").");
          adapted = adapted.replace(/\[target\(statechart\)\|Options\]/g,
                                    "[target(" + qualifyLocalPid(selfPidText) + ")|Options]");
          return { name: name, source: adapted };
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
      inheritedSource = String(message.source || "");
      behaviourSource = String(message.behaviourSource || "");
      installActorPredicates();
      return installSharedDatabase().then(function() {
        consultSource(inheritedSource, "/worker_user_code.pl");
        return (workerRole === "statechart_actor" ? installStatechartRuntime(message) : Promise.resolve()).then(function() {
          post("ready", {});
          return runGoal(message.goal || "true");
        });
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
      deliver("'$call_text'(" + JSON.stringify(escapeNestedPrologNegation(message.goal || "true")) + "," +
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
