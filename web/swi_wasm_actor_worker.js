// Shared by the browser page and Worker. The page loads this existing asset
// for the lifecycle store; only a Worker runs the actor bootstrap below.
function createSwiWasmPromiseStore(options) {
  "use strict";
  var items = Object.create(null), nextCollector = 1;
  var now = options.now || Date.now;
  var schedule = options.setTimer || setTimeout;
  var unschedule = options.clearTimer || clearTimeout;
  var lifetime = options.ttlMs === undefined ? 300000 : options.ttlMs;
  function settleWait(entry, value) {
    var collector = entry.collector;
    if (!collector || !collector.waiter) return;
    var waiter = collector.waiter;
    collector.waiter = null;
    if (waiter.timer !== null) unschedule(waiter.timer);
    waiter.resolve(value);
  }
  function dispose(ref) {
    var entry = items[ref];
    if (!entry) return true;
    delete items[ref];
    unschedule(entry.timer);
    settleWait(entry, "missing_promise");
    entry.collector = null;
    entry.result = null;
    if (entry.cancel) {
      var cancel = entry.cancel; entry.cancel = null;
      try { cancel(); } catch (_) {} // Disposal must not mask an earlier exception.
    }
    return true;
  }
  function get(ref) {
    var entry = items[String(ref)];
    if (entry && now() >= entry.deadline) { dispose(String(ref)); return null; }
    return entry;
  }
  function create(start) {
    var ref = String(options.mint());
    var entry = {deadline:now()+lifetime, timer:null, ready:false, result:null, collector:null, cancel:null};
    items[ref] = entry;
    function expire() {
      if (items[ref] !== entry) return;
      if (now() >= entry.deadline) dispose(ref);
      else entry.timer = schedule(expire, entry.deadline-now());
    }
    try {
      entry.timer = schedule(expire, lifetime);
      var request = start(ref);
      entry.cancel = request.cancel || null;
      // Observe rejection immediately, even when nobody ever calls yield/3.
      Promise.resolve(request.promise).then(function(value) { complete(value); }, function(error) {
        complete(options.errorText(error));
      });
    } catch (error) { dispose(ref); throw error; }
    function complete(value) {
      if (get(ref) !== entry) return; // Disposal wins over late completion.
      entry.ready = true;
      entry.result = value;
      // A settled request no longer needs cancellation. Its own finally
      // releases transport timers and request bookkeeping.
      entry.cancel = null;
      settleWait(entry, value);
    }
    return ref;
  }
  function claim(ref) {
    var entry = get(ref);
    if (!entry) return "missing_promise";
    if (entry.collector) return "busy_promise";
    var token = "promise_collector("+(nextCollector++)+")";
    entry.collector = {token:token, waiter:null};
    return token;
  }
  function wait(ref, token, timeout) {
    var entry = get(ref);
    if (!entry || !entry.collector || entry.collector.token !== token) return Promise.resolve("missing_promise");
    if (entry.ready) return Promise.resolve(entry.result);
    return new Promise(function(resolve) {
      var collector = entry.collector;
      var waiter = {resolve:resolve, timer:null};
      collector.waiter = waiter;
      if (typeof timeout === "number" && isFinite(timeout) && timeout >= 0) {
        waiter.timer = schedule(function() {
          if (entry.collector === collector && collector.waiter === waiter) settleWait(entry, null);
        }, timeout*1000);
      }
    });
  }
  function release(ref, token) {
    var entry = get(ref);
    if (entry && entry.collector && entry.collector.token === token) {
      settleWait(entry, "missing_promise");
      entry.collector = null;
    }
    return true;
  }
  function commit(ref, token) {
    var entry = get(ref);
    if (!entry || !entry.collector || entry.collector.token !== token || !entry.ready) return "missing_promise";
    dispose(String(ref));
    return "committed";
  }
  function interruptCollectors() {
    var count = 0;
    Object.keys(items).forEach(function(ref) {
      var entry = items[ref];
      if (entry.collector) { count++; release(ref, entry.collector.token); }
    });
    return count;
  }
  return {items:items, create:create, claim:claim, wait:wait, commit:commit, release:release,
    dispose:dispose, interruptCollectors:interruptCollectors};
}

