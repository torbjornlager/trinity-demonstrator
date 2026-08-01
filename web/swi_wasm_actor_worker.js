(function() {
  "use strict";

  var selfPidText = "";
  var mailbox = [];
  var waiters = [];
  var outputBuffer = "";
  var started = false;
  var nextRequestId = 1;
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
  var workerConfiguration = {};
  var statechartTimers = {};

  if (typeof self.window === "undefined") {
    self.window = self;
  }

  function post(type, fields) {
    var input = fields || {};
    var message = { type: type };
    if (Object.prototype.hasOwnProperty.call(input, "pid")) {
      message.pid = input.pid;
    } else if (selfPidText) {
      message.pid = workerRole === "shell_toplevel" && /^[0-9]+$/.test(selfPidText)
        ? Number(selfPidText)
        : selfPidText;
    }
    ["data", "more"].forEach(function(key) {
      if (Object.prototype.hasOwnProperty.call(input, key)) {
        message[key] = input[key];
      }
    });
    Object.keys(input).forEach(function(key) {
      if (key !== "type" && key !== "pid" && key !== "data" && key !== "more") {
        message[key] = input[key];
      }
    });
    self.postMessage(message);
  }

  function flushOutput(force) {
    var index;
    var chunk;
    while ((index = outputBuffer.indexOf("\n")) >= 0) {
      chunk = outputBuffer.slice(0, index + 1);
      outputBuffer = outputBuffer.slice(index + 1);
      postWorkerOutput(chunk);
    }
    if (force && outputBuffer) {
      postWorkerOutput(outputBuffer);
      outputBuffer = "";
    }
  }

  function postWorkerOutput(text) {
    if (workerRole === "shell_toplevel") {
      post("output", { data: String(text).replace(/\n$/, "") });
    } else {
      post("output", { output: String(text) });
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
  // Thus source passed to src_text/1 is nested inside a quoted literal in
  // that goal.  A natural `\\+` in the source would otherwise be treated as
  // SWI's undefined `\\+` character escape before src_text/1 sees it.
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

  function readSpawnSourceAtom(text, start) {
    var output = "";
    var index = start;
    if (text.charAt(index) !== "'") {
      throw new Error("toplevel_spawn src_text/1 must contain a quoted atom");
    }
    index += 1;
    while (index < text.length) {
      var character = text.charAt(index);
      if (character === "'") {
        if (text.charAt(index + 1) === "'") {
          output += "'";
          index += 2;
          continue;
        }
        return output;
      }
      if (character === "\\" && text.charAt(index + 1) === "\\") {
        output += "\\";
        index += 2;
        continue;
      }
      output += character;
      index += 1;
    }
    throw new Error("unterminated src_text/1 option");
  }

  function toplevelSpawnSource(optionsText) {
    var text = String(optionsText || "[]");
    var match = /(?:^|[,\[])\s*src_text\s*\(\s*/.exec(text);
    return match
      ? readSpawnSourceAtom(text, match.index + match[0].length)
      : "";
  }

  function callIntegerOption(optionsText, name, defaultValue) {
    var expression = new RegExp(
      "(?:^|[,\\[])\\s*" + name + "\\s*\\(\\s*([0-9]+)\\s*\\)"
    );
    var match = expression.exec(String(optionsText || "[]"));
    return match ? Number(match[1]) : defaultValue;
  }

  function toplevelCallOptions(optionsText) {
    var text = String(optionsText || "[]");
    return {
      limit: callIntegerOption(text, "limit", 1),
      offset: callIntegerOption(text, "offset", 0),
      once: /(?:^|[,\[])\s*once\s*\(\s*true\s*\)/.test(text)
    };
  }

  function toplevelCallHasSourceOption(optionsText) {
    return /(?:^|[,\[])\s*(?:src_text|load_text)\s*\(/.test(String(optionsText || "[]"));
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
    if (text === "main") return "main@localhost";
    return /^[1-9][0-9]{9}$/.test(text) ? text + "@localhost" : text;
  }

  function localizePid(pidText) {
    var text = String(pidText || "").trim();
    if (/^main\s*@\s*'?localhost'?$/.test(text)) return "main";
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

  function actorRpc(nodeText, goalText, templateText, offset, limit, loadText,
                    remoteTimeout, once, httpTimeout) {
    return actorRequest("rpc", {
      node: String(nodeText || ""),
      goal: String(goalText || "true"),
      template: String(templateText || "true"),
      offset: Number(offset || 0),
      limit: Number(limit || 10000000000),
      loadText: String(loadText || ""),
      remoteTimeout: Number(remoteTimeout),
      once: once === true || String(once) === "true",
      httpTimeout: Number(httpTimeout)
    });
  }

  function actorPromiseStart(nodeText, goalText, templateText, offset, limit,
                             loadText, remoteTimeout, once, httpTimeout) {
    var ref = makePromiseRef();
    // Attach a rejection handler immediately so an HTTP failure cannot become
    // an unhandled promise rejection while Prolog is doing other work.
    pendingRpcPromises[ref] = actorRpc(
      nodeText, goalText, templateText, offset, limit, loadText,
      remoteTimeout, once, httpTimeout
    ).then(function(value) {
      return { ok: true, value: value };
    }, function(error) {
      return { ok: false, error: error && error.message ? error.message : String(error) };
    });
    return ref;
  }

  function makePromiseRef() {
    var ref;
    var min = 1000000000;
    // Keep the value within SWI-WASM's tagged-integer range while retaining
    // the canonical ten-digit opaque-reference presentation.
    var span = 73741824;
    do {
      if (self.crypto && typeof self.crypto.getRandomValues === "function") {
        var values = new Uint32Array(1);
        self.crypto.getRandomValues(values);
        ref = min + (values[0] % span);
      } else {
        ref = min + Math.floor(Math.random() * span);
      }
      ref = Math.floor(ref);
    } while (Object.prototype.hasOwnProperty.call(pendingRpcPromises, String(ref)));
    return ref;
  }

  function actorLoadUri(uriText) {
    return actorRequest("src_uri", { uri: String(uriText || "") });
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

  function actorStatechartSpawn(sourceKind, sourceText) {
    return actorRequest("statechart_spawn", {
      sourceKind: String(sourceKind || ""),
      source: String(sourceText || "")
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

  function actorTerminalOutput(text, termText) {
    if (workerRole === "statechart_actor") {
      post("terminal_output", {
        term: String(termText || "true")
      });
      return true;
    }
    postWorkerOutput(String(text) + "\n");
    return true;
  }

  function structuredCompound(value) {
    var functor;
    var args;
    if (!value || typeof value !== "object" || value.$t !== "t") {
      return null;
    }
    functor = value.functor || Object.keys(value).find(function(key) {
      return key !== "$t";
    });
    if (!functor) {
      return null;
    }
    args = typeof value.arguments === "function" ? value.arguments() : value[functor];
    if (Array.isArray(args) && args.length === 1 && Array.isArray(args[0])) {
      args = args[0];
    }
    return { functor: functor, args: Array.isArray(args) ? args : [] };
  }

  function structuredList(value) {
    if (Array.isArray(value)) {
      return value;
    }
    if (value && typeof value === "object" && value.$t === "l" && Array.isArray(value.v)) {
      return value.v;
    }
    return [];
  }

  function formatAtom(value) {
    var text = String(value);
    if (/^[a-z][A-Za-z0-9_]*$/.test(text) ||
        text === "[]" || text === "!" || text === "true" || text === "false") {
      return text;
    }
    return "'" + text.replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'";
  }

  function formatValue(value) {
    var compound;
    var args;
    if (value === null) return "null";
    if (value === undefined) return "_";
    if (typeof value === "number" || typeof value === "bigint") return String(value);
    if (typeof value === "boolean") return value ? "true" : "false";
    if (typeof value === "string") return formatAtom(value);
    if (Array.isArray(value)) {
      return "[" + value.map(formatValue).join(",") + "]";
    }
    if (value && value.$t === "v") {
      return "_" + (value.v !== undefined ? value.v : "");
    }
    if (value && value.$t === "s") {
      return JSON.stringify(String(value.v));
    }
    if (value && value.$t === "l") {
      var items = Array.isArray(value.v) ? value.v.map(formatValue) : [];
      return "[" + items.join(",") +
        (value.t !== undefined ? "|" + formatValue(value.t) : "") + "]";
    }
    compound = structuredCompound(value);
    if (compound) {
      args = compound.args;
      if (compound.functor === "@" && args.length === 2) {
        return formatValue(args[0]) + "@" + formatValue(args[1]);
      }
      if (compound.functor === "/" && args.length === 2) {
        return formatValue(args[0]) + "/" + formatValue(args[1]);
      }
      if (compound.functor === "-" && args.length === 2) {
        return formatValue(args[0]) + "-" + formatValue(args[1]);
      }
      if (compound.functor === "=" && args.length === 2) {
        return formatValue(args[0]) + "=" + formatValue(args[1]);
      }
      if (compound.functor === "," && args.length === 2) {
        return "(" + formatValue(args[0]) + "," + formatValue(args[1]) + ")";
      }
      if (args.length === 0) return formatAtom(compound.functor);
      return formatAtom(compound.functor) + "(" + args.map(formatValue).join(",") + ")";
    }
    return String(value);
  }

  function displayRows(value) {
    return structuredList(value).map(function(row) {
      var display = {};
      if (row && typeof row === "object") {
        Object.keys(row).forEach(function(key) {
          if (/^[A-Z_]/.test(key) && key !== "_" && !(row[key] && row[key].$t === "v")) {
            display[key] = formatValue(row[key]);
          }
        });
      }
      return display;
    });
  }

  function actorToplevelEvent(value, text) {
    var eventValue = value;
    var compound;
    var args;
    var data;
    try {
      eventValue = JSON.parse(JSON.stringify(value));
    } catch (_) {
    }
    // Publish a final non-newline fragment before its query answer.
    flushOutput(true);
    compound = structuredCompound(eventValue);
    if (!compound) {
      post("error", { data: String(text || "Unexpected toplevel event") });
      return true;
    }
    args = compound.args;
    if (compound.functor === "success") {
      post("success", {
        data: displayRows(args[1]),
        more: args[2] === true || args[2] === "true"
      });
    } else if (compound.functor === "failure") {
      post("failure", {});
    } else if (compound.functor === "error") {
      post("error", { data: String(text || formatValue(args[1])) });
    } else if (compound.functor === "output" || compound.functor === "terminal_output") {
      data = typeof args[1] === "string" ? args[1] : formatValue(args[1]);
      post("output", { data: data });
    } else if (compound.functor === "prompt") {
      data = typeof args[1] === "string" ? args[1] : formatValue(args[1]);
      post("prompt", { data: data });
    } else {
      post("error", { data: String(text || "Unexpected toplevel event") });
    }
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
  self.actorToplevelEvent = actorToplevelEvent;
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
      "    toplevel_halt/1, toplevel_halt/2,",
      "    toplevel_stop/1, toplevel_abort/1,",
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
      "    rpc/2, rpc/3, promise/3, promise/4, yield/2, yield/3, runtime_property/1",
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
      "runtime_property(implementation(swi_wasm_worker)).",
      "runtime_property(persistent(false)).",
      "runtime_property(inbound_addressable(false)).",
      "runtime_property(dom(false)).",
      "runtime_property(actor_isolation(web_worker)).",
      "runtime_property(hard_termination(true)).",
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
      "        Pid-Goal -> receive({down(Pid, _, true) -> true}) ;",
      "        down(FailedPid, _, false) if memberchk(FailedPid, Pids) ->",
      "            worker_tidy_all(Pids), !, fail ;",
      "        down(FailedPid, _, exception(Error)) if memberchk(FailedPid, Pids) ->",
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
      "        down(FailedPid, _, false) if memberchk(FailedPid, Pids) ->",
      "            ( OnFail == continue -> selectchk(FailedPid, Pids, Rest),",
      "              wait_first(Rest, Solution, OnFail, OnError)",
      "            ; worker_tidy_all(Pids), !, fail ) ;",
      "        down(FailedPid, _, exception(Error)) if memberchk(FailedPid, Pids) ->",
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
      "    receive({down(Pid, CleanupRef, _) -> true}),",
      "    worker_drain(Pid).",
      "worker_drain(Pid) :-",
      "    receive({",
      "        Pid-_ -> worker_drain(Pid) ;",
      "        down(Pid, _, _) -> worker_drain(Pid)",
      "    }, [timeout(0)]).",
      "",
      "canonical_source_option(src_text(Text), src_text(Text)).",
      "canonical_source_option(src_list(Terms), src_list(Terms)).",
      "canonical_source_option(src_uri(URI), src_uri(URI)).",
      "canonical_source_option(src_predicates(PIs), src_predicates(PIs)).",
      "canonical_source_option(load_text(Text), src_text(Text)).",
      "canonical_source_option(load_list(Terms), src_list(Terms)).",
      "canonical_source_option(load_uri(URI), src_uri(URI)).",
      "canonical_source_option(load_predicates(PIs), src_predicates(PIs)).",
      "source_option_member(Canonical, Options) :-",
      "    member(Option, Options),",
      "    canonical_source_option(Option, Canonical).",
      "",
      "statechart_spawn(Pid, Options) :-",
      "    ( member(TraceOption, Options), TraceOption = trace(_)",
      "    -> throw(error(domain_error(statechart_spawn_option, TraceOption), statechart_spawn/2))",
      "    ; true",
      "    ),",
      "    ( source_option_member(src_text(Source), Options) -> SourceKind = text",
      "    ; source_option_member(src_uri(Source), Options) -> SourceKind = uri",
      "    ; throw(error(domain_error(statechart_source_option, src_text_or_src_uri), statechart_spawn/2))",
      "    ),",
      "    Promise := actorStatechartSpawn(#SourceKind, #Source),",
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
      "        down(Pid, Ref, _Reason) ->",
      "            Reply = killed",
      "    }, [timeout(Timeout), on_timeout((",
      // actorExit resolves after the coordinator has terminated the Worker and
      // emitted down/3. Waiting for that notification again can miss it and
      // leave the shell parked forever.
      "            exit(Pid, kill),",
      "            Reply = killed",
      "        ))]).",
      "",
      "collect_spawn_source(Options, Source) :-",
      "    findall(Text, spawn_source_option(Options, Text), Texts),",
      "    atomic_list_concat(Texts, '\\n', Source).",
      "",
      "spawn_source_option(Options, Text) :-",
      "    source_option_member(src_text(Text), Options).",
      "spawn_source_option(Options, Text) :-",
      "    source_option_member(src_list(Terms), Options),",
      "    findall(ClauseText, (member(Term, Terms), clause_source_text(Term, ClauseText)), ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "spawn_source_option(Options, Text) :-",
      "    source_option_member(src_predicates(Indicators), Options),",
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
      "    Offset = 0,",
      "    option(limit(Limit), Options, 10000000000),",
      "    rpc_transport_options(Options, RemoteTimeout, Once, HTTPTimeout),",
      "    collect_rpc_load_text(Options, LoadText),",
      "    worker_rpc_page(NodeText, GoalText, TemplateText, Template, Offset, Limit, LoadText, RemoteTimeout, Once, HTTPTimeout).",
      "",
      "worker_rpc_page(NodeText, GoalText, TemplateText, Template, Offset, Limit, LoadText, RemoteTimeout, Once, HTTPTimeout) :-",
      "    Promise := actorRpc(#NodeText, #GoalText, #TemplateText, #Offset, #Limit, #LoadText, #RemoteTimeout, #Once, #HTTPTimeout),",
      "    await(Promise, ResponseText),",
      "    (   catch(term_string(Response, ResponseText), _, fail)",
      "    ->  true",
      "    ;   throw(rpc_error(parse_failed))",
      "    ),",
      "    (   Response = success(Slice, true)",
      "    ->  ( member(Bound, Slice), Template = Bound",
      "        ; Once == false,",
      "          NextOffset is Offset + Limit,",
      "          worker_rpc_page(NodeText, GoalText, TemplateText, Template, NextOffset, Limit, LoadText, RemoteTimeout, Once, HTTPTimeout)",
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
      "    rpc_transport_options(Options, RemoteTimeout, Once, HTTPTimeout),",
      "    collect_rpc_load_text(Options, LoadText),",
      "    Ref := actorPromiseStart(#NodeText, #GoalText, #TemplateText, #Offset, #Limit, #LoadText, #RemoteTimeout, #Once, #HTTPTimeout).",
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
      "rpc_transport_options(Options, RemoteTimeout, Once, HTTPTimeout) :-",
      "    option(timeout(RemoteTimeout0), Options, none),",
      "    normalize_optional_timeout(RemoteTimeout0, RemoteTimeout),",
      "    option(once(Once0), Options, false),",
      "    normalize_boolean(Once0, Once),",
      "    option(http_timeout(HTTPTimeout0), Options, none),",
      "    normalize_optional_timeout(HTTPTimeout0, HTTPTimeout).",
      "",
      "normalize_optional_timeout(none, -1) :- !.",
      "normalize_optional_timeout(Value, Timeout) :-",
      "    must_be(number, Value),",
      "    Timeout is max(0, Value).",
      "",
      "normalize_boolean(true, true) :- !.",
      "normalize_boolean(false, false) :- !.",
      "normalize_boolean(Value, _) :-",
      "    throw(error(domain_error(boolean, Value), rpc/3)).",
      "",
      "collect_rpc_load_text(Options, LoadText) :-",
      "    findall(Text, rpc_load_text(Options, Text), Texts),",
      "    atomic_list_concat(Texts, '\\n', LoadText).",
      "",
      "rpc_load_text(Options, Text) :-",
      "    source_option_member(src_text(Source), Options),",
      "    ( atom(Source) -> atom_string(Source, Text0) ; string(Source) -> Text0 = Source ; term_string(Source, Text0) ),",
      "    Text := actorEnsureFinalFullStop(#Text0).",
      "rpc_load_text(Options, Text) :-",
      "    source_option_member(src_list(Terms), Options),",
      "    findall(ClauseText, (member(Term, Terms), clause_source_text(Term, ClauseText)), ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "rpc_load_text(Options, Text) :-",
      "    source_option_member(src_predicates(Indicators), Options),",
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
      "    source_option_member(src_uri(URI), Options),",
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
      "transportable_term(Term) :-",
      "    acyclic_term(Term),",
      "    term_attvars(Term, []),",
      "    \\+ (sub_term(Sub, Term), nonvar(Sub), blob(Sub, BlobType), BlobType \\== text, BlobType \\== reserved_symbol).",
      "must_be_transportable_term(Term) :-",
      "    ( transportable_term(Term) -> true",
      "    ; throw(error(type_error(transportable_term, Term), send/2)) ).",
      "",
      "Pid ! Message :- send(Pid, Message).",
      "",
      "toplevel_event_text(error(_, Error), Text) :- !, term_string(Error, Text).",
      "toplevel_event_text(Message, Text) :- term_string(Message, Text).",
      "",
      "send(terminal, Message) :-",
      "    shell_toplevel_role, !,",
      "    catch(flush_output(user_output), _, true),",
      "    catch(flush_output(user_error), _, true),",
      "    toplevel_event_text(Message, Text),",
      "    _ := actorToplevelEvent(#Message, #Text).",
      "",
      "send(Pid, Message) :-",
      "    must_be_transportable_term(Message),",
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
      "    must_be_transportable_term(Message),",
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
      "    receive({down(_, Ref, _) -> flush_down(Ref)}, [timeout(0)]),",
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
      "            catch(load_private_source('/worker_user_code.pl'), Error, send(Target0, error(Pid, Error)))",
      "        }),",
      "    (   Session == false",
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
      "toplevel_halt(Pid) :- exit(Pid, true).",
      "",
      "%  await/2 is not permitted in a setup_call_cleanup/3 cleanup in",
      "%  SWI-WASM. Down delivery retires the monitor in the coordinator;",
      "%  the final demonitor is therefore an idempotent bridge cleanup.",
      "toplevel_halt(Pid, Reply) :-",
      "    monitor(Pid, Ref),",
      "    toplevel_halt(Pid),",
      "    receive({down(Pid, Ref, _) -> Reply = true}),",
      "    demonitor(Ref, [flush]).",
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
      "    term_string(Term, TermText),",
      "    _ := actorTerminalOutput(#Text, #TermText).",
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
      Prolog.query("statechart_wasm:set_trace_hook(user:statechart_trace_hook)").once();
    });
  }

  function start(message) {
    if (started) {
      post("error", { error: "worker actor already started" });
      return;
    }
    selfPidText = String(message.pid || "");
    workerRole = String(message.role || workerConfiguration.role || "actor");
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
      inheritedSource = String(message.source !== undefined
        ? message.source
        : (message.src_text || ""));
      behaviourSource = String(message.behaviourSource || workerConfiguration.behaviourSource || "");
      installActorPredicates();
      return installSharedDatabase().then(function() {
        consultSource(inheritedSource, "/worker_user_code.pl");
        return (workerRole === "statechart_actor" ? installStatechartRuntime(message) : Promise.resolve()).then(function() {
          post(workerRole === "shell_toplevel" ? "spawned" : "ready", {});
          return runGoal(message.goal || workerConfiguration.goal || "true");
        });
      });
    }).catch(function(error) {
      flushOutput(true);
      post("error", { error: String(error) });
    });
  }

  self.onmessage = function(event) {
    var message = event && event.data ? event.data : {};
    if (message.command === "configure") {
      workerConfiguration = Object.assign({}, message);
      return;
    }
    if (message.command === "start") {
      start(message);
      return;
    }
    if (message.command === "toplevel_spawn") {
      var spawnSource;
      try {
        spawnSource = toplevelSpawnSource(message.options || "[]");
      } catch (error) {
        post("error", { error: String(error) });
        return;
      }
      // Input compatibility for an older controller. Current controllers put
      // source only in the canonical options field.
      if (spawnSource === "" &&
          Object.prototype.hasOwnProperty.call(message, "src_text")) {
        spawnSource = String(message.src_text || "");
      }
      start(Object.assign({}, workerConfiguration, {
        command: "toplevel_spawn",
        pid: message.pid,
        options: message.options || "[]",
        source: spawnSource,
        role: "shell_toplevel"
      }));
      return;
    }
    if (message.command === "deliver") {
      deliver(message.message || "true");
      return;
    }
    if (message.command === "toplevel_call" && workerRole === "shell_toplevel") {
      if (Object.prototype.hasOwnProperty.call(message, "src_text") ||
          toplevelCallHasSourceOption(message.options)) {
        post("error", { data: "Unsupported toplevel_call source option" });
        return;
      }
      var callOptions = toplevelCallOptions(message.options || "[]");
      deliver("'$call_text'(" + JSON.stringify(escapeNestedPrologNegation(message.goal || "true")) + "," +
              callOptions.limit + "," + callOptions.offset + "," +
              (callOptions.once ? "true" : "false") + ")");
      return;
    }
    if (message.command === "toplevel_next" && workerRole === "shell_toplevel") {
      deliver("'$next'([])");
      return;
    }
    if (message.command === "toplevel_stop" && workerRole === "shell_toplevel") {
      deliver("'$stop'");
      post("stop", {});
      return;
    }
    if (message.command === "toplevel_respond" && workerRole === "shell_toplevel") {
      // Mirror the main-thread reader: an empty line is end_of_file; otherwise
      // strip a single trailing '.' (the read/1 terminator) and parenthesise
      // the answer so the whole line is ONE argument term.  Without the
      // parentheses a bare comma or operator (e.g. read of `a, b.`) would turn
      // the message into '$input'/3 and the shell's receive({'$input'(_, A)})
      // would never match, hanging the prompt.
      var inputLine = message.input == null ? "" : String(message.input);
      var inputBody = inputLine.replace(/\.[ \t]*$/, "");
      var inputArg = inputBody.trim() === "" ? "end_of_file" : "(" + inputBody + ")";
      deliver("'$input'(terminal," + inputArg + ")");
      post("responded", {});
      return;
    }
    if (message.command === "toplevel_abort" && workerRole === "shell_toplevel") {
      abortCurrentGoal();
      post("abort", {});
      return;
    }
    if (message.command === "toplevel_halt" && workerRole === "shell_toplevel") {
      post("halted", {});
      self.close();
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