(function() {
  "use strict";
  if (typeof document !== "undefined") return;

  var selfPidText = "";
  var mailbox = [];
  var waiters = [];
  var outputBuffer = "";
  var started = false;
  var nextRequestId = 1;
  var pendingRequests = {};
  var pendingRpcPromises = createSwiWasmPromiseStore({
    mint: makePromiseRef,
    errorText: function(error) {
      var detail = error && error.message ? error.message : String(error);
      return "error(rpc_error("+JSON.stringify(detail)+"))";
    }
  });
  var Prolog = null;
  var Module = null;
  var exitReason = null;
  var abortRequested = false;
  var pendingAbortCount = 0;
  var recoveringPtcp = false;
  var activeAwait = null;
  var ptcpTimeLimitRequested = false;
  var ptcpTimeLimitTimer = null;
  var ptcpTimeLimitTargetText = "";
  var ptcpTimeLimitPidText = "";
  var ptcpTimeLimitRequestRefText = "none";
  // PTCP state reported by the toplevel itself (Semantic Contracts D3, D4):
  // its pid and session mode, and the client of the active query ("" when
  // the toplevel is idle in s1).
  var ptcpPidText = "";
  var ptcpSessionText = "true";
  var ptcpClientText = "";
  var ptcpLastClientText = "";
  var ptcpTargetText = "";
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
      if (character === "\\") {
        // Decode the escape sequences of a quoted Prolog atom.  The
        // controller writes newlines, tabs and carriage returns as \n, \t
        // and \r (prologQuotedText), so these must be read back, or the
        // whole program reaches the consult as one line of text.
        var escaped = text.charAt(index + 1);
        var simple = { n: "\n", t: "\t", r: "\r", a: "\x07", b: "\b", f: "\f",
                       v: "\v", e: "\x1b", s: " ", "0": "\0",
                       "\\": "\\", "'": "'", "\"": "\"", "`": "`" };
        if (escaped === "\n") {
          index += 2;
          continue;
        }
        if (escaped === "x") {
          var hex = /^x([0-9a-fA-F]+)\\/.exec(text.slice(index + 1));
          if (hex) {
            output += String.fromCodePoint(parseInt(hex[1], 16));
            index += 1 + hex[0].length;
            continue;
          }
        }
        var octal = /^([0-7]+)\\/.exec(text.slice(index + 1));
        if (octal) {
          output += String.fromCodePoint(parseInt(octal[1], 8));
          index += 1 + octal[0].length;
          continue;
        }
        if (Object.prototype.hasOwnProperty.call(simple, escaped)) {
          output += simple[escaped];
          index += 2;
          continue;
        }
        throw new Error("undefined escape sequence \\" + escaped + " in src_text/1");
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
    if (new RegExp("(?:^|[,\\[])\\s*" + name + "\\s*\\(").test(String(optionsText || "[]")) &&
        (!match || (name === "limit" && Number(match[1]) <= 0))) {
      throw new Error(name + " must be " + (name === "limit" ? "a positive" : "a non-negative") + " integer");
    }
    return match ? Number(match[1]) : defaultValue;
  }

  function toplevelCallOptions(optionsText) {
    var text = String(optionsText || "[]");
    return {
      limit: callIntegerOption(text, "limit", "none"),
      offset: callIntegerOption(text, "offset", 0),
      once: /(?:^|[,\[])\s*once\s*\(\s*true\s*\)/.test(text)
    };
  }

  function toplevelCallHasSourceOption(optionsText) {
    return /(?:^|[,\[])\s*src_text\s*\(/.test(String(optionsText || "[]"));
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
          if (fields && fields.promise_ref) post("promise_dispose", {ref:String(fields.promise_ref)});
        }
      }, REQUEST_TIMEOUT_MS);
      pendingRequests[id] = {
        promiseRef: fields && fields.promise_ref ? String(fields.promise_ref) : null,
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
    // wire_text/2 uses canonical prefix notation for the @/2 operator.
    var canonical = /^@\(([^,]+),\s*(.+)\)$/.exec(text);
    if (canonical) text = canonical[1].trim() + "@" + canonical[2].trim();
    if (/^terminal\s*@\s*'?localhost'?$/.test(text)) return "terminal";
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

  function actorWorkerScopeOpen() {
    var token = "scope-" + nextRequestId++;
    post("worker_scope_open", { scope: token });
    return token;
  }
  function actorWorkerScopeReserve(token) {
    return actorRequest("worker_scope_reserve", { scope: String(token) });
  }
  function actorWorkerScopeSpawn(token, pid, goal) {
    return actorRequest("worker_scope_spawn", { scope: String(token), worker: String(pid), goal: String(goal) });
  }
  function actorWorkerScopeRelease(token, pid) {
    post("worker_scope_release", { scope: String(token), worker: localizePid(pid) });
    return true;
  }
  function actorWorkerScopeClose(token) {
    // The request still settles when an interrupted caller no longer awaits it.
    return actorRequest("worker_scope_close", { scope: String(token) }).catch(function() { return false; });
  }

  function actorReservePid() {
    return actorRequest("reserve_pid", {});
  }

  function actorSpawnWithPid(targetPidText, goalText, sourceText, nameText, linkText) {
    return actorRequest("spawn", {
      pid: String(targetPidText || ""),
      goal: String(goalText || "true"),
      source: String(sourceText || ""),
      name: String(nameText || ""),
      link: String(linkText === undefined ? "true" : linkText) !== "false"
    });
  }

  function actorRemoteSpawn(nodeText, goalText, sourceText) {
    return actorRequest("remote_spawn", {
      node: String(nodeText || ""),
      goal: String(goalText || "true"),
      source: String(sourceText || "")
    });
  }

  function actorRemoteToplevelSpawn(nodeText, sourceText, sessionText,
                                    timeLimitText, idleLimitText) {
    return actorRequest("remote_toplevel_spawn", {
      node: String(nodeText || ""),
      source: String(sourceText || ""),
      session: String(sessionText || "false"),
      timeLimit: String(timeLimitText || "infinite"),
      idleLimit: String(idleLimitText || "infinite")
    });
  }

  function actorEnsureFinalFullStop(text) {
    var source = String(text);
    return /\.\s*$/.test(source) ? source : source + ".";
  }

  function actorRpc(nodeText, goalText, templateText, offset, limit, loadText,
                    remoteTimeout, once, httpTimeout, promiseRef) {
    return actorRequest("rpc", {
      promise_ref: promiseRef || null,
      node: String(nodeText || ""),
      goal: String(goalText || "true"),
      template: String(templateText || "true"),
      offset: Number(offset || 0),
      limit: String(limit) === "none" ? undefined : Number(limit),
      loadText: String(loadText || ""),
      remoteTimeout: Number(remoteTimeout),
      once: once === true || String(once) === "true",
      httpTimeout: Number(httpTimeout)
    });
  }

  function actorPromiseStart(nodeText, goalText, templateText, offset, limit,
                             loadText, remoteTimeout, once, httpTimeout) {
    return pendingRpcPromises.create(function(ref) {
      return {promise: actorRpc(nodeText, goalText, templateText, offset, limit,
        loadText, remoteTimeout, once, httpTimeout, ref),
        cancel: function() { cancelPromiseRequest(ref); }};
    });
  }

  function cancelPromiseRequest(ref) {
    Object.keys(pendingRequests).forEach(function(id) {
      var request = pendingRequests[id];
      if (request.promiseRef !== String(ref)) return;
      delete pendingRequests[id];
      request.reject(new Error("promise disposed"));
    });
    post("promise_dispose", {ref:String(ref)});
    return true;
  }

  var issuedPromiseRefs = Object.create(null);
  function makePromiseRef() {
    if (!self.crypto || typeof self.crypto.getRandomValues !== "function") {
      throw new Error("Secure randomness is required for promise references");
    }
    var ref;
    do {
      var value;
      do {
        var values = new Uint8Array(5);
        self.crypto.getRandomValues(values);
        value = 0;
        for (var i = 0; i < values.length; i++) {
          value = value * 256 + values[i];
        }
      } while (value >= 1098000000000);
      ref = String(1000000000 + (value % 9000000000));
    } while (issuedPromiseRefs[ref]);
    issuedPromiseRefs[ref] = true;
    return ref;
  }

  function actorToplevelCorrelation(nodeText) {
    return actorRequest("toplevel_correlation", {node: String(nodeText)});
  }
  function actorSynchronousSend(pidText, messageText) {
    return actorRequest("synchronous_send", {to: localizePid(pidText), message: String(messageText)});
  }

  function actorLoadUri(uriText) {
    return actorRequest("src_uri", { uri: String(uriText || "") });
  }

  function actorPromiseWait(ref, token, timeout) {
    return pendingRpcPromises.wait(String(ref), String(token), Number(timeout));
  }

  function actorStatechartSpawn(sourceKind, sourceText, supportSourceText,
                                nameText, linkText, ioTargetText, traceText) {
    return actorRequest("statechart_spawn", {
      sourceKind: String(sourceKind || ""),
      source: String(sourceText || ""),
      supportSource: String(supportSourceText || ""),
      name: String(nameText || ""),
      link: String(linkText === undefined ? "true" : linkText) !== "false",
      // Match native output/1: absent an explicit target, a nested actor sends
      // output to the actor that spawned it.
      ioTarget: String(ioTargetText || qualifyLocalPid(selfPidText)),
      trace: String(traceText === undefined ? "true" : traceText) !== "false"
    }).then(function(pid) {
      return "statechart_spawn_ok(" + JSON.stringify(String(pid)) + ")";
    }, function(error) {
      var message = error && error.message ? error.message : String(error || "statechart startup failed");
      return "statechart_spawn_error(" + JSON.stringify(message) + ")";
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

  function actorServerMonitorCleanup(refText) {
    post("server_monitor_cleanup", { ref: String(refText) });
    return true;
  }

  function actorDemonitor(refText) {
    return actorRequest("demonitor", { ref: String(refText) });
  }

  function actorExit(targetText, reasonText) {
    var target = localizePid(targetText || selfPidText);
    var reason = String(reasonText || "true");
    if (target === selfPidText || target === "self") {
      if (exitReason === null) {
        exitReason = reason;
      }
      post("exit", { pid: selfPidText, reason: exitReason });
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

  // Interrupt an await at the privileged bridge boundary, never by injecting
  // an application mailbox message or by returning a fake reply to the goal.
  function actorAwait(promise) {
    if (!isPtcpGoal()) return promise;
    return new Promise(function(resolve, reject) {
      var waiting = { interrupt: function() { resolve(null); } };
      activeAwait = waiting;
      function finish(callback, value) {
        if (activeAwait === waiting) activeAwait = null;
        callback(value);
      }
      Promise.resolve(promise).then(function(value) {
        finish(resolve, value);
      }, function(error) { finish(reject, error); });
      if (abortRequested || ptcpTimeLimitRequested) waiting.interrupt();
    });
  }

  function actorControlPending() {
    return abortRequested || ptcpTimeLimitRequested;
  }

  function interruptGoal() {
    if (activeAwait) {
      var waiting = activeAwait;
      activeAwait = null;
      // Remove the old receive waiter before the next query can receive.
      waiters.splice(0).forEach(function(w) {
        if (w.timer !== null) clearTimeout(w.timer);
      });
      Object.keys(pendingRequests).forEach(function(id) {
        var request = pendingRequests[id];
        if (request.promiseRef) return; // Interrupt the collector, not its request.
        delete pendingRequests[id];
        request.reject(new Error("query interrupted"));
      });
      waiting.interrupt();
      return true;
    }
    if (Prolog && typeof Prolog.abort === "function") {
      Prolog.abort();
      return true;
    }
    return false;
  }

  function abortCurrentGoal() {
    if (isPtcpGoal()) {
      // An abort never resumes a terminating toplevel.  Every other abort is
      // acknowledged, including one that reaches an idle toplevel (s1):
      // there the toplevel stays idle, or a one-shot toplevel ends.
      if (exitReason !== null) {
        return true;
      }
      pendingAbortCount++;
      abortRequested = true;
      return recoveringPtcp ? true : interruptGoal();
    }
    abortRequested = true;
    if (Prolog && typeof Prolog.abort === "function") {
      Prolog.abort();
      return true;
    }
    return false;
  }

  function actorPtcpStart(pidText, sessionText, targetText) {
    ptcpPidText = String(pidText || "");
    ptcpSessionText = String(sessionText || "true");
    ptcpTargetText = String(targetText || "");
    ptcpClientText = "";
    return true;
  }

  function actorPtcpClient(clientText) {
    ptcpClientText = String(clientText || "");
    if (ptcpClientText) {
      ptcpLastClientText = ptcpClientText;
    }
    return true;
  }

  // The first exit reason commits termination (Semantic Contracts D3).
  function actorRecordExit(reasonText) {
    if (exitReason === null) {
      exitReason = String(reasonText || "true");
    }
    return true;
  }

  // The acknowledgement of an abort goes to the client of the aborted query,
  // after the answers that query had already sent (Semantic Contracts D4).
  function sendAbortAcknowledgement(clientText) {
    if (!clientText) {
      return Promise.resolve(true);
    }
    if (workerRole === "shell_toplevel" && localizePid(clientText) === "terminal") {
      post("abort", {});
      return Promise.resolve(true);
    }
    return Promise.resolve(actorSend(clientText, "abort(" + ptcpPidText + ")")).catch(function(error) {
      post("error", { error: "PTCP abort acknowledgement failed: " + String(error) });
      return false;
    });
  }

  function actorArmTimeLimit(seconds, targetText, pidText, refText) {
    var delay = Number(seconds);
    actorDisarmTimeLimit();
    if (!isFinite(delay) || delay <= 0) {
      return false;
    }
    ptcpTimeLimitTargetText = String(targetText || "");
    ptcpTimeLimitPidText = String(pidText || selfPidText);
    ptcpTimeLimitRequestRefText = String(refText || "none");
    ptcpTimeLimitTimer = setTimeout(function() {
      ptcpTimeLimitTimer = null;
      if (exitReason !== null) {
        return;
      }
      ptcpTimeLimitRequested = true;
      interruptGoal();
    }, delay * 1000);
    return true;
  }

  function actorDisarmTimeLimit() {
    if (ptcpTimeLimitTimer !== null) {
      clearTimeout(ptcpTimeLimitTimer);
      ptcpTimeLimitTimer = null;
    }
    return true;
  }

  function isPtcpGoal() {
    return /(?:^|:)ptcp\(/.test(currentGoalText);
  }

  function sendPtcpTimeLimitError() {
    var targetText = ptcpTimeLimitTargetText;
    var pidText = ptcpTimeLimitPidText || selfPidText;
    var messageText = "error(" + pidText + ",error(resource_error(time),_))";
    if (ptcpTimeLimitRequestRefText !== "none") messageText = "'$toplevel_reply'(" + ptcpTimeLimitRequestRefText + "," + messageText + ")";
    ptcpTimeLimitRequestRefText = "none";
    ptcpTimeLimitTargetText = "";
    ptcpTimeLimitPidText = "";
    if (workerRole === "shell_toplevel" && localizePid(targetText) === "terminal") {
      post("error", {
        data: "Resource error: time",
        details: "error(resource_error(time),_)"
      });
      return Promise.resolve(true);
    }
    return Promise.resolve(actorSend(targetText, messageText)).catch(function(error) {
      post("error", { error: "PTCP time-limit delivery failed: " + String(error) });
      return false;
    });
  }

  function restartAbortedPtcp(error) {
    var timedOut = ptcpTimeLimitRequested;
    var clientText = ptcpClientText || ptcpLastClientText || ptcpTargetText;
    recoveringPtcp = true;
    actorDisarmTimeLimit();
    ptcpTimeLimitRequested = false;
    ptcpClientText = "";
    function acknowledgePending() {
      if (pendingAbortCount === 0) return Promise.resolve(true);
      pendingAbortCount--;
      return sendAbortAcknowledgement(clientText).then(acknowledgePending);
    }
    return (timedOut ? sendPtcpTimeLimitError() : Promise.resolve(true))
      .then(acknowledgePending).then(function() {
        abortRequested = false;
        recoveringPtcp = false;
        post("aborted", error === undefined ? {} : { error: String(error) });
        if (ptcpSessionText === "false") {
          post("done", { reason: "true" });
          return undefined;
        }
        return runGoal(currentGoalText);
      });
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

  function actorToplevelEvent(value, text, details) {
    var eventValue = value;
    var compound;
    var args;
    var data;
    var errorPayload;
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
      errorPayload = { data: String(text || formatValue(args[1])) };
      if (details && String(details) !== errorPayload.data) {
        errorPayload.details = String(details);
      }
      post("error", errorPayload);
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
    if (exitReason === null) {
      exitReason = String(reasonText || "true");
    }
    return true;
  }

  function actorInput(promptText) {
    return actorRequest("input", { prompt: String(promptText || "") });
  }

  self.actorAwait = actorAwait;
  self.actorControlPending = actorControlPending;
  self.actorMakeRef = actorMakeRef;
  self.actorReceive = actorReceive;
  self.actorSend = actorSend;
  self.actorSendDelayed = actorSendDelayed;
  self.actorCancel = actorCancel;
  self.actorToplevelCorrelation = actorToplevelCorrelation;
  self.actorSynchronousSend = actorSynchronousSend;
  self.actorSpawn = actorSpawn;
  var nextName = 0;
  self.swiWasmNameToken = function() { return "name-" + (++nextName); };
  self.swiWasmNameReserve = function(token, name) { return actorRequest("name_reserve", {token:String(token), name:String(name)}); };
  self.swiWasmNamePublish = function(token, name, pid, live) { return actorRequest("name_publish", {token:String(token), name:String(name), pid:String(pid), chartLive:live}); };
  self.swiWasmNameCommit = function(token, name) { post("name_commit", {token:String(token), name:String(name)}); return true; };
  self.swiWasmNameRelease = function(token, name) { post("name_release", {token:String(token), name:String(name)}); return true; };
  self.swiWasmStartupErrorText = function(error) { return String(error && error.message || error); };
  var nextStartup = 0;
  self.swiWasmStartupOpen = function() {
    var token = "startup-" + (++nextStartup);
    post("startup_open", {token:token});
    return token;
  };
  self.swiWasmStartupFinish = function(token, committed) {
    post("startup_finish", {token:String(token), committed:committed === true || String(committed) === "true"});
    return true;
  };
  self.actorReservePid = actorReservePid;
  self.actorWorkerScopeOpen = actorWorkerScopeOpen;
  self.actorWorkerScopeReserve = actorWorkerScopeReserve;
  self.actorWorkerScopeSpawn = actorWorkerScopeSpawn;
  self.actorWorkerScopeRelease = actorWorkerScopeRelease;
  self.actorWorkerScopeClose = actorWorkerScopeClose;
  self.actorSpawnWithPid = actorSpawnWithPid;
  self.actorRemoteSpawn = actorRemoteSpawn;
  self.actorRemoteToplevelSpawn = actorRemoteToplevelSpawn;
  self.actorEnsureFinalFullStop = actorEnsureFinalFullStop;
  self.actorRpc = actorRpc;
  self.actorPromiseStart = actorPromiseStart;
  self.actorLoadUri = actorLoadUri;
  self.actorPromiseWait = actorPromiseWait;
  self.actorPromiseClaim = function(ref) { return pendingRpcPromises.claim(String(ref)); };
  self.actorPromiseCommit = function(ref, token) { return pendingRpcPromises.commit(String(ref),String(token)); };
  self.actorPromiseRelease = function(ref, token) { return pendingRpcPromises.release(String(ref),String(token)); };
  self.actorPromiseCleanup = function(ref) { return pendingRpcPromises.dispose(String(ref)); };
  self.actorStatechartSpawn = actorStatechartSpawn;
  self.actorActors = actorActors;
  self.actorRegister = actorRegister;
  self.actorUnregister = actorUnregister;
  self.actorWhereis = actorWhereis;
  self.actorMonitor = actorMonitor;
  self.actorDemonitor = actorDemonitor;
  self.actorServerMonitorCleanup = actorServerMonitorCleanup;
  self.actorExit = actorExit;
  self.actorAbort = actorAbort;
  self.actorArmTimeLimit = actorArmTimeLimit;
  self.actorDisarmTimeLimit = actorDisarmTimeLimit;
  self.actorTerminalOutput = actorTerminalOutput;
  self.actorToplevelEvent = actorToplevelEvent;
  self.actorSetDoneReason = actorSetDoneReason;
  self.actorPtcpStart = actorPtcpStart;
  self.actorPtcpClient = actorPtcpClient;
  self.actorRecordExit = actorRecordExit;
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
    Prolog.query("swi_wasm_actor_bridge:load_private_source(File)", {File:path}).once();
  }

  function installSharedDatabase() {
    if (!Module || !Module.FS) {
      return Promise.reject(new Error("SWI-WASM shared database requires the virtual filesystem"));
    }
    var url = runtimeAsset("shared_db.pl");
    return (url === null ? Promise.resolve({ok:true,text:function() { return Promise.resolve(""); }}) : fetch(url, { cache: "no-store" })).then(function(response) {
      if (!response.ok) {
        throw new Error("HTTP " + response.status + " for /wasm/shared_db.pl");
      }
      return response.text();
    }).then(function(sourceText) {
      // Shared node code gets the same actor API and operators as ordinary
      // Web Prolog actor modules.  Keep this loader concern out of the shared
      // source so users can write receive/1 and Pid ! Message naturally.
      Module.FS.writeFile("/worker_shared_db.pl",
        ":- set_prolog_flag(double_quotes,chars).\n:- use_module('/worker_actor_bridge.pl').\n" + sourceText);
      Prolog.query("use_module(library(modules))").once();
      Prolog.query("set_module(wasm_shared_db:base(system))").once();
      Prolog.query("load_files(wasm_shared_db:'/worker_shared_db.pl',[silent(true)])").once();
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
      "    toplevel_call/2, toplevel_call/3, toplevel_call_synch/3, toplevel_call_synch/4, toplevel_next_synch/2, toplevel_next_synch/3,",
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
      "    rpc/2, rpc/3, promise/3, promise/4, promise_cleanup/1, yield/2, yield/3, runtime_property/1",
      "]).",
      ":- use_module(library(wasm)).",
      ":- use_module(library(apply)).",
      ":- use_module(library(error)).",
      ":- use_module(library(lists)).",
      ":- use_module(library(option)).",
      ":- op(800, xfx, !).",
      ":- op(200, xfx, @).",
      ":- op(1000, xfy, if).",
      ":- meta_predicate spawn(:), spawn(:, -), spawn(:, -, +), toplevel_call(+, :), toplevel_call(+, :, +), toplevel_call_synch(+, :, -), toplevel_call_synch(+, :, -, :), toplevel_next_synch(+, -), toplevel_next_synch(+, -, :), receive(:), receive(:, +), with_io_target(+, 0), parallel(:), first_solution(?, :), first_solution(?, :, +), yield(+, -, :), with_worker_scope(-, 0), spawn_scoped_worker(+, 0, -).",
      ":- dynamic deferred/1, io_target/1, retiring_server_monitor/1, retiring_supervisor_shutdown/1, retiring_scope_worker/2, closing_worker_scope/1.",
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
      "% Validate original terms before source loading or actor setup; do not copy options.",
      "validate_browser_spawn_options(Options) :-",
      "    catch((must_be(list, Options), maplist(validate_browser_spawn_option, Options)),",
      "          error(Formal, _), throw(error(Formal, context(spawn/3, 'invalid spawn option')))).",
      "",
      "validate_browser_spawn_option(Option) :-",
      "    must_be(nonvar, Option),",
      "    ( compound(Option), compound_name_arity(Option, Name, 1),",
      "      browser_spawn_option_type(Name, Type)",
      "    -> arg(1, Option, Value), validate_rpc_client_value(Type, Value)",
      "    ; domain_error(spawn_option, Option) ).",
      "",
      "browser_spawn_option_type(node, atom_or_string).",
      "browser_spawn_option_type(link, spawn_boolean).",
      "browser_spawn_option_type(monitor, spawn_boolean).",
      "browser_spawn_option_type(name, atom).",
      "browser_spawn_option_type(target, nonvar).",
      "browser_spawn_option_type(io_target, nonvar).",
      "browser_spawn_option_type(src_text, atom_or_string).",
      "browser_spawn_option_type(src_uri, atom_or_string).",
      "browser_spawn_option_type(src_list, list).",
      "browser_spawn_option_type(src_predicates, predicate_indicators).",
      "",
      "% Wrapper schemas extend recognition only at their own public entry points.",
      "validate_browser_wrapper_options(Kind, PI, Options) :-",
      "    catch((must_be(list, Options), maplist(validate_browser_wrapper_option(Kind), Options)),",
      "          error(Formal, _), throw(error(Formal, context(PI, 'invalid wrapper option')))).",
      "validate_browser_wrapper_option(Kind, Option) :-",
      "    must_be(nonvar, Option),",
      "    ( compound(Option), compound_name_arity(Option, Name, 1),",
      "      ( browser_wrapper_option_type(Kind, Name, Type) -> true",
      "      ; browser_spawn_option_type(Name, Type) )",
      "    -> arg(1, Option, Value), validate_browser_wrapper_value(Type, Value)",
      "    ; domain_error(spawn_option, Option) ).",
      "",
      "browser_wrapper_option_type(toplevel, session, spawn_boolean).",
      "browser_wrapper_option_type(toplevel, time_limit, ptcp_limit(time_limit)).",
      "browser_wrapper_option_type(toplevel, idle_limit, ptcp_limit(idle_limit)).",
      "browser_wrapper_option_type(server, initial_state, template).",
      "browser_wrapper_option_type(supervisor, strategy, supervisor_strategy).",
      "browser_wrapper_option_type(supervisor, intensity, nonneg).",
      "browser_wrapper_option_type(supervisor, period, supervisor_period).",
      "browser_wrapper_option_type(statechart, trace, spawn_boolean).",
      "browser_wrapper_option_type(statechart, src_uri, atom_or_string).",
      "",
      "validate_browser_wrapper_value(ptcp_limit(Kind), Value) :- !,",
      "    must_be(nonvar, Value), normalize_ptcp_limit(Kind, Value, _).",
      "validate_browser_wrapper_value(supervisor_strategy, Value) :- !,",
      "    must_be(nonvar, Value),",
      "    ( memberchk(Value, [one_for_one,one_for_all,rest_for_one]) -> true",
      "    ; domain_error(supervisor_strategy, Value) ).",
      "validate_browser_wrapper_value(supervisor_period, Value) :- !,",
      "    must_be(number, Value),",
      "    ( Value > 0 -> true ; domain_error(supervisor_period, Value) ).",
      "validate_browser_wrapper_value(Type, Value) :- validate_rpc_client_value(Type, Value).",
      "",
      "spawn(Goal, Pid, Options) :-",
      "    validate_browser_spawn_options(Options),",
      "    browser_named_creation(Options, Pid, spawn/3, Inner, browser_spawn_options(Goal, Pid, Inner)).",
      "browser_spawn_options(Goal, Pid, Options) :-",
      "    option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
      "    (   Node == localhost",
      "    ->  collect_spawn_source(Options, ExtraSource),",
      "        PidPromise := actorReservePid(),",
      "        actor_await(PidPromise, PidText),",
      "        term_string(LocalPid, PidText),",
      "        Pid = LocalPid@localhost,",
      "        wire_text(Goal, GoalText),",
      "        ( option(name(Name), Options) -> term_string(Name, NameText) ; NameText = \"\" ),",
      "        option(link(Link), Options, true),",
      "        term_string(Link, LinkText),",
      "        Promise := actorSpawnWithPid(#PidText, #GoalText, #ExtraSource, #NameText, #LinkText),",
      "        actor_await(Promise, SpawnedText),",
      "        term_string(SpawnedPid, SpawnedText), SpawnedPid == LocalPid",
      "    ;   collect_spawn_source(Options, ExtraSource),",
      "        term_string(Node, NodeText),",
      "        wire_text(Goal, GoalText),",
      "        Promise := actorRemoteSpawn(#NodeText, #GoalText, #ExtraSource),",
      "        actor_await(Promise, PidText),",
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
      "    maplist(goal_template, Goals, Templates),",
      "    ( Goals == [] -> true ; with_worker_scope(Scope,",
      "        (maplist(par_solve(Scope), Goals, Templates, Pids),",
      "         maplist(par_yield(Scope, Pids), Pids, Templates)))).",
      "",
      "qualify_actor_goal(Module, Goal, Module:Goal).",
      "",
      "goal_template(Goal, Template) :- term_variables(Goal, Template).",
      "",
      "par_solve(Scope, Goal, Template, Pid) :-",
      "    self(Self),",
      "    spawn_scoped_worker(Scope, (call(Goal), send(Self, Pid-Template)), Pid).",
      "",
      "par_yield(Pids, Pid, Template) :- par_yield(none, Pids, Pid, Template).",
      "par_yield(Scope, Pids, Pid, Template) :-",
      "    receive({",
      "        Pid-Answer ->",
      "            ( Template = Answer",
      "            -> receive({down(Pid, Ref, _) if scoped_worker_ref(Scope, Pid, Ref) -> release_scoped_worker(Scope, Pid)})",
      "            ; tidy_worker_scope(Scope, Pids), !, fail ) ;",
      "        down(FailedPid, Ref, false) if (known_worker(FailedPid, Pids), scoped_worker_ref(Scope, FailedPid, Ref)) ->",
      "            tidy_worker_scope(Scope, Pids), !, fail ;",
      "        down(FailedPid, Ref, Reason) if (known_worker(FailedPid, Pids), scoped_worker_ref(Scope, FailedPid, Ref), (Reason \\== true ; FailedPid == Pid)) ->",
      "            tidy_worker_scope(Scope, Pids), worker_error(FailedPid, Reason, Error), throw(Error)",
      "    }).",
      "",
      "%  A guard tests a worker pid; it never binds one (Semantic Contracts D1).",
      "known_worker(Pid, Pids) :- ground(Pid), memberchk(Pid, Pids).",
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
      "    ( Goals == [] -> fail ; with_worker_scope(Scope,",
      "        (maplist(first_solve(Scope, Solution), Goals, Pids),",
      "         wait_first(Scope, Pids, Solution, OnFail, OnError)))).",
      "",
      "valid_first_solution_option(on_fail(_)) :- !.",
      "valid_first_solution_option(on_error(_)) :- !.",
      "valid_first_solution_option(Option) :-",
      "    throw(error(domain_error(first_solution_option, Option), first_solution/3)).",
      "",
      "first_solve(Scope, Solution, Goal, Pid) :-",
      "    self(Self),",
      "    spawn_scoped_worker(Scope, (call(Goal), send(Self, Pid-Solution)), Pid).",
      "",
      "wait_first(Pids, Solution, OnFail, OnError) :- wait_first(none, Pids, Solution, OnFail, OnError).",
      "wait_first(_, [], _, _, _) :- !, fail.",
      "wait_first(Scope, Pids, Solution, OnFail, OnError) :-",
      "    receive({",
      "        Winner-Answer if known_worker(Winner, Pids) ->",
      "            tidy_worker_scope(Scope, Pids), Solution = Answer ;",
      "        down(FailedPid, Ref, false) if (known_worker(FailedPid, Pids), scoped_worker_ref(Scope, FailedPid, Ref)) ->",
      "            ( OnFail == continue -> release_scoped_worker(Scope, FailedPid), selectchk(FailedPid, Pids, Rest),",
      "              wait_first(Scope, Rest, Solution, OnFail, OnError)",
      "            ; tidy_worker_scope(Scope, Pids), !, fail ) ;",
      "        down(FailedPid, Ref, Reason) if (known_worker(FailedPid, Pids), scoped_worker_ref(Scope, FailedPid, Ref)) ->",
      "            ( OnError == continue -> release_scoped_worker(Scope, FailedPid), selectchk(FailedPid, Pids, Rest),",
      "              wait_first(Scope, Rest, Solution, OnFail, OnError)",
      "            ; tidy_worker_scope(Scope, Pids), worker_error(FailedPid, Reason, Error), throw(Error) )",
      "    }).",
      "",
      "% An accepted result establishes success; an unexplained exit is an error.",
      "worker_error(Pid, Reason, Error) :-",
      "    ( nonvar(Reason), Reason = exception(E) -> Error = E ; Error = worker_exit(Pid, Reason) ).",
      "",
      "% Private scopes own only workers started by the two combinators.",
      "with_worker_scope(Scope, Goal) :-",
      "    Token := actorWorkerScopeOpen(),",
      "    Scope = workers(Token, [], open, _),",
      "    call_cleanup(call(Goal), close_worker_scope(Scope)).",
      "",
      "spawn_scoped_worker(Scope, Goal, Pid) :-",
      "    arg(1, Scope, Token),",
      "    Reservation := actorWorkerScopeReserve(#Token),",
      "    actor_await(Reservation, PidText),",
      "    term_string(LocalPid, PidText), Pid = LocalPid@localhost,",
      "    arg(2, Scope, Pids), nb_setarg(2, Scope, [Pid|Pids]),",
      "    wire_text(Goal, GoalText),",
      "    Startup := actorWorkerScopeSpawn(#Token, #PidText, #GoalText),",
      "    actor_await(Startup, _).",
      "",
      "scoped_worker_ref(none, _, _) :- !.",
      "scoped_worker_ref(_, Pid, Ref) :- Ref == Pid.",
      "",
      "release_scoped_worker(none, _) :- !.",
      "release_scoped_worker(Scope, Pid) :-",
      "    arg(2, Scope, Pids), selectchk(Pid, Pids, Rest), nb_setarg(2, Scope, Rest),",
      "    arg(1, Scope, Token), term_string(Pid, PidText),",
      "    _ := actorWorkerScopeRelease(#Token, #PidText).",
      "",
      "tidy_worker_scope(none, Pids) :- !, worker_tidy_all(Pids).",
      "tidy_worker_scope(Scope, _) :-",
      "    close_worker_scope(Scope), arg(4, Scope, Closed),",
      "    actor_await(Closed, _).",
      "",
      "close_worker_scope(Scope) :-",
      "    ( arg(3, Scope, open)",
      "    -> nb_setarg(3, Scope, closing),",
      "       arg(1, Scope, Token), arg(2, Scope, Pids), assertz(closing_worker_scope(Token)),",
      "       forall(member(Pid, Pids),",
      "              (assertz(retiring_scope_worker(Token, Pid)), flush_scoped_worker_messages(Pid))),",
      "       Closed := actorWorkerScopeClose(#Token), nb_linkarg(4, Scope, Closed)",
      "    ; true ).",
      "",
      "flush_scoped_worker_messages(Pid) :-",
      "    forall((clause(deferred(Msg), true, Clause), scoped_worker_message(Pid, Msg)), erase(Clause)).",
      "scoped_worker_message(Pid, Msg) :- nonvar(Msg), Msg = Worker-_, Worker == Pid.",
      "scoped_worker_message(Pid, Msg) :- nonvar(Msg), Msg = down(Worker, Ref, _), Worker == Pid, Ref == Pid.",
      "discard_worker_scope_message('$worker_scope_closed'(Token)) :-",
      "    closing_worker_scope(Closing), Token == Closing, !,",
      "    retractall(closing_worker_scope(Token)), retractall(retiring_scope_worker(Token, _)).",
      "discard_worker_scope_message(Msg) :-",
      "    retiring_scope_worker(_, Pid), scoped_worker_message(Pid, Msg).",
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
      "canonical_source_option(src_text(Text0), src_text(Text)) :- browser_source_text(Text0,Text).",
      "canonical_source_option(src_list(Terms), src_list(Terms)).",
      "canonical_source_option(src_uri(URI0), src_uri(URI)) :- browser_uri_atom(URI0, URI).",
      "canonical_source_option(src_predicates(PIs), src_predicates(PIs)).",
      "source_option_member(Canonical, Options) :-",
      "    member(Option, Options),",
      "    canonical_source_option(Option, Canonical).",
      "",
      "statechart_spawn(Pid, Options) :-",
      "    validate_browser_wrapper_options(statechart, statechart_spawn/2, Options),",
      "    browser_named_creation(Options, Pid, statechart_spawn/2, Inner, browser_statechart_spawn_options(Pid, Inner)).",
      "browser_statechart_spawn_options(Pid, Options) :-",
      "    ( source_option_member(src_text(Source), Options) -> SourceKind = text",
      "    ; source_option_member(src_uri(Source), Options) -> SourceKind = uri",
      "    ; throw(error(domain_error(statechart_source_option, src_text_or_src_uri), statechart_spawn/2))",
      "    ),",
      "    collect_statechart_support_source(Options, SupportSource),",
      "    ( option(name(Name), Options) -> term_string(Name, NameText) ; NameText = \"\" ),",
      "    option(link(Link), Options, true), term_string(Link, LinkText),",
      "    ( option(io_target(IoTarget), Options) -> term_string(IoTarget, IoTargetText) ; IoTargetText = \"\" ),",
      "    option(trace(Trace), Options, true), term_string(Trace, TraceText),",
      "    option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
      "    (   Node == localhost",
      "    ->  Promise := actorStatechartSpawn(#SourceKind, #Source, #SupportSource, #NameText, #LinkText, #IoTargetText, #TraceText),",
      "        actor_await(Promise, ResultText), statechart_spawn_worker_result(ResultText, Pid)",
      "    ;   statechart_remote_goal(SourceKind, Source, Trace, Options, Goal),",
      "        term_string(Goal, GoalText), term_string(Node, NodeText),",
      "        Promise := actorRemoteSpawn(#NodeText, #GoalText, #SupportSource),",
      "        actor_await(Promise, PidText), term_string(Pid, PidText),",
      "        maybe_register_toplevel_name(Options, Pid)",
      "    ),",
      "    install_spawn_monitor(Pid, Options).",
      "",
      "statechart_spawn_worker_result(ResultText, Pid) :-",
      "    term_string(Result, ResultText),",
      "    (   Result = statechart_spawn_ok(PidText)",
      "    ->  term_string(LocalPid, PidText), canonical_pid(LocalPid, Pid)",
      "    ;   Result = statechart_spawn_error(Message)",
      "    ->  throw(error(statechart_startup_error(Message), context(statechart_spawn/2, 'the statechart worker rejected its source')))",
      "    ;   throw(error(domain_error(statechart_spawn_result, Result), statechart_spawn/2))",
      "    ).",
      "",
      "statechart_remote_goal(text, Source, Trace, Options, Goal) :-",
      "    statechart_remote_goal_io(statechart_actor:interpret_text_trace(Trace, Source), Options, Goal).",
      "statechart_remote_goal(uri, Source, Trace, Options, Goal) :-",
      "    statechart_remote_goal_io(statechart_actor:interpret_trace(Trace, Source), Options, Goal).",
      "statechart_remote_goal_io(Goal0, Options, Goal) :-",
      "    ( option(io_target(Target), Options) -> Goal = actors:with_io_target(Target, Goal0) ; Goal = Goal0 ).",
      "",
      "collect_statechart_support_source(Options, Source) :-",
      "    findall(Text, (member(Option, Options), statechart_support_source_option(Option, Raw), browser_materialized_source(Options,Raw,Text)), Texts),",
      "    atomic_list_concat(Texts, '\\n', Source).",
      "statechart_support_source_option(Option, Text) :-",
      "    canonical_source_option(Option, Canonical),",
      "    statechart_support_source_text(Canonical, Text).",
      "statechart_support_source_text(src_list(Terms), Text) :-",
      "    findall(ClauseText,",
      "            ( member(Term, Terms), clause_source_text(Term, ClauseText) ),",
      "            ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "statechart_support_source_text(src_predicates(Indicators), Text) :-",
      "    findall(ClauseText,",
      "            ( member(Name/Arity, Indicators), functor(Head, Name, Arity),",
      "              statechart_source_clause(Head, Body),",
      "              (Body == true -> Clause = Head ; Clause = (Head :- Body)),",
      "              clause_source_text(Clause, ClauseText) ),",
      "            ClauseTexts),",
      "    atomic_list_concat(ClauseTexts, '\\n', Text).",
      "statechart_source_clause(Head, Body) :-",
      "    catch(predicate_property(statechart_wasm:Head, number_of_clauses(Count)), _, fail), Count > 0, !,",
      "    statechart_wasm:clause(Head, Body).",
      "statechart_source_clause(Head, Body) :- catch(user:clause(Head, Body), _, fail).",
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
      "    atomic_list_concat(ClauseTexts, '\\n', Raw), browser_materialized_source(Options,Raw,Text).",
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
      "    atomic_list_concat(ClauseTexts, '\\n', Raw), browser_materialized_source(Options,Raw,Text).",
      "",
      "% Preserve Worker source groups: text, lists, predicates, then URI texts.",
      "spawn_source_option(Options, Text) :-",
      "    source_option_member(src_uri(URI0), Options), browser_uri_atom(URI0, URI),",
      "    term_string(URI, URIText),",
      "    Promise := actorLoadUri(#URIText),",
      "    actor_await(Promise, Text).",
      "",
      "clause_source_text(Clause, Text) :-",
      "    copy_term(Clause, Copy),",
      "    numbervars(Copy, 0, _, [singletons(true)]),",
      "    with_output_to(string(Body), write_term(Copy, [quoted(true), numbervars(true)])),",
      "    string_concat(Body, '.', Text).",
      "",
      "% Inspect the original options: template and callback variables must stay shared.",
      "validate_rpc_client_options(Kind, Options) :-",
      "    rpc_client_option_context(Kind, PI),",
      "    catch((must_be(list, Options), maplist(validate_rpc_client_option(Kind), Options)),",
      "          error(Formal, _), throw(error(Formal, context(PI, 'invalid client option')))).",
      "",
      "rpc_client_option_context(rpc, rpc/3).",
      "rpc_client_option_context(promise, promise/4).",
      "rpc_client_option_context(yield, yield/3).",
      "",
      "validate_rpc_client_option(Kind, Option) :-",
      "    must_be(nonvar, Option),",
      "    ( compound(Option), compound_name_arity(Option, Name, 1),",
      "      rpc_client_option_type(Kind, Name, Type)",
      "    -> arg(1, Option, Value), validate_rpc_client_value(Type, Value)",
      "    ; atom_concat(Kind, '_option', Domain), domain_error(Domain, Option) ).",
      "",
      "rpc_client_option_type(rpc, Name, Type) :- rpc_query_option_type(Name, Type).",
      "rpc_client_option_type(promise, template, template).",
      "rpc_client_option_type(promise, offset, nonneg).",
      "rpc_client_option_type(promise, Name, Type) :- rpc_query_option_type(Name, Type).",
      "rpc_client_option_type(yield, timeout, number).",
      "rpc_client_option_type(yield, on_timeout, callable).",
      "",
      "browser_uri_atom(Input, URI) :-",
      "    must_be(nonvar, Input),",
      "    ( atom(Input) -> URI = Input",
      "    ; string(Input) -> atom_string(URI, Input)",
      "    ; is_list(Input), maplist(browser_character,Input) -> atom_chars(URI,Input)",
      "    ; type_error(atom_or_string, Input) ).",
      "browser_rpc_uri(Input, URI) :-",
      "    nonvar(Input), Input = Host0:Port, !,",
      "    browser_uri_atom(Host0, Host), must_be(integer, Port),",
      "    format(atom(URI), 'http://~w:~w', [Host,Port]).",
      "browser_rpc_uri(Input, URI) :- browser_uri_atom(Input, URI).",
      "",
      "rpc_query_option_type(limit, positive_integer).",
      "rpc_query_option_type(once, boolean).",
      "rpc_query_option_type(timeout, query_timeout).",
      "rpc_query_option_type(http_timeout, query_timeout).",
      "rpc_query_option_type(src_text, atom_or_string).",
      "rpc_query_option_type(src_uri, atom_or_string).",
      "rpc_query_option_type(src_list, list).",
      "rpc_query_option_type(src_predicates, predicate_indicators).",
      "",
      "validate_rpc_client_value(spawn_boolean, Value) :- !, must_be(boolean, Value).",
      "validate_rpc_client_value(template, _) :- !.",
      "validate_rpc_client_value(query_timeout, Value) :- !,",
      "    must_be(nonvar, Value), normalize_optional_timeout(Value, _).",
      "validate_rpc_client_value(boolean, Value) :- !,",
      "    must_be(nonvar, Value), normalize_boolean(Value, _).",
      "validate_rpc_client_value(atom_or_string, Value) :- !,",
      "    must_be(nonvar, Value),",
      "    browser_native_text(Value,_).",
      "validate_rpc_client_value(predicate_indicators, Value) :- !,",
      "    must_be(list, Value), maplist(validate_rpc_client_pi, Value).",
      "validate_rpc_client_value(Type, Value) :- must_be(Type, Value).",
      "",
      "validate_rpc_client_pi(PI) :-",
      "    must_be(nonvar, PI),",
      "    ( compound(PI), compound_name_arity(PI, '/', 2)",
      "    -> arg(1, PI, Name), arg(2, PI, Arity), must_be(atom, Name), must_be(nonneg, Arity)",
      "    ; type_error(predicate_indicator, PI) ).",
      "",
      "rpc(Node, Goal) :- rpc(Node, Goal, []).",
      "",
      "rpc(Node0, Goal, Options) :-",
      "    validate_rpc_client_options(rpc, Options), browser_rpc_uri(Node0, Node),",
      "    term_variables(Goal, Variables),",
      "    Template =.. [v|Variables],",
      "    term_string(Node, NodeText),",
      "    wire_texts([Goal, Template], [GoalText, TemplateText]),",
      "    Offset = 0,",
      "    solution_limit(Options, Limit),",
      "    rpc_transport_options(Options, RemoteTimeout, Once, HTTPTimeout),",
      "    collect_rpc_load_text(Options, LoadText),",
      "    worker_rpc_page(NodeText, GoalText, TemplateText, Template, Offset, Limit, LoadText, RemoteTimeout, Once, HTTPTimeout).",
      "",
      "worker_rpc_page(NodeText, GoalText, TemplateText, Template, Offset, Limit, LoadText, RemoteTimeout, Once, HTTPTimeout) :-",
      "    Promise := actorRpc(#NodeText, #GoalText, #TemplateText, #Offset, #Limit, #LoadText, #RemoteTimeout, #Once, #HTTPTimeout),",
      "    actor_await(Promise, ResponseText),",
      "    (   catch(wire_read(ResponseText, Response), _, fail)",
      "    ->  true",
      "    ;   throw(rpc_error(parse_failed))",
      "    ),",
      "    (   Response = success(Slice, true)",
      "    ->  ( member(Bound, Slice), Template = Bound",
      "        ; Once == false,",
      "          length(Slice, Count), NextOffset is Offset + Count,",
      "          worker_rpc_page(NodeText, GoalText, TemplateText, Template, NextOffset, Limit, LoadText, RemoteTimeout, Once, HTTPTimeout)",
      "        )",
      "    ;   Response = success(Slice, false)",
      "    ->  member(Bound, Slice), Template = Bound",
      "    ;   Response = failure",
      "    ->  fail",
      "    ;   Response = error(Error)",
      "    ->  throw(Error)",
      "    ;   throw(rpc_error(unexpected_response))",
      "    ).",
      "",
      "promise(Node, Goal, Ref) :- promise(Node, Goal, Ref, []).",
      "",
      "promise(Node0, Goal, Ref, Options) :-",
      "    validate_rpc_client_options(promise, Options), browser_rpc_uri(Node0, Node),",
      "    option(template(Template), Options, Goal),",
      "    term_string(Node, NodeText),",
      "    wire_texts([Goal, Template], [GoalText, TemplateText]),",
      "    option(offset(Offset), Options, 0),",
      "    solution_limit(Options, Limit),",
      "    rpc_transport_options(Options, RemoteTimeout, Once, HTTPTimeout),",
      "    collect_rpc_load_text(Options, LoadText),",
      "    RefText := actorPromiseStart(#NodeText, #GoalText, #TemplateText, #Offset, #Limit, #LoadText, #RemoteTimeout, #Once, #HTTPTimeout),",
      "    atom_number(RefText, Ref).",
      "",
      "promise_cleanup(Ref) :-",
      "    must_be(integer, Ref), number_string(Ref, RefText), _ := actorPromiseCleanup(#RefText).",
      "",
      "yield(Ref, Message) :- yield(Ref, Message, []).",
      "",
      "yield(Ref, Message, Options0) :-",
      "    must_be(integer, Ref),",
      "    strip_module(Options0, Caller, Options),",
      "    validate_rpc_client_options(yield, Options),",
      "    option(timeout(Timeout), Options, -1),",
      "    number_string(Ref, RefText),",
      "    setup_call_cleanup(",
      "      ( Claim := actorPromiseClaim(#RefText),",
      "        ( Claim == missing_promise -> throw(error(existence_error(promise, Ref), context(yield/3, 'unknown, consumed or expired promise')))",
      "        ; Claim == busy_promise -> throw(error(permission_error(collect,promise,Ref), context(yield/3, 'promise already has a collector')))",
      "        ; true ) ),",
      "      ( Promise := actorPromiseWait(#RefText, #Claim, #Timeout),",
      "        actor_await(Promise, ResponseText),",
      "        ( ResponseText == null -> true ; ResponseText == \"missing_promise\" -> true",
      "        ; Status := actorPromiseCommit(#RefText, #Claim),",
      "          ( Status == committed -> true",
      "          ; throw(error(existence_error(promise, Ref), context(yield/3, 'promise disposed before collection'))) ) ) ),",
      "      (_ := actorPromiseRelease(#RefText, #Claim))),",
      "    (   ResponseText == \"missing_promise\"",
      "    ->  throw(error(existence_error(promise, Ref), context(yield/3, 'unknown or consumed promise')))",
      "    ;   ResponseText = null",
      "    ->  option(on_timeout(OnTimeout), Options, true),",
      "        ( once(call(Caller:OnTimeout))",
      "        -> (var(Message) -> Message = timeout ; true)",
      "        ; throw(error(timeout_callback_failed(Ref), context(yield/3, 'on_timeout goal failed'))) )",
      "    ;   catch(wire_read(ResponseText, Message), _, throw(rpc_error(parse_failed)))",
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
      "    browser_native_text(Source,Text0),",
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
      "    source_option_member(src_uri(URI0), Options), browser_uri_atom(URI0, URI),",
      "    term_string(URI, URIText),",
      "    Promise := actorLoadUri(#URIText),",
      "    actor_await(Promise, Text),",
      "    (Text = null -> throw(rpc_error(fetch_failed)) ; true).",
      "",
      "install_spawn_monitor(Pid, Options) :-",
      "    option(monitor(true), Options, false),",
      "    !,",
      "    term_string(Pid, PidText),",
      "    Promise := actorMonitor(#PidText, #PidText),",
      "    actor_await(Promise, _).",
      "install_spawn_monitor(_, _).",
      "",
      "actors(Pids) :-",
      "    Promise := actorActors(),",
      "    actor_await(Promise, PidsText),",
      "    term_string(Pids, PidsText).",
      "",
      "make_ref(Ref) :-",
      "    Promise := actorMakeRef(),",
      "    actor_await(Promise, RefText),",
      "    term_string(Ref, RefText).",
      "",
      "canonical_pid(Pid@localhost, Pid@localhost) :- integer(Pid), !.",
      "canonical_pid(Pid, Pid@localhost) :- integer(Pid), !.",
      "canonical_pid(Pid, Pid).",
      "",
      "transportable_term(Term) :-",
      "    acyclic_term(Term),",
      "    term_attvars(Term, []),",
      "    \\+ (sub_term(Sub, Term), nonvar(Sub), blob(Sub, BlobType), BlobType \\== text, BlobType \\== ucs_text, BlobType \\== reserved_symbol).",
      "must_be_transportable_term(Term) :-",
      "    ( transportable_term(Term) -> true",
      "    ; throw(error(type_error(transportable_term, Term), send/2)) ).",
      "",
      "Pid ! Message :- send(Pid, Message).",
      "",
      "%  Canonical term text (Semantic Contracts D5), as in the native node's",
      "%  wire_text.pl: quoted, operator-independent, no portray hooks, no",
      "%  numbervars, explicit variable names so that terms written together",
      "%  share their variables; read with double_quotes set to string.",
      "wire_text(Term, Text) :- wire_texts([Term], [Text]).",
      "wire_texts(Terms, Texts) :-",
      "    term_variables(Terms, Vars),",
      "    wire_variable_names(Vars, 1, Names),",
      "    maplist(wire_write(Names), Terms, Texts).",
      "wire_write(Names, Term, Text) :-",
      "    with_output_to(string(Text),",
      "        write_term(Term, [quoted(true), ignore_ops(true), portray(false), numbervars(false), variable_names(Names)])).",
      "wire_variable_names([], _, []).",
      "wire_variable_names([Var|Vars], N, [Name=Var|Names]) :-",
      "    format(atom(Name), '_~d', [N]), N1 is N + 1,",
      "    wire_variable_names(Vars, N1, Names).",
      "% Language text uses characters; bridge/library and wire strings stay native.",
      "language_read(Text, Term) :- term_string(Term, Text, [double_quotes(chars),module(user)]).",
      "browser_character(Char) :- atom(Char), atom_length(Char,1).",
      "browser_source_text(Text, Source) :-",
      "    ( atom(Text) -> Source=Text ; browser_native_text(Text,Source) ).",
      "browser_native_text(Text, Native) :-",
      "    ( atom(Text) -> atom_string(Text,Native)",
      "    ; string(Text) -> Native=Text",
      "    ; is_list(Text), maplist(browser_character,Text) -> string_chars(Native,Text)",
      "    ; type_error(atom_or_string,Text) ).",
      "% Materialised local clauses already contain typed terms, including native strings.",
      "browser_materialized_source(Options, Raw, Text) :-",
      "    option(node(Node0),Options,localhost), browser_uri_atom(Node0,Node),",
      "    ( Node == localhost",
      "    -> format(atom(Text),':- set_prolog_flag(double_quotes,string).~n~s~n:- set_prolog_flag(double_quotes,chars).~n',[Raw])",
      "    ; Text=Raw ).",
      "",
      ":- set_prolog_flag(user:double_quotes,chars).",
      "",
      "wire_read(Text, Term) :- term_string(Term, Text, [double_quotes(string)]).",
      "remote_answer_message(Text, Msg) :-",
      "    wire_read(Text, Raw),",
      "    ( nonvar(Raw), Raw = '$remote_answer'(Kind,Pid,Body,More)",
      "    -> ( catch((string(Body), wire_read(Body,Payload),",
      "                 must_be_transportable_term(Payload), remote_answer_payload(Kind,Payload)), _, fail)",
      "       -> (Kind == success -> Msg = success(Pid,Payload,More) ; Msg = error(Pid,Payload))",
      "       ; Msg = error(Pid,remote_answer_protocol_error(invalid_term)) )",
      "    ; Msg = Raw ).",
      "remote_answer_payload(success, Payload) :- is_list(Payload).",
      "remote_answer_payload(error, _).",
      "",
      "toplevel_event_text(error(_, Error), Text, Details) :- !,",
      "    term_string(Error, Text),",
      "    exception_display_text(Error, Details).",
      "toplevel_event_text(Message, Text, Text) :- term_string(Message, Text).",
      "exception_display_text(error(Formal0, _), Text) :- !,",
      "    display_formal_error(Formal0, Formal),",
      "    Term = error(Formal, Context),",
      "    term_string(Term, Text, [quoted(true), variable_names(['_'=Context])]).",
      "exception_display_text(Error, Text) :- term_string(Error, Text).",
      "display_formal_error(existence_error(procedure, Module:PI), existence_error(procedure, PI)) :-",
      "    atom(Module), sub_atom(Module, 0, _, _, 'actor_'), !.",
      "display_formal_error(Formal, Formal).",
      "",
      "send(terminal, Message) :-",
      "    shell_toplevel_role, !,",
      "    catch(flush_output(user_output), _, true),",
      "    catch(flush_output(user_error), _, true),",
      "    toplevel_event_text(Message, Text, Details),",
      "    _ := actorToplevelEvent(#Message, #Text, #Details).",
      "",
      "send(Pid, Message) :-",
      "    must_be_transportable_term(Message),",
      "    term_string(Pid, PidText),",
      "    wire_text(Message, MessageText),",
      "    Promise := actorSend(#PidText, #MessageText),",
      "    actor_await(Promise, Sent),",
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
      "    wire_text(Message, MessageText),",
      "    term_string(Id, IdText),",
      "    Promise := actorSendDelayed(#PidText, #MessageText, #Delay, #IdText),",
      "    actor_await(Promise, Sent),",
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
      "    actor_await(Promise, Cancelled),",
      "    Cancelled == true.",
      "",
      "monitor(Pid, Ref) :- make_ref(Ref), install_monitor(Pid, Ref).",
      "",
      "install_monitor(Pid, Ref) :-",
      "    term_string(Pid, PidText),",
      "    term_string(Ref, RefText),",
      "    Promise := actorMonitor(#PidText, #RefText),",
      "    actor_await(Promise, Monitored),",
      "    Monitored == true.",
      "",
      "demonitor(Ref) :- demonitor(Ref, []).",
      "",
      "demonitor(Ref, Options) :-",
      "    term_string(Ref, RefText),",
      "    Promise := actorDemonitor(#RefText),",
      "    actor_await(Promise, _),",
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
      "%  The first exit reason commits termination (Semantic Contracts D3).",
      "%  The reason is recorded with the worker, and the goal is then aborted;",
      "%  cleanup handlers run as it unwinds, and it cannot be resumed.",
      "exit(Reason) :-",
      "    term_string(Reason, ReasonText),",
      "    _ := actorRecordExit(#ReasonText),",
      "    abort.",
      "",
      "exit(Pid, Reason) :-",
      "    (   ( Pid == self ; self(Pid) )",
      "    ->  exit(Reason)",   // abort own goal, like exit/1 (desktop: thread_signal(exit))
      "    ;   term_string(Pid, PidText),",
      "        term_string(Reason, ReasonText),",
      "        Promise := actorExit(#PidText, #ReasonText),",
      "        actor_await(Promise, Exited),",
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
      "    actor_await(Promise, Registered),",
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
      "    actor_await(Promise, _).",
      "",
      "whereis(Name, Pid) :- whereis_name(actor, Name, Pid).",
      "whereis_service(Name, Pid) :- whereis_name(service, Name, Pid).",
      "",
      "whereis_name(Kind, Name, Pid) :-",
      "    term_string(Name, NameText),",
      "    Promise := actorWhereis(#Kind, #NameText),",
      "    actor_await(Promise, PidText),",
      "    term_string(Pid, PidText).",
      "",
      "respond(Pid, Answer) :-",
      "    self(Self),",
      "    send(Pid, '$input'(Self, Answer)).",
      "",
      "toplevel_spawn(Pid) :- toplevel_spawn(Pid, []).",
      "",
      "toplevel_spawn(Pid, Options) :-",
      "    validate_browser_wrapper_options(toplevel, toplevel_spawn/2, Options),",
      "    browser_named_creation(Options, Pid, toplevel_spawn/2, Inner, browser_toplevel_spawn_options(Pid, Inner)).",
      "browser_toplevel_spawn_options(Pid, Options) :-",
      "    option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
      "    option(session(Session), Options, false),",
      "    option(time_limit(TimeLimit0), Options, infinite),",
      "    option(idle_limit(IdleLimit0), Options, infinite),",
      "    normalize_ptcp_limit(time_limit, TimeLimit0, TimeLimit),",
      "    normalize_ptcp_limit(idle_limit, IdleLimit0, IdleLimit),",
      "    collect_spawn_source(Options, ExtraSource),",
      "    (   Node == localhost",
      "    ->  self(Self),",
      "        option(target(Target), Options, Self),",
      "        PidPromise := actorReservePid(),",
      "        actor_await(PidPromise, PidText),",
      "        term_string(LocalPid, PidText),",
      "        Pid = LocalPid@localhost,",
      "        Lifecycle = ptcp_options(Session, TimeLimit, IdleLimit),",
      "        term_string(swi_wasm_actor_bridge:ptcp(Pid, Target, Lifecycle), GoalText),",
      "        Promise := actorSpawnWithPid(#PidText, #GoalText, #ExtraSource),",
      "        actor_await(Promise, SpawnedText),",
      "        term_string(SpawnedPid, SpawnedText), SpawnedPid == LocalPid",
      "    ;   term_string(Node, NodeText),",
      "        term_string(Session, SessionText),",
      "        term_string(TimeLimit, TimeLimitText),",
      "        term_string(IdleLimit, IdleLimitText),",
      "        Promise := actorRemoteToplevelSpawn(#NodeText, #ExtraSource, #SessionText, #TimeLimitText, #IdleLimitText),",
      "        actor_await(Promise, PidText),",
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
      "normalize_ptcp_limit(_, infinite, infinite) :- !.",
      "normalize_ptcp_limit(Kind, Limit0, Limit) :-",
      "    must_be(number, Limit0),",
      "    ( Limit0 > 0 -> Limit = Limit0 ; throw(error(domain_error(Kind, Limit0), toplevel_spawn/2)) ).",
      "",
      "%  The worker restarts ptcp/3 after an abort or a running-time expiry,",
      "%  so the abort acknowledgement, the one-shot rule and the time-limit",
      "%  error are handled by the worker (restartAbortedPtcp).  The toplevel",
      "%  tells the worker its pid, its session mode and, while a query is",
      "%  active, the client to acknowledge (Semantic Contracts D3, D4).",
      "ptcp(Pid, Target, SessionOrLifecycle) :-",
      "    ptcp_lifecycle(SessionOrLifecycle, Session, TimeLimit, IdleLimit),",
      "    term_string(Pid, PidText),",
      "    term_string(Session, SessionText),",
      "    term_string(Target, TargetText),",
      "    _ := actorPtcpStart(#PidText, #SessionText, #TargetText),",
      "    catch(state_1(Pid, Target, Session, TimeLimit, IdleLimit), '$ptcp_idle_limit', true).",
      "",
      "ptcp_client(Target) :-",
      "    (   Target == none",
      "    ->  ClientText = \"\"",
      "    ;   wire_text(Target, ClientText)",
      "    ),",
      "    _ := actorPtcpClient(#ClientText).",
      "",
      "%  Discard control and input messages left over from an earlier query:",
      "%  those that arrived before the call and were skipped (deferred) while the",
      "%  toplevel waited for it.  A command sent after the call is kept.",
      "drain_stale_commands :-",
      "    forall(( clause(deferred(Message), true, Ref), stale_command(Message) ),",
      "           erase(Ref)).",
      "",
      "stale_command('$next'(_)).",
      "stale_command('$stop').",
      "stale_command('$input'(_, _)).",
      "",
      "ptcp_lifecycle(ptcp_options(Session, TimeLimit, IdleLimit), Session, TimeLimit, IdleLimit) :- !.",
      "ptcp_lifecycle(Session, Session, infinite, infinite).",
      "",
      "state_1(Pid, Target0, Session, TimeLimit, IdleLimit) :-",
      "    receive_idle({",
      "        '$call_text'(GoalText, Limit0, Offset, Once) ->",
      "            drain_stale_commands,",
      "            term_string(PlainGoal, GoalText, [variable_names(Bindings), double_quotes(chars),module(user)]),",
      "            Goal = user:PlainGoal,",
      "            dict_create(Template, bindings, Bindings),",
      "            ( Limit0 == none -> Limits = [] ; must_be(positive_integer, Limit0), Limits = [limit(Limit0)] ), append(Limits, [template(Template), offset(Offset), once(Once)], Options),",
      "            toplevel_run_call(Goal, Options, Target0, Pid, TimeLimit, IdleLimit) ;",
      "        '$call'(Goal, Options) ->",
      "            drain_stale_commands,",
      "            toplevel_run_call(Goal, Options, Target0, Pid, TimeLimit, IdleLimit) ;",
      "        '$reload' ->",
      "            catch(load_private_source('/worker_user_code.pl'), Error, send(Target0, error(Pid, Error)))",
      "        }, IdleLimit),",
      "    (   Session == false",
      "    ->  true",
      "    ;   state_1(Pid, Target0, Session, TimeLimit, IdleLimit)",
      "    ).",
      "",
      "receive_idle(Clauses, infinite) :- !, receive(Clauses).",
      "receive_idle(Clauses, IdleLimit) :-",
      "    receive(Clauses, [timeout(IdleLimit), on_timeout(throw('$ptcp_idle_limit'))]).",
      "",
      "toplevel_run_call(Goal, Options, Target0, Pid, TimeLimit, IdleLimit) :-",
      "            option(template(Template0), Options, Goal),",
      "            strip_module(Template0, _, Template),",
      "            option(offset(Offset), Options, 0),",
      "            ( option(limit(N), Options) -> must_be(positive_integer, N), Limit = count(N) ; Limit = all ),",
      "            option(once(Once), Options, false),",
      "            option(target(Target1), Options, Target0),",
      "            option('$request_ref'(RequestRef), Options, none), Target = target(Target1,RequestRef),",
      "            ptcp_client(Target1),",
      "            arm_time_limit(TimeLimit, Target, Pid),",
      "            state_2(Goal, Template, Offset, Limit, Once, Target, Pid, Answer),",
      "            disarm_time_limit(TimeLimit),",
      "            (   Answer = pending_error(Pid, Slice, Error)",
      "            ->  send_toplevel_answer(Target, success(Pid, Slice, true)),",
      "                state_3_error(Pid, Error, Target, IdleLimit)",
      "            ;   send_toplevel_answer(Target, Answer),",
      "                (   arg(3, Answer, true)",
      "                ->  state_3(Limit, Target, IdleLimit, TimeLimit, Pid)",
      "                ;   true",
      "                )",
      "            ),",
      "            ptcp_client(none).",
      "",
      "%  Solutions found before an exception are delivered as a page with more",
      "%  to come; the error answers the next request (Semantic Contracts D4).",
      "state_3_error(Pid, Error, Target, IdleLimit) :-",
      "    receive_idle({",
      "        '$next'(Options) ->",
      "            ptcp_next_ref(Options, Target),",
      "            (   option(target(NewTarget), Options)",
      "            ->  nb_setarg(1, Target, NewTarget),",
      "                ptcp_client(NewTarget)",
      "            ;   true",
      "            ),",
      "            send_toplevel_answer(Target, error(Pid, Error)) ;",
      "        '$stop' -> true",
      "    }, IdleLimit).",
      "",
      "arm_time_limit(infinite, _, _) :- !.",
      "arm_time_limit(TimeLimit, TargetBox, Pid) :-",
      "    arg(1,TargetBox,Target), ptcp_reply_ref(TargetBox,Ref), term_string(Ref,RefText), term_string(Target, TargetText),",
      "    term_string(Pid, PidText),",
      "    true := actorArmTimeLimit(#TimeLimit, #TargetText, #PidText, #RefText).",
      "",
      "disarm_time_limit(infinite) :- !.",
      "disarm_time_limit(_) :- true := actorDisarmTimeLimit().",
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
      "state_3(Limit, Target, IdleLimit, TimeLimit, Pid) :-",
      "    receive_idle({",
      "        '$next'(Options2) ->",
      "            ptcp_next_ref(Options2, Target),",
      "            (   option(limit(NewLimit), Options2)",
      "            ->  must_be(positive_integer, NewLimit), nb_setarg(1, Limit, NewLimit)",
      "            ;   true",
      "            ),",
      "            (   option(target(NewTarget), Options2)",
      "            ->  nb_setarg(1, Target, NewTarget),",
      "                ptcp_client(NewTarget)",
      "            ;   true",
      "            ),",
      "            arm_time_limit(TimeLimit, Target, Pid),",
      "            fail ;",
      "        '$stop' -> true",
      "    }, IdleLimit).",
      "",
      "answer(Goal, Template, Offset, Limit, Answer) :-",
      "    answer_(Goal, Template, Offset, Limit, Answer0),",
      "    portable_answer(Answer0, Answer).",
      "",
      "answer_(Goal, Template, Offset, Limit, Answer) :-",
      "    Pending = pending(none),",
      "    catch(call_cleanup(slice(capture_error(Goal, Pending), Template, Offset, Limit, Slice), Det = true), Error, true),",
      "    arg(1, Pending, Cell),",
      "    (   nonvar(Error), control_exception(Error)",
      "    ->  throw(Error)",
      "    ;   Cell = caught(Captured), Slice \\== [], Limit \\== all",
      "    ->  normalize_resource_error(Captured, PublicError), Answer = pending_error(Slice, PublicError)",
      "    ;   Cell = caught(Captured)",
      "    ->  normalize_resource_error(Captured, PublicError), Answer = error(PublicError)",
      "    ;   nonvar(Error)",
      "    ->  normalize_resource_error(Error, PublicError), Answer = error(PublicError)",
      "    ;   Slice == []",
      "    ->  Answer = failure",
      "    ;   var(Det)",
      "    ->  Answer = success(Slice, true)",
      "    ;   Det == true",
      "    ->  Answer = success(Slice, false)",
      "    ).",
      "",
      "%  Run Goal, recording an ordinary exception instead of letting it discard",
      "%  the solutions already collected for the current page.",
      "capture_error(Goal, Pending) :-",
      "    catch(Goal, E, record_goal_error(E, Pending)).",
      "",
      "record_goal_error(E, _) :-",
      "    control_exception(E),",
      "    !,",
      "    throw(E).",
      "record_goal_error(E, Pending) :-",
      "    nb_setarg(1, Pending, caught(E)),",
      "    fail.",
      "",
      "%  An answer is a plain term (Semantic Contracts D5): a page whose solutions",
      "%  carry constraints cannot be represented, and ends the query with a",
      "%  representation error.",
      "portable_answer(Answer0, Answer) :-",
      "    answer_slice(Answer0, Slice),",
      "    \\+ term_attvars(Slice, []),",
      "    !,",
      "    Answer = error(error(representation_error(constraints), _)).",
      "portable_answer(Answer, Answer).",
      "",
      "answer_slice(success(Slice, _), Slice).",
      "answer_slice(pending_error(Slice, _), Slice).",
      "",
      "normalize_resource_error(error(resource_error(Resource), _),",
      "                         error(resource_error(space), _)) :-",
      "    nonvar(Resource),",
      "    memberchk(Resource, [space, stack, memory, heap, trail, global_stack, local_stack]),",
      "    !.",
      "normalize_resource_error(time_limit_exceeded, error(resource_error(time), _)) :- !.",
      "normalize_resource_error(error(resource_error(time), _), error(resource_error(time), _)) :- !.",
      "normalize_resource_error(Error, Error).",
      "slice(Goal, Template, Offset, all, Slice) :- !, findall(Template, offset(Offset, Goal), Slice).",
      "slice(Goal, Template, Offset, Limit, Slice) :-",
      "    findnsols(Limit, Template, offset(Offset, Goal), Slice).",
      "",
      "apply_once_answer(true, success(Slice, _), success(Slice, false)) :- !.",
      "apply_once_answer(true, pending_error(Slice, _), success(Slice, false)) :- !.",
      "apply_once_answer(_, Answer, Answer).",
      "",
      "add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).",
      "add_pid(failure, Pid, failure(Pid)).",
      "add_pid(error(Term), Pid, error(Pid, Term)).",
      "add_pid(pending_error(Slice, Term), Pid, pending_error(Pid, Slice, Term)).",
      "",
      "solution_limit(Options, Limit) :- ( option(limit(Limit), Options) -> must_be(positive_integer, Limit) ; Limit = none ).",
      "validate_solution_limit(Options) :- solution_limit(Options, _).",
      "validate_once_options(Options) :- must_be(list, Options), forall((member(Option, Options), nonvar(Option), Option = once(Value)), must_be(boolean, Value)).",
      "synchronous_remote_support(Node, Supported) :-",
      "    term_string(Node, NodeText), Promise := actorToplevelCorrelation(#NodeText), actor_await(Promise, Supported).",
      "synchronous_send(Pid, Message) :-",
      "    wire_text(Pid, PidText), wire_text(Message, MessageText),",
      "    Promise := actorSynchronousSend(#PidText, #MessageText), actor_await(Promise, Sent),",
      "    ( Sent == true -> true ; Pid = _@Node, throw(error(permission_error(use,toplevel_correlation,Node),_)) ).",
      "toplevel_call(Pid, Goal) :- toplevel_call(Pid, Goal, []).",
      "toplevel_call(Pid, Goal, Options) :- validate_once_options(Options), validate_solution_limit(Options), send(Pid, '$call'(Goal, Options)).",
      "",
      "toplevel_next(Pid) :- toplevel_next(Pid, []).",
      "toplevel_next(Pid, Options) :- validate_solution_limit(Options), send(Pid, '$next'(Options)).",
      "",
      "toplevel_halt(Pid) :- exit(Pid, true).",
      "",
      "%  await/2 is not permitted in a setup_call_cleanup/3 cleanup in",
      "%  SWI-WASM. Down delivery retires the monitor in the coordinator;",
      "%  the final demonitor is therefore an idempotent bridge cleanup.",
      "toplevel_halt(Pid, true) :-",
      "    monitor(Pid, Ref),",
      "    toplevel_halt(Pid),",
      "    receive({down(Pid, Ref, _) -> true}),",
      "    demonitor(Ref, [flush]).",
      "",
      "toplevel_stop(Pid) :- send(Pid, '$stop').",
      "",
      "toplevel_abort(Pid) :-",
      "    term_string(Pid, PidText),",
      "    Promise := actorAbort(#PidText),",
      "    actor_await(Promise, Aborted),",
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
      "    ( is_list(Prompt), maplist(browser_character,Prompt) -> string_chars(PromptTerm,Prompt) ; PromptTerm=Prompt ),",
      "    (   option(target(Target), Options)",
      "    ->  send(Target, prompt(Self, PromptTerm)),",
      "        receive({'$input'(_, Answer) -> true ; '$input_text'(_, Line) -> language_read(Line,Answer)})",
      "    ;   io_target(Target)",
      "    ->  send(Target, prompt(Self, PromptTerm)),",
      "        receive({'$input'(_, Answer) -> true ; '$input_text'(_, Line) -> language_read(Line,Answer)})",
      "    ;   ( atom(PromptTerm) -> atom_string(PromptTerm,PromptText)",
      "        ; string(PromptTerm) -> PromptText=PromptTerm ; term_string(PromptTerm,PromptText) ),",
      "        Promise := actorInput(#PromptText),",
      "        actor_await(Promise, AnswerText),",
      "        AnswerText \\== null,",
      "        language_read(AnswerText, Answer)",
      "    ).",
      "",
      ":- dynamic behaviour_source_load/1, behaviour_source_block/1.",
      "% The active load's clause reference scopes markers across nested loads and",
      "% is erased on success, exception or interruption, even without an end marker.",
      "load_behaviour_source(File) :-",
      "    browser_native_text(File,NativePath), atom_string(Path,NativePath),",
      "    setup_call_cleanup(",
      "        asserta(behaviour_source_load(Path), Ref),",
      "        user:consult(Path),",
      "        (erase(Ref), retractall(behaviour_source_block(Ref)), set_prolog_flag(user:double_quotes,chars))",
      "    ).",
      "behaviour_source_boundary(Boundary) :-",
      "    prolog_load_context(file, File),",
      "    clause(behaviour_source_load(File), true, Ref), !,",
      "    ( Boundary == begin -> assertz(behaviour_source_block(Ref)), set_prolog_flag(user:double_quotes,string)",
      "    ; retractall(behaviour_source_block(Ref)), set_prolog_flag(user:double_quotes,chars) ).",
      "behaviour_source_boundary(_).",
      "internal_behaviour_loading :-",
      "    prolog_load_context(file, File),",
      "    clause(behaviour_source_load(File), true, Ref),",
      "    behaviour_source_block(Ref).",
      "user:message_hook(ignored_weak_import(user, swi_wasm_actor_bridge:_), warning, _) :-",
      "    swi_wasm_actor_bridge:internal_behaviour_loading.",
      "",
      "load_private_source(File) :-",
      "    setup_call_cleanup(",
      "        asserta(suppress_shared_override_warnings, Ref),",
      "        load_behaviour_source(File),",
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
      "actor_await(Promise, Result) :-",
      "    Wrapped := actorAwait(#Promise),",
      "    await(Wrapped, Result),",
      "    Pending := actorControlPending(),",
      "    ( Pending == true -> abort ; true ).",
      "",
      "% Cleanup must not await: withdraw the monitor and filter until the host barrier.",
      "supervisor_shutdown_cleanup(Ref) :-",
      "    catch((assertz(retiring_supervisor_shutdown(Ref)),",
      "           forall((clause(deferred(Msg), true, Clause), nonvar(Msg),",
      "                   Msg = Tag-_, Tag == Ref), erase(Clause)),",
      "           server_monitor_cleanup(Ref)), _, true).",
      "server_monitor_cleanup(Ref) :-",
      "    ( var(Ref) -> true",
      "    ; catch((flush_deferred_server_monitor(Ref),",
      "             (retiring_server_monitor(Ref) -> true ; assertz(retiring_server_monitor(Ref))),",
      "             term_string(Ref, RefText), _ := actorServerMonitorCleanup(#RefText)), _, true) ).",
      "",
      "flush_deferred_server_monitor(Ref) :-",
      "    forall((clause(deferred(Msg), true, Clause), nonvar(Msg),",
      "            Msg = down(_, MessageRef, _), MessageRef == Ref), erase(Clause)).",
      "",
      "discard_server_monitor_message('$startup_retire'(Refs)) :- !, maplist(server_monitor_cleanup, Refs).",
      "discard_server_monitor_message('$server_monitor_cleaned'(Ref)) :-",
      "    retiring_server_monitor(Retired), Ref == Retired, !, retractall(retiring_server_monitor(Ref)), retractall(retiring_supervisor_shutdown(Ref)).",
      "discard_server_monitor_message(Ref-_) :- retiring_supervisor_shutdown(Retired), Ref == Retired.",
      "discard_server_monitor_message(down(_, Ref, _)) :- retiring_server_monitor(Retired), Ref == Retired.",
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
      "    actor_await(Promise, MessageText),",
      "    (   MessageText = null",
      "    ->  option(on_timeout(Goal), Options, true),",
      "        clauses_module(Clauses, Module),",
      "        call(Module:Goal)",
      "    ;   remote_answer_message(MessageText, Msg),",
      "        ( (discard_server_monitor_message(Msg) ; discard_worker_scope_message(Msg)) -> receive_loop(Clauses, Options)",
      "        ; assertz(deferred(Msg), Ref),",
      "        (   select_body(Clauses, Msg, Module, Body)",
      "        ->  erase(Ref),",
      "            call(Module:Body)",
      "        ;   receive_loop(Clauses, Options)",
      "        ) )",
      "    ).",
      "",
      "%  A new message is recorded as deferred before its guards run, and the",
      "%  record is erased only when a clause is selected.  A control exception",
      "%  escaping from a guard therefore leaves the message in the mailbox",
      "%  (Semantic Contracts D2). The privileged await bridge checks control",
      "%  state after wakeup; application messages cannot impersonate a signal.",
      "",
      "guard_exception(E) :-",
      "    control_exception(E),",
      "    !,",
      "    throw(E).",
      "guard_exception(_) :-",
      "    fail.",
      "",
      "control_exception(E) :- var(E), !, fail.",
      "control_exception('$abort_goal').",
      "control_exception('$ptcp_time_limit').",
      "control_exception('$aborted').",
      "control_exception(unwind(_)).",
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
      "        catch(once(Module:Guard), E, guard_exception(E))",
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
      "swi_wasm_actor_bridge:wire_read(GoalText, Goal), catch(catch((call(Goal) -> Outcome = true ; Outcome = false), '$actor_exit'(Reason), Outcome = Reason), Error, Outcome = exception(Error)), term_string(Outcome, OutcomeText), _ := actorSetDoneReason(#OutcomeText)",
      { GoalText: currentGoalText },
      function(answer) {
        flushOutput(true);
        post("answer", { answer: answer || {} });
      },
      { heartbeat: 10000 }
    ).then(function() {
      // A goal that completed is never restarted, even if an abort arrived
      // while it was finishing (Semantic Contracts D3).
      flushOutput(true);
      actorDisarmTimeLimit();
      post("done", { reason: exitReason || "true" });
    }).catch(function(error) {
      flushOutput(true);
      if (exitReason !== null) {
        // exit/1 aborts the goal after recording its reason.
        actorDisarmTimeLimit();
        post("done", { reason: exitReason });
        return undefined;
      }
      if ((abortRequested || ptcpTimeLimitRequested) && isPtcpGoal()) {
        return restartAbortedPtcp(error);
      }
      actorDisarmTimeLimit();
      post("error", { error: String(error) });
    });
  }

  function installStatechartRuntime(message) {
    var names = [
      "sxml_schema.pl",
      "statechart_wasm_runtime.pl",
      "statechart_wasm_model.pl",
      "statechart_wasm_exec.pl",
      "statechart_wasm.pl"
    ];
    try { Module.FS.mkdir("/wasm"); } catch (_) {}
    return Promise.all(names.map(function(name) {
      return fetch(runtimeAsset(name), { cache: "no-store" }).then(function(response) {
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
        "statechart_actor_start :-",
        "    read_file_to_string('/statechart.xml', XML, []),",
        "    statechart_wasm:set_trace_enabled(" + (message.statechartTrace === false ? "false" : "true") + "),",
        "    statechart_wasm:statechart_start(text(XML), " + JSON.stringify(String(message.statechartSupportSource || "")) + ").",
        "statechart_actor_loop :- statechart_actor_wait.",
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
      // Do not announce this actor as ready until its SXML has passed DTD and
      // semantic validation and the initial model has been constructed.  A
      // startup exception then rejects actorStatechartSpawn/7 in the parent
      // worker, so statechart_spawn/2 reports the error at the toplevel.
      var startResult = Prolog.query("user:statechart_actor_start").once();
      if (!startResult || startResult.error) {
        throw new Error(startResult && startResult.message
          ? startResult.message
          : "statechart startup failed");
      }
    });
  }

  function installInitialIoTarget(message) {
    var ioTarget = String(message.ioTarget || "");
    if (!ioTarget) return;
    if (!Prolog.query(
      "term_string(Target," + JSON.stringify(ioTarget) + ")," +
      "retractall(swi_wasm_actor_bridge:io_target(_))," +
      "assertz(swi_wasm_actor_bridge:io_target(Target))"
    ).once()) {
      throw new Error("invalid io_target for worker actor");
    }
  }

  function runtimeAsset(name) {
    var assets = workerConfiguration.assets || {};
    if (name === "engine") return assets.engineUrl || "/swipl-bundle.js";
    if (name === "shared_db.pl" && Object.prototype.hasOwnProperty.call(assets,"sharedDatabaseUrl")) return assets.sharedDatabaseUrl;
    return (assets.prologBaseUrl || "/wasm/") + name;
  }

  function start(message) {
    if (message.assets) workerConfiguration.assets = message.assets;
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
    importScripts(runtimeAsset("engine"));
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
        installInitialIoTarget(message);
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
      deliver("'$input_text'(terminal," + JSON.stringify(inputArg) + ")");
      post("responded", {});
      return;
    }
    if (message.command === "toplevel_abort" && workerRole === "shell_toplevel") {
      // The abort event is the toplevel's acknowledgement, posted once the
      // abort has taken effect (Semantic Contracts D4).
      abortCurrentGoal();
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
