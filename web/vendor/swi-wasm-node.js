// SPDX-License-Identifier: MIT
// Browser-node runtime. Host presentation adapters live in demonstrator.html.
// Kept in vendor/ so existing native static routes can serve it unchanged.
(function(root, factory) {
  var api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.SwiWasmNode = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function() {
  "use strict";
      function normalizeNodeUrl(url) {
        if (typeof url !== "string" || url.trim() === "") {
          return null;
        }
        var trimmed = url.trim();
        if (trimmed.charAt(0) === "'" && trimmed.charAt(trimmed.length - 1) === "'") {
          trimmed = trimmed.slice(1, -1);
        }
        var markdown = /^\[(https?:\/\/[^\]]+)\]\((https?:\/\/[^)]+)\)$/.exec(trimmed);
        if (markdown) {
          trimmed = markdown[2];
        }
        if (trimmed.charAt(trimmed.length - 1) === "/") {
          trimmed = trimmed.slice(0, -1);
        }
        try {
          return new URL(trimmed);
        } catch (error) {
          return null;
        }
      }

      function isLoopbackHost(host) {
        return host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
      }

      function resolveBrowserRpcBaseUri(baseUri) {
        var base = String(baseUri || "").replace(/^'|'$/g, "").trim();
        var current;
        var normalized;
        function withoutTrailingSlash(url) {
          return String(url || "").replace(/\/$/, "");
        }
        normalized = normalizeNodeUrl(base);
        if (normalized) {
          return withoutTrailingSlash(normalized.href);
        }
        if (base === "localhost" || isLoopbackHost(base)) {
          current = normalizeNodeUrl(window.location.origin);
          if (current && current.protocol !== "file:") {
            return withoutTrailingSlash(current.origin);
          }
          return "http://localhost";
        }
        return base;
      }

      // Resolve source supplied to rpc/3's src_uri/1 before the browser
      // fetches it.  The terminal can paste a Markdown link such as
      // '[https://n2...](https://n2.../)', while the HTTP client needs the
      // actual link target.  Keep relative URI support for node-local source.
      function resolveBrowserRpcLoadUri(uri) {
        var source = String(uri || "");
        var normalized = normalizeNodeUrl(source);
        if (normalized) {
          return normalized.href;
        }
        try {
          return new URL(source, window.location.origin).href;
        } catch (error) {
          return source;
        }
      }

      // term_string/2 renders a qualified service address as
      // Name@'https://node'.  Numeric distributed pids have their own parser;
      // this one deliberately accepts only atom-valued left operands so that
      // send/2 can route a published service without widening monitor/exit to
      // non-pid targets.
      function parseSwiWasmQualifiedServiceAddress(pidText) {
        var text = String(pidText || "").trim();
        var match = /^([a-z][A-Za-z0-9_]*|'(?:\\.|[^'])*')\s*@\s*'((?:\\.|[^'])*)'$/.exec(text);
        var name;
        if (!match) {
          return null;
        }
        name = match[1];
        if (name.charAt(0) === "'") {
          name = name.slice(1, -1).replace(/\\(.)/g, "$1");
        }
        return {
          pid: name,
          node: match[2].replace(/\\(.)/g, "$1")
        };
      }

      // Browser actors are exposed to Prolog as Id@localhost, while the
      // JavaScript node controller keeps using the decimal Id as its
      // worker-map key.  Keep the conversion at this boundary so localhost
      // remains a local-node designator rather than a network destination.
      function qualifySwiWasmLocalPid(pidText) {
        var text = String(pidText || "").trim();
        if (text === "main") return "main@localhost";
        return /^[1-9][0-9]{9}$/.test(text) ? text + "@localhost" : text;
      }

      function localizeSwiWasmPid(pidText) {
        var text = String(pidText || "").trim();
        if (/^main\s*@\s*'?localhost'?$/.test(text)) return "main";
        var match = /^([1-9][0-9]{9})\s*@\s*'?localhost'?$/.exec(text);
        return match ? match[1] : text;
      }


      function splitTopLevelArgs(text) {
        var parts = [];
        var start = 0;
        var depthParen = 0;
        var depthBracket = 0;
        var depthBrace = 0;
        var quote = null;
        var i;
        var ch;
        for (i = 0; i < text.length; i += 1) {
          ch = text.charAt(i);
          if (quote !== null) {
            if (ch === quote) {
              if (text.charAt(i + 1) === quote) {
                i += 1;
              } else {
                quote = null;
              }
            }
            continue;
          }
          if (ch === "'" || ch === '"') {
            quote = ch;
            continue;
          }
          if (ch === "(") {
            depthParen += 1;
            continue;
          }
          if (ch === ")") {
            depthParen = Math.max(0, depthParen - 1);
            continue;
          }
          if (ch === "[") {
            depthBracket += 1;
            continue;
          }
          if (ch === "]") {
            depthBracket = Math.max(0, depthBracket - 1);
            continue;
          }
          if (ch === "{") {
            depthBrace += 1;
            continue;
          }
          if (ch === "}") {
            depthBrace = Math.max(0, depthBrace - 1);
            continue;
          }
          if (ch === "," && depthParen === 0 && depthBracket === 0 && depthBrace === 0) {
            parts.push(text.slice(start, i).trim());
            start = i + 1;
          }
        }
        parts.push(text.slice(start).trim());
        return parts.filter(function(part) {
          return part !== "";
        });
      }
      function unwrapPrologCompound(text, name) {
        var value = String(text || "").trim();
        var prefix = name + "(";
        if (value.slice(0, prefix.length) !== prefix || value.charAt(value.length - 1) !== ")") {
          return null;
        }
        return splitTopLevelArgs(value.slice(prefix.length, -1));
      }
      function stripRuntimeErrorScaffolding(text) {
        var value = String(text || "").trim();
        var next;
        var changed = true;
        while (changed) {
          changed = false;
          next = value.replace(/^(?:uncaught\s+exception|prolog\s+exception)\s*:\s*/i, "");
          if (next !== value) {
            value = next.trim();
            changed = true;
            continue;
          }
          next = value.replace(/^(?:[^:\s]+:)+[^:\s]+:\s*/, "");
          if (next !== value &&
              /^(?:error\(|exception\(|Unknown procedure:|existence_error\(|permission_error\(|type_error\(|domain_error\(|instantiation_error|representation_error\(|evaluation_error\(|resource_error\(|syntax_error\(|system_error)/.test(next)) {
            value = next.trim();
            changed = true;
          }
        }
        return value;
      }
      function exceptionDisplayTerm(text) {
        var value = stripRuntimeErrorScaffolding(text);
        var args = unwrapPrologCompound(value, "exception");
        var formal;
        if (args && args.length >= 1) {
          value = args[0];
        }
        args = unwrapPrologCompound(value, "error");
        if (!args || args.length < 1) {
          return value;
        }
        formal = args[0].replace(
          /^existence_error\(procedure,actor_[A-Za-z0-9_]+:([^()]+\/\d+)\)$/,
          "existence_error(procedure,$1)"
        );
        return "error(" + formal + ",_)";
      }
      function sanitizeDownReasonTerm(text) {
        var value = String(text || "terminated").trim();
        var args = unwrapPrologCompound(value, "exception");
        if (args && args.length >= 1) {
          return "exception(" + exceptionDisplayTerm(args[0]) + ")";
        }
        return value;
      }
  var methods = {
          loadSwiWasmMainSource: function(codeToLoad) {
            var self = this;
            var Prolog = this.swiWasmProlog;
            var Module = this.swiWasmModule;
            var loadErr = null;
            var bridgeCode = this.swiWasmRpcProlog();
            // library(wasm) is already loaded (preloaded at init), so :=/2 and #/1
            // operators are defined before consult runs.
            if (Module && Module.FS) {
              try {
                Module.FS.writeFile("/swi_wasm_actor_bridge.pl", bridgeCode);
                var bridgeLoaded = Prolog.query("consult('/swi_wasm_actor_bridge.pl')").once();
                if (!bridgeLoaded) {
                  throw new Error("Unable to consult the SWI-WASM actor bridge.");
                }
                var bridgeImported = Prolog.query("use_module('/swi_wasm_actor_bridge.pl')").once();
                if (!bridgeImported) {
                  throw new Error("Unable to import the SWI-WASM actor bridge.");
                }
                // Operators declared inside the bridge module are not
                // automatically visible while the terminal renders answers
                // in user.  Match the node-side distributed-pid notation.
                Prolog.query("user:op(200, xfx, @)").once();
                // Deferred unmatched messages are actor mailbox state. Preserve
                // them across toplevel queries just like a persistent node does.
                //  read/1 and read_term/2 must be redefined in the USER module
                //  (where the program runs) to use the inline terminal -- the
                //  bridge module's copy can't override the built-in for user
                //  calls.  Consult a small shim into user that delegates to the
                //  bridge's async reader. Spawned workers do not receive this
                //  shell-only shim through explicit src_* options.
                Module.FS.writeFile("/swi_wasm_read_shim.pl",
                  ":- catch(redefine_system_predicate(read(_)), _, true).\n" +
                  ":- catch(redefine_system_predicate(read_term(_, _)), _, true).\n" +
                  "read(T) :- read_term(T, []).\n" +
                  "read_term(T, _) :- swi_wasm_actor_bridge:swi_wasm_read_term(T).\n");
                Prolog.query("consult('/swi_wasm_read_shim.pl')").once();
                Module.FS.writeFile("/user_code.pl", codeToLoad);
                self.swiWasmOutputBuffer = "";
                Prolog.query("swi_wasm_actor_bridge:load_private_source('/user_code.pl')").once();
                console.log("[SWI-QUERY] consult ok, output:", self.swiWasmOutputBuffer);
                self.swiWasmOutputBuffer = "";
              } catch(e) { loadErr = e; console.error("[SWI-QUERY] consult threw:", e); }
            } else {
              console.error("[SWI-QUERY] Module.FS not available");
            }
            return loadErr ? Promise.reject(loadErr) : Promise.resolve();
          },
          driveSwiWasmMainQuery: function(goal, onAnswer) {
            var drivenGoal = "swi_wasm_actor_bridge:swi_wasm_drive(user:(" + goal + "))";
            return this.swiWasmProlog.forEach(drivenGoal, {}, onAnswer, { heartbeat: 1 });
          },
          makeBrowserPromiseRef: function(existing) {
            var ref;
            this.swiWasmIssuedPromiseRefs = this.swiWasmIssuedPromiseRefs || {};
            do { ref = this.randomSwiIdentity(); }
            while (this.swiWasmIssuedPromiseRefs[ref] || (existing && existing[ref]));
            this.swiWasmIssuedPromiseRefs[ref] = true;
            return ref;
          },

          cleanupSwiWasm2ShellEntry: function(pid, entry) {
            var current = this.swiWasmActorWorkers[pid];
            if (!entry || current !== entry) {
              return;
            }
            if (entry.retireTimer) {
              clearTimeout(entry.retireTimer);
              entry.retireTimer = null;
            }
            if (entry.worker) {
              this.disposeSwiWasmPromiseRequest(pid);
              try { entry.worker.terminate(); } catch (_error) {}
            }
            delete this.swiWasmActorWorkers[pid];
          },
          retireSwiWasm2Shell: function(pid) {
            var entry = this.swiWasmActorWorkers[pid];
            var envelope;
            if (!entry || !entry.worker || entry.done) {
              this.cleanupSwiWasm2ShellEntry(pid, entry);
              return;
            }
            entry.shellRetired = true;
            envelope = {
              command: "toplevel_halt",
              pid: Number(pid)
            };
            this.logSwiWasmWorkerTraffic(envelope, "request");
            entry.worker.postMessage(envelope);
            entry.retireTimer = setTimeout(function() {
              this.cleanupSwiWasm2ShellEntry(pid, entry);
            }.bind(this), 1000);
          },
          replaceSwiWasm2Shell: function(sourceText) {
            var oldPid = String(this.swiWasm2ShellPid);
            var oldEntry = this.swiWasmActorWorkers[oldPid];
            var newPid = this.reserveSwiWasmWorkerActorPid();
            var source = String(sourceText || "");
            var goal = "swi_wasm_actor_bridge:ptcp(" +
              qualifySwiWasmLocalPid(newPid) + ",terminal,true)";
            return this.spawnSwiWasmWorkerActorReady(
              goal,
              source,
              newPid,
              "",
              "shell_toplevel",
              { shellCandidate: true }
            ).then(function(readyPid) {
              var entry = this.swiWasmActorWorkers[readyPid];
              if (!entry || entry.done || !entry.ready) {
                throw new Error("Replacement SWI-WASM toplevel did not become ready.");
              }
              entry.shellCandidate = false;
              this.swiWasm2ShellPid = readyPid;
              this.swiWasm2ShellReady = true;
              this.swiWasm2QueryPending = false;
              this.swiWasm2LoadedSource = source;
              this.swiWasmHostEvent("session_replaced", {pid:readyPid});
              try {
                this.retireSwiWasm2Shell(oldPid);
              } catch (retireError) {
                this.log("WARN", "SWI-WASM", "Could not halt replaced Worker toplevel " + oldPid + ": " +
                  (retireError && retireError.message ? retireError.message : retireError));
                this.cleanupSwiWasm2ShellEntry(oldPid, oldEntry);
              }
              return readyPid;
            }.bind(this)).catch(function(error) {
              var candidate = this.swiWasmActorWorkers[newPid];
              this.cleanupSwiWasm2ShellEntry(newPid, candidate);
              throw error;
            }.bind(this));
          },

          initSwiWasmSession: function() {
            var self = this;
            // Compatibility model: keep the shell engine on the UI thread so
            // library(dom) can call browser DOM APIs directly.
            this.swiWasmHostEvent("loading", {});
            window.swiRpcGet = function(url) {
              console.log("[SWI-RPC] GET", url);
              var xhr = new XMLHttpRequest();
              xhr.open("GET", url, false);
              try {
                xhr.send();
                console.log("[SWI-RPC] status", xhr.status, "len", xhr.responseText.length);
                return xhr.responseText;
              }
              catch(e) { console.error("[SWI-RPC] error", e); return null; }
            };
            // Keep user-provided source verbatim, but do not add a second full
            // stop when a multiline src_text/1 string ends with whitespace.
            // A second standalone `.` is a syntax error on the remote node.
            window.swiEnsureFinalFullStop = function(text) {
              var source = String(text);
              return /\.\s*$/.test(source) ? source : source + ".";
            };
            // The RPC predicate awaits this promise between pages.  Do not use
            // the synchronous helper above: it would block the browser and
            // make Abort ineffective during an unbounded remote enumeration.
            window.swiRpcGetAsync = function(url, httpTimeout) {
              var controller = new AbortController();
              window.swiRpcAbortController = controller;
              var timeout = httpTimeout === null || httpTimeout === undefined
                ? NaN
                : Number(httpTimeout);
              var timer = isFinite(timeout) && timeout >= 0
                ? setTimeout(function() { controller.abort(); }, timeout * 1000)
                : null;
              var request = fetch(url, {
                credentials: "same-origin",
                signal: controller.signal
              }).then(function(response) {
                return response.text();
              }).then(function(text) {
                // A task boundary, rather than only a promise microtask,
                // lets click handlers run between rapid same-origin pages.
                return new Promise(function(resolve) {
                  setTimeout(function() { resolve(text); }, 25);
                });
              });
              var cancelled = new Promise(function(_, reject) {
                controller.signal.addEventListener("abort", function() {
                  reject(new Error("RPC aborted"));
                }, { once: true });
              });
              return Promise.race([request, cancelled]).finally(function() {
                if (timer !== null) clearTimeout(timer);
                if (window.swiRpcAbortController === controller) {
                  window.swiRpcAbortController = null;
                }
              });
            };
            window.swiAbortRpc = function() {
              if (window.swiRpcAbortController) {
                window.swiRpcAbortController.abort();
                window.swiRpcAbortController = null;
              }
            };
            window._swi_rpc_get = function(url) {
              var xhr = new XMLHttpRequest();
              xhr.open("GET", url, false);
              try { xhr.send(); return xhr.responseText; }
              catch(e) { return null; }
            };
            window.swiResolveRpcBase = function(baseUri) {
              return resolveBrowserRpcBaseUri(baseUri);
            };
            window.swiResolveRpcLoadUri = function(uri) {
              return resolveBrowserRpcLoadUri(uri);
            };
            window.swiResolveAssetUrl = function(uri) {
              return new URL(String(uri || ""), window.location.origin).href;
            };
            this.installSwiWasmActorBridge();
            window._swiPromiseStore = createSwiWasmPromiseStore({
              mint: function() { return self.makeBrowserPromiseRef(window._swiPromiseStore.items); },
              errorText: function() { return "error(rpc_error(fetch_failed))."; }
            });
            window.swiPromiseStart = function(url, httpTimeout) {
              return window._swiPromiseStore.create(function() {
                var controller = new AbortController();
                var timeout = httpTimeout === null || httpTimeout === undefined ? NaN : Number(httpTimeout);
                var timer = isFinite(timeout) && timeout >= 0
                  ? setTimeout(function() { controller.abort(); }, timeout*1000) : null;
                var promise;
                try {
                  promise = fetch(url, {signal:controller.signal}).then(function(response) { return response.text(); })
                    .catch(function() { return controller.signal.aborted
                      ? "error(rpc_error(http_timeout))." : "error(rpc_error(fetch_failed))."; })
                    .finally(function() { if (timer !== null) clearTimeout(timer); });
                } catch (error) { if (timer !== null) clearTimeout(timer); controller.abort(); throw error; }
                return {promise:promise, cancel:function() {
                  if (timer !== null) clearTimeout(timer);
                  controller.abort();
                }};
              });
            };
            window.swiPromiseWait = function(ref, token, timeout) { return window._swiPromiseStore.wait(String(ref),String(token),Number(timeout)); };
            window.swiPromiseClaim = function(ref) { return window._swiPromiseStore.claim(String(ref)); };
            window.swiPromiseCommit = function(ref, token) { return window._swiPromiseStore.commit(String(ref),String(token)); };
            window.swiPromiseRelease = function(ref, token) { return window._swiPromiseStore.release(String(ref),String(token)); };
            window.swiPromiseCleanup = function(ref) { return window._swiPromiseStore.dispose(String(ref)); };
            window.swiAbortPromiseWaits = function() { return window._swiPromiseStore.interruptCollectors(); };
            return this.loadSwiWasmEngineBundle().then(function() {
              self.swiWasmOutputBuffer = "";
              return SWIPL({
                arguments: ["-q", "--nosignals"],
                on_output: function(text, stream) {
                  // Long-running queries and statecharts stream output while
                  // their runner is active.  Appending it to a buffer first
                  // lets a fast remote paging loop reach a rate-limit error
                  // before a timer has a chance to repaint it.
                  if (self._swiWasmOutputTimer) {
                    self.emitSwiWasmOutput(String(text).replace(/\n$/, ""));
                  } else {
                    self.swiWasmOutputBuffer += text;
                  }
                }
              }).then(function(Module) {
                var Prolog = Module.prolog;
                self.swiWasmProlog = Prolog;
                self.swiWasmModule = Module;
                // Bypass the JS-level innermost-query check. Certain Prolog library
                // loading paths leave ghost entries in the JS open_queries array
                // without a matching C-level open query. Patching the check is safe
                // because the C query stack remains correct.
                //
                // The check lives on the Engine class (exposed as prolog.Engine),
                // not on the Prolog instance or on the Query. We must patch:
                //   1. Prolog.Engine.prototype.__pop_query  (removes the check entirely)
                //   2. prolog.main_engine directly          (the already-created instance)
                var _noopInnermost = function(q) {};
                var _safePopQuery = function(q) {
                  // Remove q from open_queries without enforcing LIFO order.
                  var idx = this.open_queries.lastIndexOf(q);
                  if (idx !== -1) this.open_queries.splice(idx, 1);
                  if (this.auto_close && this.open_queries.length === 0) this.close();
                };
                // Patch Engine prototype.
                try {
                  if (typeof Prolog.Engine === "function") {
                    Prolog.Engine.prototype.__must_be_innermost_query = _noopInnermost;
                    Prolog.Engine.prototype.__pop_query = _safePopQuery;
                  }
                } catch(e) {}
                // Patch the already-created main engine instance.
                try {
                  if (Prolog.main_engine) {
                    Prolog.main_engine.__must_be_innermost_query = _noopInnermost;
                    Prolog.main_engine.__pop_query = _safePopQuery;
                  }
                } catch(e) {}
                // Wrap Prolog.query so every future query instance is patched.
                var _origPrologQuery = Prolog.query.bind(Prolog);
                Prolog.query = function(goal, bindings) {
                  var q = _origPrologQuery(goal, bindings);
                  if (q) q.__must_be_innermost_query = _noopInnermost;
                  return q;
                };
                // Pre-load library(wasm/lists/apply) so := and # operators are
                // available before any user code is compiled.
                try { Prolog.query("use_module(library(wasm))").once(); } catch(e) {
                  console.warn("[SWI-INIT] library(wasm) preload threw:", e);
                }
                try { Prolog.query("use_module(library(lists))").once(); } catch(e) {}
                try { Prolog.query("use_module(library(apply))").once(); } catch(e) {}
                try { Prolog.query("use_module(library(option))").once(); } catch(e) {}
                var sharedDatabaseReady = self.installSwiWasmSharedDatabase(Prolog, Module);
                // DOM access is the reason this compatibility model exists;
                // preload the module rather than requiring every program to.
                var _domOk = false;
                try { _domOk = !!Prolog.query("use_module(library(dom))").once(); } catch(e) {
                  console.warn("[SWI-INIT] library(dom) preload threw:", e);
                }
                if (!_domOk) self.emitSwiWasmOutput("% Warning: library(dom) could not be loaded.");
                // `limit/2` puts a hard ceiling on terminal enumeration.
                // Without it, a query such as rpc(..., phrase(s(_), S),
                // [limit(10)]) has infinitely many answers and repeatedly
                // fetches remote pages until the remote rate limit intervenes.
                try { Prolog.query("use_module(library(solution_sequences))").once(); } catch(e) {}
                var _sgmlOk = false;
                try { _sgmlOk = !!Prolog.query("use_module(library(sgml))").once(); } catch(e) {}
                console.log("[SWI-INIT] library(sgml) available:", _sgmlOk);
                // Verify := works — show a visible warning in the terminal if not
                self.swiWasmOutputBuffer = "";
                var _wasmOk = false;
                try {
                  var _opCheck = Prolog.query("current_op(990,xfx,:=)").once();
                  _wasmOk = !!_opCheck;
                } catch(e) {}
                console.log("[SWI-INIT] library(wasm) := available:", _wasmOk);
                return sharedDatabaseReady.then(function() {
                  // The SWI-WASM Prolog session is ready for ordinary
                  // queries now — resume the terminal immediately rather
                  // than waiting on the statechart preload below.
                  self.swiWasmHostEvent("ready", {});
                  self.log("info", "SWI-Prolog WASM runtime ready.", "swi-wasm");

                  // Lazy-load the statechart WASM modules in the
                  // background so the editor's Run button can drive
                  // charts via statechart_start/1.  Failure is non-fatal
                  // — the SWI-WASM Prolog session remains usable for
                  // ordinary queries.
                  self.preloadSwiWasmStatechart(Prolog, Module).then(function(ok) {
                    console.log("[SWI-INIT] statechart_wasm loaded:", ok);
                  });
                });
              });
            }).catch(function(err) {
              self.swiWasmHostEvent("error", {error:String(err)});
              throw err;
            });
          },
          installSwiWasmActorBridge: function() {
            var self = this;
            window.swiWasmActorSpawn = function(goalText, extraSourceText) {
              return self.spawnSwiWasmWorkerActorReady(goalText, extraSourceText);
            };
            window.swiWasmActorReservePid = function() {
              return self.reserveSwiWasmWorkerActorPid("main");
            };
            window.swiWasmNameToken = function() { return "name-" + (self.swiWasmNextName = (self.swiWasmNextName || 0) + 1); };
            window.swiWasmNameReserve = function(token, name) { return Promise.resolve(self.reserveSwiWasmName("main", token, name)); };
            window.swiWasmNamePublish = function(token, name, pid, live) { return Promise.resolve(self.publishSwiWasmName("main", token, name, pid, live)); };
            window.swiWasmNamedChartStarted = function(live) { self.startSwiWasmLocalChart(live === true || live === "true"); return true; };
            window.swiWasmNamedChartStopped = function() { self.stopSwiWasmLocalChart("true"); return true; };
            window.swiWasmSyncChartStatus = function(live) {
              if (live === true || live === "true") {
                if (!self.swiWasmStatechartActive) self.startSwiWasmLocalChart(true);
              } else self.stopSwiWasmLocalChart("true");
              return true;
            };
            window.swiWasmNameCommit = function(token, name) { return self.commitSwiWasmName("main", token, name); };
            window.swiWasmNameRelease = function(token, name) { return self.releaseSwiWasmName("main", token, name); };
            window.swiWasmStartupErrorText = function(error) { return String(error && error.message || error); };
            window.swiWasmStartupOpen = function() {
              var token = "startup-" + (self.swiWasmNextStartup = (self.swiWasmNextStartup || 0) + 1);
              self.openSwiWasmStartup("main", token);
              return token;
            };
            window.swiWasmStartupFinish = function(token, committed) {
              return self.finishSwiWasmStartup("main", token, committed === true || String(committed) === "true");
            };
            window.swiWasmWorkerScopeOpen = function() {
              var token = "scope-" + (self.swiWasmNextWorkerScope = (self.swiWasmNextWorkerScope || 0) + 1);
              self.openSwiWasmWorkerScope("main", token);
              return token;
            };
            window.swiWasmWorkerScopeReserve = function(token) {
              return Promise.resolve(self.reserveSwiWasmScopedWorker("main", token));
            };
            window.swiWasmWorkerScopeSpawn = function(token, pid, goal) {
              return self.spawnSwiWasmScopedWorker("main", token, pid, goal);
            };
            window.swiWasmWorkerScopeRelease = function(token, pid) {
              self.releaseSwiWasmScopedWorker("main", token, pid);
              return true;
            };
            window.swiWasmWorkerScopeClose = function(token) {
              try { self.closeSwiWasmWorkerScope("main", token); return Promise.resolve(true); }
              catch (_) { return Promise.resolve(false); }
            };
            window.swiWasmActorSpawnWithPid = function(pidText, goalText, extraSourceText, nameText, linkText) {
              return self.spawnSwiWasmWorkerActorReady(
                goalText,
                extraSourceText,
                pidText,
                nameText,
                "actor",
                {
                  parentPid: "main",
                  linked: String(linkText === undefined ? "true" : linkText) !== "false"
                }
              );
            };
            window.swiWasmStatechartSpawnWorker = function(sourceKind, sourceText, supportSourceText,
                                                            nameText, linkText,
                                                            ioTargetText, traceText) {
              return self.spawnSwiWasmStatechartActor(
                sourceKind, sourceText, "statechart", nameText,
                String(linkText === undefined ? "true" : linkText) !== "false",
                supportSourceText, ioTargetText,
                String(traceText === undefined ? "true" : traceText) !== "false", "main"
              ).then(function(pid) {
                return "statechart_spawn_ok(" + JSON.stringify(String(pid)) + ")";
              }, function(error) {
                var message = error && error.message ? error.message : String(error || "statechart startup failed");
                return "statechart_spawn_error(" + JSON.stringify(message) + ")";
              });
            };
            window.swiWasmActorSend = function(pidText, messageText) {
              var from = self.swiWasmStatechartOwnsActorTraffic() ? "statechart" : "main";
              return Promise.resolve(self.sendSwiWasmActorMessage(pidText, messageText, from));
            };
            window.swiWasmActorRemoteSpawn = function(nodeText, goalText, sourceText) {
              return self.spawnSwiWasmRemoteActor(nodeText, goalText, sourceText, "main");
            };
            window.swiWasmLoadUriSource = function(uriText) {
              return self.loadSwiWasmUriSource(uriText);
            };
            window.swiWasmRemoteToplevelSpawn = function(nodeText, sourceText, sessionText,
                                                         timeLimitText, idleLimitText) {
              return self.spawnSwiWasmRemoteToplevel(
                nodeText, sourceText, sessionText, "", timeLimitText, idleLimitText, "main"
              );
            };
            window.swiWasmToplevelCorrelation = function(nodeText) {
              return self.ensureSwiWasmRemoteActorConnection(nodeText).then(function(entry) {
                return entry.socket.protocol === "web-prolog-sync-v1";
              });
            };
            window.swiWasmSynchronousSend = function(pidText, messageText) {
              return Promise.resolve(self.sendSwiWasmActorMessage(pidText, messageText, "main", true));
            };
            window.swiWasmRemoteToplevelCall = function(pidText, goalText, templateText, limit, offset, once) {
              return self.callSwiWasmRemoteToplevel(pidText, goalText, templateText, limit, offset, once);
            };
            window.swiWasmRemoteToplevelNext = function(pidText, limit) {
              return self.nextSwiWasmRemoteToplevel(pidText, limit);
            };
            window.swiWasmActorSendDelayed = function(pidText, messageText, delaySeconds, idText) {
              return self.sendSwiWasmActorMessageDelayed(pidText, messageText, delaySeconds, idText);
            };
            window.swiWasmActorCancel = function(idText) {
              return self.cancelSwiWasmActorMessage(idText);
            };
            window.swiWasmActorReceive = function(timeoutSeconds) {
              return self.receiveSwiWasmActorMessage(timeoutSeconds);
            };
            window.swiWasmActorMakeRef = function() {
              return self.reserveSwiWasmActorRef();
            };
            window.swiWasmActorActors = function() {
              return self.swiWasmActorListText();
            };
            window.swiWasmActorRegister = function(kind, nameText, pidText) {
              return self.registerSwiWasmActorName(kind, nameText, pidText);
            };
            window.swiWasmActorUnregister = function(kind, nameText) {
              return self.unregisterSwiWasmActorName(kind, nameText);
            };
            window.swiWasmActorWhereis = function(kind, nameText) {
              return self.whereisSwiWasmActorName(kind, nameText);
            };
            window.swiWasmActorMonitor = function(pidText, refText) {
              return Promise.resolve(self.monitorSwiWasmActor("main", pidText, refText));
            };
            window.swiWasmActorDemonitor = function(refText) {
              return Promise.resolve(self.demonitorSwiWasmActor("main", refText));
            };
            window.swiWasmServerMonitorCleanup = function(refText) {
              self.cleanupSwiWasmServerMonitor("main", refText);
              return true;
            };
            //  Chart-watcher variants: a chart's monitor/2 records `statechart`
            //  as the watcher (not `main`), so a monitored child's down event
            //  routes back into the running chart (see sendSwiWasmActorMessage).
            window.swiWasmStatechartMonitor = function(pidText, refText) {
              return Promise.resolve(self.monitorSwiWasmActor("statechart", pidText, refText));
            };
            window.swiWasmStatechartDemonitor = function(refText) {
              return Promise.resolve(self.demonitorSwiWasmActor("statechart", refText));
            };
            window.swiWasmActorExit = function(pidText, reasonText) {
              return Promise.resolve(self.exitSwiWasmActor(pidText, reasonText));
            };
            window.swiWasmActorAbort = function(pidText) {
              return self.abortSwiWasmActor(pidText);
            };
            window.swiWasmActorTerminalOutput = function(text) {
              self.emitSwiWasmOutput(String(text), undefined, "terminal");
              return true;
            };
            window.swiWasmBehaviourSource = function() {
              return self.swiWasmBehaviourProlog();
            };
            window.swiWasmActorInput = function(promptText) {
              return self.requestSwiWasmActorInput(String(promptText || ""));
            };
            //  Lazy solution paging (see swi_wasm_drive/1 in the bridge).
            //  swiWasmNoteDet records whether the just-found solution left a
            //  choicepoint, so the forEach callback can print '.' (deterministic
            //  last) or ' ; ' (more may follow).  swiWasmAwaitMore parks the
            //  driver between solutions; nextSwiWasmSolution resolves it on ';'
            //  and stopPaging/abort reject it to unwind the suspended search.
            // Keep the original exception before the WASM query API reduces it
            // to message_to_string/2. The terminal applies its display setting.
            window.swiWasmNoteException = function(text) {
              self.swiWasmQueryException = String(text);
              return true;
            };
            window.swiWasmNoteDet = function(detText) {
              self.swiWasmLastDet = String(detText) === "true" ? "true" : "false";
              return true;
            };
            window.swiWasmAwaitMore = function() {
              return new Promise(function(resolve, reject) {
                //  If the user already pressed ';' before the driver parked
                //  (a sub-heartbeat race), honour it immediately; otherwise
                //  park until nextSwiWasmSolution / stopPaging / abort acts.
                if (self.swiWasmMoreRequested) {
                  self.swiWasmMoreRequested = false;
                  resolve("more");
                  return;
                }
                self.swiWasmMorePending = { resolve: resolve, reject: reject };
              });
            };
          },
          randomSwiIdentity: function() {
            var root = typeof globalThis !== "undefined" ? globalThis : window;
            if (!root.crypto || typeof root.crypto.getRandomValues !== "function") {
              throw new Error("Secure randomness is required for actor identities");
            }
            var value;
            do {
              var values = new Uint8Array(5);
              root.crypto.getRandomValues(values);
              value = 0;
              for (var i = 0; i < values.length; i++) {
                value = value * 256 + values[i];
              }
            } while (value >= 1098000000000);
            return String(1000000000 + (value % 9000000000));
          },
          reserveSwiWasmWorkerActorPid: function(owner) {
            var pid;
            this.swiWasmIssuedIdentities = this.swiWasmIssuedIdentities || {};
            do { pid = this.randomSwiIdentity(); }
            while (this.swiWasmIssuedIdentities[pid]);
            this.swiWasmIssuedIdentities[pid] = true;
            this.swiWasmReservedWorkerActorPids[pid] = true;
            if (owner !== undefined) this.trackSwiWasmStartup(owner, pid);
            return pid;
          },
          reserveSwiWasmActorRef: function() {
            var ref;
            this.swiWasmIssuedIdentities = this.swiWasmIssuedIdentities || {};
            do { ref = this.randomSwiIdentity(); }
            while (this.swiWasmIssuedIdentities[ref]);
            this.swiWasmIssuedIdentities[ref] = true;
            this.swiWasmReservedActorRefs[ref] = true;
            return ref;
          },
          openSwiWasmStartup: function(owner, token) {
            this.swiWasmStartups = this.swiWasmStartups || Object.create(null);
            var key = JSON.stringify([String(owner), String(token)]);
            if (this.swiWasmStartups[key]) throw new Error("startup already open");
            this.swiWasmStartups[key] = {owner:String(owner), pids:new Set(), monitors:[], finished:false, aborted:false};
          },
          trackSwiWasmStartup: function(owner, pid, ref) {
            // Follow creation ancestry, including detached children. An outer
            // attempt still owns a nested supervisor's starts until it commits.
            var ancestors = new Set(), current = String(owner || "");
            while (current && !ancestors.has(current)) {
              ancestors.add(current);
              var entry = this.swiWasmActorWorkers[current];
              current = entry ? String(entry.parentPid || "") : "";
            }
            Object.keys(this.swiWasmStartups || {}).forEach(function(key) {
              var scope = this.swiWasmStartups[key];
              if (!ancestors.has(scope.owner)) return;
              if (ref === undefined) scope.pids.add(String(pid));
              else scope.monitors.push({watcher:String(owner), ref:String(ref)});
            }.bind(this));
          },
          finishSwiWasmStartup: function(owner, token, committed) {
            var key = JSON.stringify([String(owner), String(token)]);
            var scope = (this.swiWasmStartups || {})[key];
            if (!scope) return true;
            delete this.swiWasmStartups[key]; // Retire before any recursive cleanup.
            scope.finished = true; scope.aborted = !committed;
            if (!committed) Object.values(this.swiWasmRemoteActorConnections || {}).forEach(function(entry) {
              entry.pendingSpawns.forEach(function(op) {
                if ((op.scopes || []).indexOf(scope) >= 0) {
                  op.cancelled = true; op.reject(new Error("remote named startup cancelled"));
                }
              });
            });
            if (committed) return true;
            var retired = Object.create(null);
            scope.monitors.forEach(function(m) {
              try { Promise.resolve(this.demonitorSwiWasmActor(m.watcher, m.ref)).catch(function() {}); } catch (_) {}
              (retired[m.watcher] || (retired[m.watcher] = [])).push(m.ref);
            }.bind(this));
            Object.keys(retired).forEach(function(watcher) {
              try { this.sendSwiWasmActorMessage(watcher, "'$startup_retire'([" + retired[watcher].join(",") + "])"); } catch (_) {}
            }.bind(this));
            Array.from(scope.pids).reverse().forEach(function(pid) {
              this.swiWasmReservedWorkerActorPids[pid] = false; // Reject late startup of a rolled-back reservation.
              var entry = this.swiWasmActorWorkers[pid];
              if (entry && entry.rejectReady) {
                entry.rejectReady(new Error("supervisor startup rolled back"));
                entry.resolveReady = null; entry.rejectReady = null;
              }
              try { Promise.resolve(this.exitSwiWasmActor(pid, "kill")).catch(function() {}); } catch (_) {}
              if (entry && entry.worker) { try { entry.worker.terminate(); } catch (_) {} }
            }.bind(this));
            return true;
          },
          reserveSwiWasmName: function(owner, token, name) {
            this.swiWasmNameReservations = this.swiWasmNameReservations || Object.create(null);
            var registry = this.swiWasmActorNames, reservations = this.swiWasmNameReservations;
            name = String(name); owner = String(owner); token = String(token);
            if (!this.swiWasmActorPidLive(owner)) return "missing";
            if (Object.prototype.hasOwnProperty.call(registry, name) || reservations[name]) return "collision";
            this.openSwiWasmStartup(owner, token);
            reservations[name] = {owner:owner, token:token};
            return "reserved";
          },
          publishSwiWasmName: function(owner, token, name, pidText, chartLive) {
            name = String(name);
            var reservation = (this.swiWasmNameReservations || {})[name];
            if (!reservation || reservation.owner !== String(owner) || reservation.token !== String(token)) return "missing";
            if (reservation.remoteFailure) return reservation.remoteFailure;
            var pid = this.resolveSwiWasmActorTarget(pidText), entry = this.swiWasmActorWorkers[pid];
            var registry = this.swiWasmActorNames;
            if (Object.keys(registry).some(function(key) { return registry[key] === pid && key !== name; }) ||
                Object.keys(this.swiWasmNameReservations).some(function(key) { return key !== name && this.swiWasmNameReservations[key].pid === pid; }.bind(this))) return "collision";
            // Normal early termination still succeeds as a spawn, but must not
            // publish a dead actor or interfere with its down notification.
            var isChart = pid === "statechart" && String(owner) === "main";
            var live = isChart ? chartLive !== false && String(chartLive) !== "false" : this.swiWasmActorPidLive(pid);
            if (!live) {
              if (!isChart && (!entry || !entry.done)) return "missing";
            } else {
              if (Object.prototype.hasOwnProperty.call(registry, name)) return "collision";
            }
            // Keep rollback ownership until Prolog has resumed after this reply.
            // No alias is visible during that interruptible wait.
            reservation.pid = pid; reservation.chartLive = live;
            return "published";
          },
          commitSwiWasmName: function(owner, token, name) {
            name = String(name);
            var r = (this.swiWasmNameReservations || {})[name];
            if (!r || r.owner !== String(owner) || r.token !== String(token) || r.pid === undefined) return false;
            if (r.remoteFailure) return r.remoteFailure;
            var isChart = r.pid === "statechart" && String(owner) === "main";
            var live = isChart ? r.chartLive : this.swiWasmActorPidLive(r.pid);
            if (isChart) this.swiWasmStatechartActive = live;
            if (live) Object.defineProperty(this.swiWasmActorNames, name, {value:r.pid, configurable:true, writable:true, enumerable:true});
            this.finishSwiWasmStartup(owner, token, true);
            delete this.swiWasmNameReservations[name];
            return true;
          },
          releaseSwiWasmName: function(owner, token, name) {
            var reservation = (this.swiWasmNameReservations || {})[String(name)];
            if (!reservation || reservation.owner !== String(owner) || reservation.token !== String(token)) return true;
            // Keep the name occupied until rollback has withdrawn actors.
            this.finishSwiWasmStartup(owner, token, false);
            delete this.swiWasmNameReservations[String(name)];
            return true;
          },
          releaseSwiWasmNamesForOwner: function(owner) {
            Object.keys(this.swiWasmNameReservations || {}).forEach(function(name) {
              var r = this.swiWasmNameReservations[name];
              if (r.owner === String(owner)) this.releaseSwiWasmName(owner, r.token, name);
            }.bind(this));
          },
          swiWasmWorkerScopeKey: function(watcher, token) {
            return JSON.stringify([String(watcher), String(token)]);
          },
          openSwiWasmWorkerScope: function(watcher, token) {
            this.swiWasmWorkerScopes = this.swiWasmWorkerScopes || Object.create(null);
            var key = this.swiWasmWorkerScopeKey(watcher, token);
            if (this.swiWasmWorkerScopes[key]) throw new Error("worker scope already exists");
            this.swiWasmWorkerScopes[key] = { watcher: String(watcher), token: String(token), pids: new Set(), started: new Set(), closed: false };
          },
          reserveSwiWasmScopedWorker: function(watcher, token) {
            var scope = (this.swiWasmWorkerScopes || {})[this.swiWasmWorkerScopeKey(watcher, token)];
            if (!scope || scope.closed) throw new Error("worker scope is closed");
            var pid = this.reserveSwiWasmWorkerActorPid();
            scope.pids.add(String(pid));
            return pid;
          },
          spawnSwiWasmScopedWorker: function(watcher, token, pidText, goal) {
            var pid = String(pidText);
            var scope = (this.swiWasmWorkerScopes || {})[this.swiWasmWorkerScopeKey(watcher, token)];
            if (!scope || scope.closed || !scope.pids.has(pid) || scope.started.has(pid)) {
              throw new Error("invalid scoped worker reservation");
            }
            // Ownership precedes Worker construction and the readiness wait.
            scope.started.add(pid);
            return this.spawnSwiWasmWorkerActorReady(goal, "", pid, "", "actor",
              { parentPid: String(watcher), linked: true }).then(function() {
                if (scope.closed) throw new Error("worker scope is closed");
                this.monitorSwiWasmActor(watcher, pid, qualifySwiWasmLocalPid(pid));
                return pid;
              }.bind(this));
          },
          releaseSwiWasmScopedWorker: function(watcher, token, pidText) {
            var scope = (this.swiWasmWorkerScopes || {})[this.swiWasmWorkerScopeKey(watcher, token)];
            if (scope) { var pid = this.resolveSwiWasmActorTarget(pidText); scope.pids.delete(String(pid)); scope.started.delete(String(pid)); }
          },
          closeSwiWasmWorkerScopes: function(watcher) {
            var resumedStartup = false;
            Object.keys(this.swiWasmWorkerScopes || {}).forEach(function(key) {
              var scope = this.swiWasmWorkerScopes[key];
              if (!scope || scope.watcher !== String(watcher)) return;
              scope.started.forEach(function(pid) {
                var entry = this.swiWasmActorWorkers[pid];
                if (entry && entry.rejectReady) resumedStartup = true;
              }.bind(this));
              this.closeSwiWasmWorkerScope(watcher, scope.token);
            }.bind(this));
            return resumedStartup;
          },
          closeSwiWasmWorkerScope: function(watcher, token) {
            var key = this.swiWasmWorkerScopeKey(watcher, token);
            var scope = (this.swiWasmWorkerScopes || {})[key];
            if (!scope) return;
            if (scope) {
              scope.closed = true;
              // Delete admission first. Late startup cannot install a monitor
              // or recreate a worker after the scope has been closed.
              delete this.swiWasmWorkerScopes[key];
              scope.pids.forEach(function(pid) {
                delete this.swiWasmReservedWorkerActorPids[pid];
                try { Promise.resolve(this.demonitorSwiWasmActor(watcher, qualifySwiWasmLocalPid(pid))).catch(function() {}); } catch (_) {}
                if (!scope.started.has(pid)) return;
                var entry = this.swiWasmActorWorkers[pid];
                if (entry && entry.rejectReady) {
                  entry.rejectReady(new Error("worker scope is closed"));
                  entry.resolveReady = null; entry.rejectReady = null;
                }
                try { this.exitSwiWasmActor(pid, "kill"); } catch (_) {}
                // Even failed notification/postMessage must not retain the local Worker.
                if (entry && entry.worker) { try { entry.worker.terminate(); } catch (_) {} }
              }.bind(this));
            }
            // Same channel as worker results/down: preceding messages can be
            // discarded before this barrier retires the temporary filters.
            this.sendSwiWasmActorMessage(watcher, "'$worker_scope_closed'('" + String(token).replace(/'/g, "''") + "')");
          },
          spawnSwiWasmWorkerActor: function(goalText, extraSourceText, pidText, nameText, roleText, startFields) {
            var self = this;
            var pid = pidText ? String(pidText) : this.reserveSwiWasmWorkerActorPid();
            var worker;
            var entry;
            if (this.swiWasmReservedWorkerActorPids[pid] === false) throw new Error("supervisor startup rolled back");
            if (this.swiWasmActorWorkers[pid]) {
              throw new Error("worker actor already exists: " + pid);
            }
            delete this.swiWasmReservedWorkerActorPids[pid];
            if (startFields && startFields.parentPid && this.trackSwiWasmStartup) this.trackSwiWasmStartup(startFields.parentPid, pid);
            if (nameText) throw new Error("named Worker creation requires a reservation");
            var workerUrl = this.swiWasmAssets ? this.swiWasmAssets.workerUrl : "/swi_wasm_actor_worker.js?v=20261018-answer-terms-v27";
            try {
              worker = new Worker(workerUrl, { name: pid });
            } catch (_error) {
              worker = new Worker(workerUrl);
            }
            entry = {
              pid: pid,
              worker: worker,
              ready: false,
              done: false,
              reason: null,
              goal: String(goalText || ""),
              role: String(roleText || "actor"),
              shellCandidate: !!(startFields && startFields.shellCandidate),
              shellRetired: false,
              retireTimer: null,
              parentPid: startFields && startFields.parentPid
                ? String(startFields.parentPid)
                : "",
              linked: !(startFields && startFields.linked === false),
              readyPromise: null,
              resolveReady: null,
              rejectReady: null
            };
            entry.readyPromise = new Promise(function(resolve, reject) {
              entry.resolveReady = resolve;
              entry.rejectReady = reject;
            });
            entry.readyPromise.catch(function() {});
            this.swiWasmActorWorkers[pid] = entry;
            worker.onmessage = this.handleSwiWasmWorkerActorMessage.bind(this, pid);
            worker.onerror = function(error) {
              var message = error && error.message ? error.message : String(error);
              self.log("error", pid + " worker error: " + message, "swi-wasm");
              //  An uncaught worker error (e.g. importScripts failing before
              //  the worker's own handler runs) never posts {type:error}, so
              //  finalize here: notify monitors (down/3), clear names, reap.
              if (entry.rejectReady) {
                entry.rejectReady(new Error("worker_error: " + message));
                entry.resolveReady = null;
                entry.rejectReady = null;
              }
              self.finalizeSwiWasmWorkerActor(pid, "error(" + JSON.stringify("worker_error: " + message) + ")");
            };
            if (entry.role === "shell_toplevel") {
              var spawnEnvelope = {
                command: "toplevel_spawn",
                pid: Number(pid),
                options: this.toplevelSpawnOptionsText(extraSourceText, true)
              };
              // Worker boot code is an implementation detail, transferred
              // separately so the API message itself is the same envelope
              // that the Logger displays.
              worker.postMessage({
                command: "configure",
                assets: this.swiWasmAssets,
                goal: entry.goal,
                behaviourSource: this.swiWasmBehaviourProlog(),
                role: entry.role
              });
              this.logSwiWasmWorkerTraffic(spawnEnvelope, "request");
              worker.postMessage(spawnEnvelope);
            } else {
              worker.postMessage(Object.assign({
                command: "start",
                assets: this.swiWasmAssets,
                pid: pid,
                goal: entry.goal,
                // Actor code crosses the worker boundary only through explicit
                // src_* spawn options collected into extraSourceText.
                source: String(extraSourceText || ""),
                behaviourSource: this.swiWasmBehaviourProlog(),
                role: entry.role
              }, startFields || {}));
              this.log("transport", "spawn " + pid + " using SWI-WASM WebWorker.", "swi-wasm", "request");
            }
            return pid;
          },
          spawnSwiWasmWorkerActorReady: function(goalText, extraSourceText, pidText, nameText, roleText, startFields) {
            var pid = this.spawnSwiWasmWorkerActor(goalText, extraSourceText, pidText, nameText, roleText, startFields);
            var entry = this.swiWasmActorWorkers[pid];
            if (!entry) {
              return Promise.resolve(pid);
            }
            if (entry.ready) {
              return Promise.resolve(pid);
            }
            return entry.readyPromise.then(function() {
              return pid;
            });
          },
          swiWasmRemoteNodeUrl: function(nodeText) {
            var node = String(nodeText || "");
            var quoted = /^'([\s\S]*)'$/.exec(node);
            if (quoted) {
              node = quoted[1].replace(/''/g, "'");
            }
            var markdown = /^\[(https?:\/\/[^\]]+)\]\((https?:\/\/[^)]+)\)$/.exec(node);
            if (markdown) {
              return markdown[2];
            }
            return node;
          },
          loadSwiWasmUriSource: function(uriText) {
            var uri = resolveBrowserRpcLoadUri(uriText);
            var url = new URL(uri, window.location.origin);
            var allowedOrigins = [
              "https://n0.elfenbenstornet.se", "https://n1.elfenbenstornet.se",
              "https://n2.elfenbenstornet.se", "https://n3.elfenbenstornet.se",
              "https://n4.elfenbenstornet.se", "https://n5.elfenbenstornet.se"
            ];
            if (allowedOrigins.indexOf(url.origin) < 0) {
              return Promise.reject(new Error("src_uri origin is not allowed in SWI-WASM: " + url.origin));
            }
            return fetch(url.href, { credentials: "same-origin" }).then(function(response) {
              if (!response.ok) throw new Error("src_uri failed: HTTP " + response.status);
              return response.text();
            });
          },
          loadSwiWasmAssetSource: function(uriText) {
            var uri = this.swiWasmRemoteNodeUrl(uriText);
            var url = new URL(uri, window.location.origin);
            if (url.origin !== window.location.origin) {
              return Promise.reject(new Error("statechart src_uri must use this browser node: " + url.origin));
            }
            return fetch(url.href, { credentials: "same-origin", cache: "no-store" }).then(function(response) {
              if (!response.ok) throw new Error("statechart src_uri failed: HTTP " + response.status);
              return response.text();
            });
          },
          spawnSwiWasmStatechartActor: function(sourceKind, sourceText, parentPid,
                                                nameText, linked, supportSourceText,
                                                ioTargetText, traceEnabled, startupOwner) {
            var self = this;
            var parent = String(parentPid || (this.isSwiWasm2Mode ? this.swiWasm2ShellPid : "main"));
            var parentEntry = this.swiWasmActorWorkers[parent];
            var inheritedIoTarget = String(ioTargetText || "");
            // output/1 defaults to the parent actor.  A nested statechart
            // therefore inherits its owning chart as I/O target, while a
            // chart spawned directly by the shell keeps direct terminal I/O.
            if (!inheritedIoTarget &&
                (parent === "statechart" ||
                 (parentEntry && parentEntry.role === "statechart_actor"))) {
              inheritedIoTarget = parent;
            }
            var sourcePromise = String(sourceKind) === "text"
              ? Promise.resolve(String(sourceText || ""))
              : this.loadSwiWasmAssetSource(sourceText);
            return sourcePromise.then(function(xml) {
              var candidate = self.reserveSwiWasmWorkerActorPid(startupOwner || parent);
              return self.spawnSwiWasmWorkerActorReady(
                "statechart_actor_loop", " ", candidate, String(nameText || ""), "statechart_actor",
                {
                  statechartXml: xml,
                  statechartSupportSource: String(supportSourceText || ""),
                  statechartTrace: traceEnabled !== false,
                  ioTarget: inheritedIoTarget,
                  parentPid: parent,
                  linked: linked !== false
                }
              );
            });
          },
          disposeSwiWasmPromiseRequest: function(pid, ref) {
            var entry = this.swiWasmActorWorkers[pid];
            var requests = entry && entry.promiseRequests;
            if (!requests) return;
            var refs = ref === undefined ? Object.keys(requests) : [String(ref)];
            refs.forEach(function(key) {
              var resource = requests[key];
              if (!resource) return;
              delete requests[key];
              if (resource.timer !== null) clearTimeout(resource.timer);
              resource.controller.abort();
            });
          },
          requestSwiWasmWorkerRpc: function(message, ownerPid) {
            var node = resolveBrowserRpcBaseUri(message.node || "");
            var url = new URL(node, window.location.origin);
            var path = url.pathname.replace(/\/$/, "");
            url.pathname = path + "/call";
            url.search = "";
            url.hash = "";
            url.searchParams.set("goal", "(" + String(message.goal || "true") + ")");
            url.searchParams.set("template", String(message.template || "true"));
            url.searchParams.set("format", "prolog");
            url.searchParams.set("offset", String(Number(message.offset || 0)));
            if (message.limit !== undefined && message.limit !== null) {
              url.searchParams.set("limit", String(Number(message.limit)));
            }
            if (message.loadText) {
              url.searchParams.set("src_text", String(message.loadText));
            }
            var remoteTimeout = Number(message.remoteTimeout);
            if (isFinite(remoteTimeout) && remoteTimeout >= 0) {
              url.searchParams.set("timeout", String(remoteTimeout));
            }
            if (message.once === true) {
              url.searchParams.set("once", "true");
            }
            var controller = new AbortController();
            var owner = this.swiWasmActorWorkers && this.swiWasmActorWorkers[ownerPid];
            var ref = message.promise_ref ? String(message.promise_ref) : null;
            if (ref && owner && owner.done) return Promise.reject(new Error("promise Worker has stopped"));
            var resource = {controller:controller, timer:null};
            if (ref && owner) {
              owner.promiseRequests = owner.promiseRequests || Object.create(null);
              owner.promiseRequests[ref] = resource;
            }
            var httpTimeout = message.httpTimeout === null || message.httpTimeout === undefined
              ? NaN
              : Number(message.httpTimeout);
            var timer = isFinite(httpTimeout) && httpTimeout >= 0
              ? setTimeout(function() { controller.abort(); }, httpTimeout * 1000)
              : null;
            resource.timer = timer;
            return Promise.resolve().then(function() {
              if (controller.signal.aborted) throw new Error("promise request disposed");
              return fetch(url.href, {
              credentials: "same-origin",
              signal: controller.signal
            }); }).then(function(response) {
              return response.text().then(function(text) {
                if (!response.ok) {
                  var detail = String(text || "").replace(/\s+/g, " ").trim();
                  if (detail.length > 240) detail = detail.slice(0, 240) + "...";
                  throw new Error("RPC failed: HTTP " + response.status + (detail ? ": " + detail : ""));
                }
                return text;
              });
            }).catch(function(error) {
              if (controller.signal.aborted && isFinite(httpTimeout) && httpTimeout >= 0) {
                throw new Error("RPC transport timeout after " + httpTimeout + " seconds");
              }
              throw error;
            }).finally(function() {
              if (timer !== null) clearTimeout(timer);
              if (ref && owner && owner.promiseRequests[ref] === resource) delete owner.promiseRequests[ref];
            });
          },
          swiWasmRemoteWsUrl: function(nodeText) {
            var url = new URL(this.swiWasmRemoteNodeUrl(nodeText));
            url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
            url.pathname = "/ws";
            url.search = "";
            url.hash = "";
            return url.href;
          },
          parseSwiWasmRemoteActorPid: function(pidText) {
            var match = /^remote_actor\((\d+),\s*'([^']+)'\)$/.exec(String(pidText || ""));
            if (!match) match = /^(\d+)\s*@\s*'([^']+)'$/.exec(String(pidText || ""));
            if (!match) return null;
            return { pid: match[1], node: match[2] };
          },
          parseSwiWasmRemoteToplevelPid: function(pidText) {
            var match = /^(\d+)\s*@\s*'([^']+)'$/.exec(String(pidText || ""));
            if (!match) {
              // Accept pids returned by the initial experimental bridge so
              // existing terminal bindings remain usable after an upgrade.
              match = /^remote_toplevel\((\d+),\s*'([^']+)'\)$/.exec(String(pidText || ""));
            }
            if (!match) return null;
            return { pid: match[1], node: match[2] };
          },
          ensureSwiWasmRemoteActorConnection: function(nodeText) {
            var self = this;
            var node = this.swiWasmRemoteNodeUrl(nodeText);
            var existing = this.swiWasmRemoteActorConnections[node];
            if (existing && existing.socket && existing.socket.readyState === WebSocket.OPEN && existing.ioAck) {
              return Promise.resolve(existing);
            }
            if (existing && existing.connecting) {
              return existing.connecting;
            }
            var entry = existing || { pendingSpawns: [], toplevelTemplates: {}, toplevelTargets: {} };
            entry.toplevelTargets = entry.toplevelTargets || {};
            entry.ioAck = false;
            this.swiWasmRemoteActorConnections[node] = entry;
            entry.connecting = new Promise(function(resolve, reject) {
              //  Single-settlement: resolve after I/O negotiation, reject on the first of
              //  error, close-before-open, or timeout.  Without this a socket
              //  that closes without the expected error ordering left the
              //  `connecting` promise pending forever, parking every remote
              //  spawn/call/monitor awaiting it.
              var settled = false;
              var connectTimer = null;
              function clearConnectTimer() {
                if (connectTimer) { window.clearTimeout(connectTimer); connectTimer = null; }
              }
              function settleResolve(value) {
                if (settled) return;
                settled = true; clearConnectTimer(); delete entry.connecting; resolve(value);
              }
              function settleReject(error) {
                if (settled) return;
                settled = true; clearConnectTimer(); delete entry.connecting; reject(error);
              }
              connectTimer = window.setTimeout(function() {
                settleReject(new Error("remote actor connection timed out: " + node));
                try { if (entry.socket) entry.socket.close(); } catch (_timeoutClose) {}
              }, 15000);
              function openSocket(offerSync) {
              var socket, opened = false;
              function retryLegacy() {
                if (settled || opened || !offerSync) return false;
                socket.onclose = socket.onerror = null;
                try { socket.close(); } catch (_) {}
                openSocket(false);
                return true;
              }
              try {
                socket = offerSync
                  ? new WebSocket(self.swiWasmRemoteWsUrl(node), ["web-prolog-sync-v1"])
                  : new WebSocket(self.swiWasmRemoteWsUrl(node));
              } catch (error) {
                settleReject(error);
                return;
              }
              entry.socket = socket;
              socket.onopen = function() {
                opened = true;
                entry.protocol = null;
                socket.send(JSON.stringify({
                  command: "transport_hello",
                  protocol: "web_prolog_browser_actor",
                  version: 1,
                  io_ack: true,
                  browser_pids: true,
                  answer_terms: true
                }));
                self.log("transport", "SWI-WASM connected to remote actor node " + node + ".", "swi-wasm");
              };
              socket.onmessage = function(event) {
                var message;
                try { message = JSON.parse(event.data); } catch (_) { return; }
                if (message.type === "transport_welcome") {
                  if (message.protocol !== "web_prolog_browser_actor" || message.version !== 1 || message.io_ack !== true || message.browser_pids !== true) {
                    settleReject(new Error("Remote node does not support browser actor routing and acknowledged terminal I/O: " + node));
                    self.log("error", "Unsupported browser actor transport from " + node + ".", "swi-wasm");
                    socket.close();
                    return;
                  }
                  entry.protocol = message.version;
                  entry.ioAck = true;
                  entry.answerTerms = message.answer_terms === true;
                  settleResolve(entry);
                  return;
                }
                if (message.type === "io_request") {
                  self.acceptSwiWasmRemoteIo(socket, message);
                  return;
                }
                if (message.type === "spawned") {
                  var waiter = self.takeSwiWasmSpawnReply(entry,message);
                  if (waiter && !waiter.untrusted) {
                    var remotePid = String(message.pid) + "@'" + node.replace(/'/g, "''") + "'";
                    // Record acknowledgement before the caller can resume or be interrupted.
                    waiter.names.forEach(function(r) { r.remoteNode=node; r.remoteId=String(message.pid); r.remotePid=remotePid; if ((entry.namedEarlyDowns || {})[String(message.pid)]) r.remoteFailure="terminated"; });
                    if (entry.namedEarlyDowns) { delete entry.namedEarlyDowns[String(message.pid)]; if (!entry.pendingSpawns.some(function(op) { return op.named; })) entry.namedEarlyDowns={}; }
                    waiter.scopes.forEach(function(scope) { if (!scope.finished) scope.pids.add(remotePid); });
                    if (waiter.cancelled || waiter.scopes.some(function(scope) { return scope.aborted; })) {
                      try { socket.send(JSON.stringify({command:"exit",pid:message.pid,reason:"kill",request_id:self.reserveSwiWasmActorRef()})); } catch (_) {}
                      waiter.reject(new Error("remote named startup cancelled")); return;
                    }
                    self.swiWasmRemoteActorKinds[remotePid] = waiter.kind;
                    if (waiter.kind === "toplevel" && waiter.target) {
                      entry.toplevelTargets[String(message.pid)] = waiter.target;
                    }
                    waiter.resolve(remotePid);
                  }
                  return;
                }
                // Negotiate exact payloads; parse them in the receiving Prolog engine.
                // Spawn/command errors retain their existing request-id handling.
                if (entry.answerTerms && (message.type === "success" ||
                    (message.type === "error" && message.pid !== undefined && message.request_id === undefined))) {
                  var exactPid = String(message.pid) + "@'" + node.replace(/'/g, "''") + "'";
                  var exactMessage = typeof message.term === "string"
                    ? "'$remote_answer'(" + message.type + "," + exactPid + "," + JSON.stringify(message.term) + "," + (message.more === true ? "true" : "false") + ")"
                    : "error(" + exactPid + ",remote_answer_protocol_error(missing_term))";
                  self.deliverSwiWasmRemoteResult(exactMessage, entry.toplevelTargets[String(message.pid)]);
                  return;
                }
                if (message.type === "success" || message.type === "failure" || message.type === "timeout") {
                  var remotePid = String(message.pid) + "@'" + node.replace(/'/g, "''") + "'";
                  var remoteMessage;
                  if (message.type === "success") {
                    var values = (Array.isArray(message.data) ? message.data : []).map(function(value) {
                      // /ws serializes named template bindings as objects,
                      // e.g. {Who:"plato"}; receive/1 expects their Prolog
                      // values, not JavaScript's "[object Object]" string.
                      if (value && typeof value === "object") {
                        var template = entry.toplevelTemplates[String(message.pid)];
                        if (template) {
                          Object.keys(value).forEach(function(key) {
                            var escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
                            template = template.replace(new RegExp("\\b" + escaped + "\\b", "g"), String(value[key]));
                          });
                          return template;
                        }
                        var bound = Object.keys(value).map(function(key) { return String(value[key]); });
                        return bound.length === 1 ? bound[0] : "[" + bound.join(",") + "]";
                      }
                      return String(value);
                    });
                    remoteMessage = "success(" + remotePid + ",[" + values.join(",") + "]," + (message.more === true ? "true" : "false") + ")";
                  } else if (message.type === "failure") {
                    remoteMessage = "failure(" + remotePid + ")";
                  } else {
                    remoteMessage = "timeout(" + remotePid + ")";
                  }
                  self.deliverSwiWasmRemoteResult(remoteMessage, entry.toplevelTargets[String(message.pid)]);
                  return;
                }
                if (message.type === "down") {
                  self.invalidateSwiWasmRemoteNames(node,message.pid,"terminated");
                  if (entry.pendingSpawns.some(function(op) { return op.named; })) {
                    entry.namedEarlyDowns = entry.namedEarlyDowns || {}; entry.namedEarlyDowns[String(message.pid)] = true;
                  }
                  var refText = String(message.ref || "");
                  var reasonText = String(message.reason || "true");
                  var monitor = self.takeSwiWasmRemoteMonitor(node, message.pid, refText);
                  if (monitor) {
                    self.deliverSwiWasmActorDown(monitor.watcher, monitor.ref, monitor.pid, reasonText);
                  }
                  return;
                }
                if (message.type === "actor_message") {
                  self.routeSwiWasmActorMessage("remote", message.target, message.message);
                  return;
                }
                if (message.type === "error") {
                  var pending = self.takeSwiWasmSpawnReply(entry,message);
                  if (pending && !entry.pendingSpawns.some(function(op) { return op.named; })) entry.namedEarlyDowns = {};
                  if (pending && pending.untrusted) return;
                  if (pending) pending.reject(new Error(String(message.data || "remote actor error")));
                  if (!pending && message.request_id !== undefined) return;
                  if (!pending && message.pid !== undefined) {
                    var errorPid = String(message.pid) + "@'" + node.replace(/'/g, "''") + "'";
                    var errorText = String(message.data || "remote actor error").replace(/\\/g, "\\\\").replace(/'/g, "''");
                    self.deliverSwiWasmRemoteResult(
                      "error(" + errorPid + ",remote_error('" + errorText + "'))",
                      entry.toplevelTargets[String(message.pid)]
                    );
                  } else if (!pending) {
                    var generalError = String(message.data || "remote actor error").replace(/\\/g, "\\\\").replace(/'/g, "''");
                    self.deliverSwiWasmRemoteResult("error(remote_toplevel,remote_error('" + generalError + "'))");
                  }
                  self.log("error", "Remote actor node " + node + ": " + String(message.data || "error"), "swi-wasm");
                  return;
                }
                if (message.type === "output" && message.data) self.emitSwiWasmOutput(String(message.data));
              };
              socket.onclose = function() {
                if (retryLegacy()) return;
                //  Close before open settles the connect promise (no-op once
                //  opened); a mid-session close falls through to the cleanup.
                settleReject(new Error("remote actor connection closed before ready: " + node));
                self.invalidateSwiWasmRemoteNames(node,undefined,"connection_closed");
                var error = new Error("remote actor connection closed: " + node);
                while (entry.pendingSpawns.length) entry.pendingSpawns.shift().reject(error);
                var lostReason = "connection_lost('" + node.replace(/'/g, "''") + "')";
                var lostMonitors = self.swiWasmActorMonitors.filter(function(monitor) {
                  var remote = self.parseSwiWasmRemoteToplevelPid(monitor.pid) || self.parseSwiWasmRemoteActorPid(monitor.pid);
                  return remote && remote.node === node;
                });
                self.swiWasmActorMonitors = self.swiWasmActorMonitors.filter(function(monitor) {
                  var remote = self.parseSwiWasmRemoteToplevelPid(monitor.pid) || self.parseSwiWasmRemoteActorPid(monitor.pid);
                  return !remote || remote.node !== node;
                });
                lostMonitors.forEach(function(monitor) {
                  self.deliverSwiWasmActorDown(monitor.watcher, monitor.ref, monitor.pid, lostReason);
                });
                delete self.swiWasmRemoteActorConnections[node];
              };
              socket.onerror = function() {
                if (retryLegacy()) return;
                if (socket.readyState !== WebSocket.OPEN) {
                  settleReject(new Error("unable to connect to remote actor node " + node));
                }
              };
              }
              openSocket(true);
            });
            return entry.connecting;
          },
          swiWasmRemoteSpawnOperation: function(owner, kind, target, resolve, reject) {
            owner = String(owner || "");
            var ancestors = new Set(), current = owner;
            while (current && !ancestors.has(current)) {
              ancestors.add(current);
              var actor = this.swiWasmActorWorkers[current]; current = actor ? String(actor.parentPid || "") : "";
            }
            var scopes = Object.values(this.swiWasmStartups || {}).filter(function(scope) { return ancestors.has(scope.owner); });
            var names = Object.values(this.swiWasmNameReservations || {}).filter(function(r) { return r.owner === owner; });
            return {id:this.reserveSwiWasmActorRef(), kind:kind, target:String(target || ""), owner:owner,
              scopes:scopes, names:names, named:names.length > 0, resolve:resolve, reject:reject};
          },
          takeSwiWasmSpawnReply: function(entry, message) {
            var index = message.request_id === undefined ? 0 : entry.pendingSpawns.findIndex(function(op) { return op.id === String(message.request_id); });
            if (index < 0 || !entry.pendingSpawns.length) return null;
            var op = entry.pendingSpawns.splice(index,1)[0];
            if (message.request_id === undefined && op.named) {
              op.reject(new Error("remote_spawn_failed(uncorrelated_spawn_reply)"));
              if (!entry.pendingSpawns.some(function(item) { return item.named; })) entry.namedEarlyDowns = {};
              op.untrusted = true; return op; // The pid cannot safely be claimed or killed.
            }
            return op;
          },
          invalidateSwiWasmRemoteNames: function(node, pid, reason) {
            // Withdraw ordinary aliases before notifying observers. Compare the
            // current binding so a delayed down cannot erase a reused name.
            Object.keys(this.swiWasmActorNames || {}).forEach(function(name) {
              var value = String(this.swiWasmActorNames[name]);
              var remote = this.parseSwiWasmRemoteToplevelPid(value) || this.parseSwiWasmRemoteActorPid(value);
              if (remote && remote.node === node && (pid === undefined || String(remote.pid) === String(pid))) delete this.swiWasmActorNames[name];
            }.bind(this));
            Object.values(this.swiWasmNameReservations || {}).forEach(function(r) {
              if (r.remoteNode === node && (pid === undefined || r.remoteId === String(pid))) r.remoteFailure = reason;
            });
          },
          spawnSwiWasmRemoteActor: function(nodeText, goalText, sourceText, owner) {
            var self = this;
            var node = this.swiWasmRemoteNodeUrl(nodeText);
            // Remote ACTOR nodes execute their advertised predicates.  Do not
            // implicitly upload the browser editor: that would both surprise
            // users and turn an ordinary remote spawn into a source-loading
            // request subject to the public-node sandbox policy.
            var source = String(sourceText || "");
            var options = source
              ? "[src_text('" + source.replace(/\\/g, "\\\\").replace(/'/g, "''") + "')]"
              : "[]";
            return new Promise(function(resolve, reject) {
              var op = self.swiWasmRemoteSpawnOperation(owner, "actor", "", resolve, reject);
              self.ensureSwiWasmRemoteActorConnection(node).then(function(entry) {
                if (op.scopes.some(function(scope) { return scope.aborted; })) throw new Error("remote named startup cancelled");
                entry.pendingSpawns.push(op);
                try {
                  entry.socket.send(JSON.stringify({
                    command: "spawn", request_id:op.id,
                    goal: String(goalText || "true"),
                    options: options
                  }));
                } catch (error) {
                  entry.pendingSpawns.pop();
                  reject(error);
                }
              }).catch(reject);
            });
          },
          spawnSwiWasmRemoteToplevel: function(nodeText, sourceText, sessionText, targetPid,
                                               timeLimitText, idleLimitText, owner) {
            var self = this;
            var node = this.swiWasmRemoteNodeUrl(nodeText);
            var source = String(sourceText || "");
            var session = String(sessionText || "false") === "true";
            return new Promise(function(resolve, reject) {
              var op = self.swiWasmRemoteSpawnOperation(owner, "toplevel", targetPid, resolve, reject);
              self.ensureSwiWasmRemoteActorConnection(node).then(function(entry) {
                if (op.scopes.some(function(scope) { return scope.aborted; })) throw new Error("remote named startup cancelled");
                entry.pendingSpawns.push(op);
                try {
                  entry.socket.send(JSON.stringify({
                    command: "toplevel_spawn", request_id:op.id,
                    options: self.toplevelSpawnOptionsText(source, session, {
                      timeLimit: timeLimitText || "infinite",
                      idleLimit: idleLimitText || "infinite"
                    })
                  }));
                } catch (error) {
                  entry.pendingSpawns.pop();
                  reject(error);
                }
              }).catch(reject);
            });
          },
          callSwiWasmRemoteToplevel: function(pidText, goalText, templateText, limit, offset, once) {
            var self = this;
            var remote = this.parseSwiWasmRemoteToplevelPid(pidText);
            if (!remote) return Promise.resolve(false);
            return this.ensureSwiWasmRemoteActorConnection(remote.node).then(function(entry) {
              entry.toplevelTemplates[String(remote.pid)] = String(templateText || goalText || "true");
              entry.socket.send(JSON.stringify({
                command: "toplevel_call",
                pid: remote.pid,
                goal: String(goalText || "true"),
                options: self.toplevelCallOptionsText({
                  template: String(templateText || goalText || "true"),
                  format: entry.answerTerms ? "prolog" : undefined,
                  limit: String(limit) === "none" ? undefined : Number(limit),
                  offset: Number(offset || 0),
                  once: once === true
                })
              }));
              return true;
            });
          },
          nextSwiWasmRemoteToplevel: function(pidText, limitText) {
            var remote = this.parseSwiWasmRemoteToplevelPid(pidText);
            if (!remote) return Promise.resolve(false);
            return this.ensureSwiWasmRemoteActorConnection(remote.node).then(function(entry) {
              var requestedLimit = String(limitText || "default");
              var envelope = {
                command: "toplevel_next",
                pid: remote.pid
              };
              if (requestedLimit !== "default") {
                envelope.limit = Number(requestedLimit);
              }
              entry.socket.send(JSON.stringify(envelope));
              return true;
            });
          },
          swiWasmStructuredCompound: function(value) {
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
          },
          handleSwiWasmWorkerActorMessage: function(pid, event) {
            var entry = this.swiWasmActorWorkers[pid];
            var message = event && event.data ? event.data : {};
            if (!entry) {
              return;
            }
            if (message.type === "halted" && entry.shellRetired) {
              this.logSwiWasmWorkerTraffic(message, "response");
              this.cleanupSwiWasm2ShellEntry(pid, entry);
              return;
            }
            if (message.type === "ready" || message.type === "spawned") {
              entry.ready = true;
              if (entry.resolveReady) {
                entry.resolveReady(pid);
                entry.resolveReady = null;
                entry.rejectReady = null;
              }
              if (entry.role === "shell_toplevel") {
                this.logSwiWasmWorkerTraffic(message, "response");
                if (!entry.shellCandidate) {
                  this.swiWasm2ShellReady = true;
                  this.swiWasmHostEvent("shell_ready", {pid:pid});
                  this.log("info", "SWI-WASM worker toplevel actor ready.", "swi-wasm");

                }
              } else {
                this.log("transport", pid + " ready.", "swi-wasm", "response");
              }
              return;
            }
            if (entry.role === "shell_toplevel" && this.handleSwiWasm2ToplevelMessage(pid, message)) {
              return;
            }
            if (message.type === "started") {
              if (entry.role !== "shell_toplevel") {
                this.log("transport", pid + " started.", "swi-wasm", "response");
              }
              return;
            }
            if (message.type === "output") {
              if (message.output) {
                if (entry.role === "shell_toplevel") {
                  this.logSwiWasmWorkerTraffic({
                    type: "output",
                    pid: pid,
                    data: String(message.output).replace(/\n$/, "")
                  }, "response");
                }
                this.emitSwiWasmOutput( String(message.output).replace(/\n$/, ""));
              }
              return;
            }
            if (message.type === "terminal_output") {
              if (entry.role === "statechart_actor" && entry.parentPid) {
                var terminalParent = this.swiWasmActorWorkers[String(entry.parentPid)];
                if (terminalParent && terminalParent.role === "shell_toplevel") {
                  this.emitSwiWasmOutput( String(message.term || "true"));
                } else {
                  this.sendSwiWasmActorMessage(
                    entry.parentPid,
                    "terminal_output(" + qualifySwiWasmLocalPid(pid) + "," +
                      String(message.term || "true") + ")",
                    pid
                  );
                }
              }
              return;
            }
            if (message.type === "answer") {
              if (message.output) {
                this.emitSwiWasmOutput( String(message.output).replace(/\n$/, ""));
              }
              return;
            }
            if (message.type === "statechart_trace") {
              this.handleSwiWasmTrace(message.trace || "");
              return;
            }
            if (message.type === "aborted") {
              this.log("transport", pid + " aborted current goal.", "swi-wasm", "response");
              return;
            }
            if (message.type === "send") {
              this.routeSwiWasmActorMessage(pid, message.to, message.message);
              return;
            }
            if (message.type === "request") {
              this.handleSwiWasmActorRequest(pid, message);
              return;
            }
            if (message.type === "send_delayed") {
              this.sendSwiWasmActorMessageDelayed(message.to, message.message, message.delay, message.id);
              return;
            }
            if (message.type === "promise_dispose") {
              this.disposeSwiWasmPromiseRequest(pid, message.ref);
              return;
            }
            if (message.type === "cancel") {
              this.cancelSwiWasmActorMessage(message.id);
              return;
            }
            if (message.type === "monitor") {
              this.monitorSwiWasmActor(pid, message.target, message.ref);
              return;
            }
            if (message.type === "name_commit") {
              this.commitSwiWasmName(pid, message.token, message.name);
              return;
            }
            if (message.type === "name_release") {
              this.releaseSwiWasmName(pid, message.token, message.name);
              return;
            }
            if (message.type === "startup_open") {
              this.openSwiWasmStartup(pid, message.token);
              return;
            }
            if (message.type === "startup_finish") {
              this.finishSwiWasmStartup(pid, message.token, message.committed === true);
              return;
            }
            if (message.type === "worker_scope_open") {
              this.openSwiWasmWorkerScope(pid, message.scope);
              return;
            }
            if (message.type === "worker_scope_release") {
              this.releaseSwiWasmScopedWorker(pid, message.scope, message.worker);
              return;
            }
            if (message.type === "server_monitor_cleanup") {
              this.cleanupSwiWasmServerMonitor(pid, message.ref);
              return;
            }
            if (message.type === "demonitor") {
              this.demonitorSwiWasmActor(pid, message.ref);
              return;
            }
            if (message.type === "register") {
              this.registerSwiWasmActorName(message.kind, message.name, message.pid || pid);
              return;
            }
            if (message.type === "unregister") {
              this.unregisterSwiWasmActorName(message.kind, message.name);
              return;
            }
            if (message.type === "exit") {
              this.exitSwiWasmActor(message.pid || pid, message.reason || "true");
              return;
            }
            if (message.type === "done") {
              if (!entry.done) {
                entry.done = true;
                entry.reason = message.reason || "true";
                if (entry.rejectReady) {
                  entry.rejectReady(new Error("worker exited before ready: " + entry.reason));
                  entry.resolveReady = null;
                  entry.rejectReady = null;
                }
                this.notifySwiWasmActorMonitors(pid, entry.reason);
              } else if (!entry.reason && message.reason) {
                entry.reason = message.reason;
              }
              this.terminateLinkedSwiWasmChildren(pid);
              if (message.output) {
                this.emitSwiWasmOutput( String(message.output).replace(/\n$/, ""));
              }
              // The spawned actor's goal has returned (or it exited
              // itself) - reap its worker so a finished actor does not
              // keep a whole SWI-WASM engine alive.
              if (pid !== "main" && entry.worker) {
                this.disposeSwiWasmPromiseRequest(pid);
                try { entry.worker.terminate(); } catch (_reapError) {}
              }
              if (entry.role === "shell_toplevel" &&
                  !entry.shellCandidate && !entry.shellRetired) {
                this.swiWasm2ShellReady = false;
                this.swiWasm2QueryPending = false;
                this.swiWasmHostEvent("shell_error", {pid:pid,error:"The SWI-WASM worker toplevel actor stopped: " + entry.reason});
              } else {
                this.log("transport", pid + " done.", "swi-wasm", "response");
              }
              return;
            }
            if (message.type === "error") {
              if (!entry.done) {
                entry.done = true;
                entry.reason = "error(" + JSON.stringify(String(message.error || "unknown_error")) + ")";
                if (entry.rejectReady) {
                  entry.rejectReady(new Error(String(message.error || "unknown_error")));
                  entry.resolveReady = null;
                  entry.rejectReady = null;
                }
                this.notifySwiWasmActorMonitors(pid, entry.reason);
              }
              this.terminateLinkedSwiWasmChildren(pid);
              if (entry.role === "shell_toplevel") {
                this.logSwiWasmWorkerTraffic(message, "response");
              }
              this.log("error", pid + " failed: " + String(message.error || "unknown error"), "swi-wasm");
              if (message.output) {
                this.emitSwiWasmOutput( String(message.output).replace(/\n$/, ""));
              }
              if (entry.role === "shell_toplevel" &&
                  !entry.shellCandidate && !entry.shellRetired) {
                this.swiWasm2ShellReady = false;
                this.swiWasm2QueryPending = false;
                this.swiWasmHostEvent("shell_error", {pid:pid,error:String(message.error || "SWI-WASM worker failed")});
              }
            }
          },
          handleSwiWasmActorRequest: function(pid, message) {
            var entry = this.swiWasmActorWorkers[pid];
            var result = null;
            var ok = true;
            var error = "";
            try {
              switch (String(message.action || "")) {
              case "name_reserve":
                result = this.reserveSwiWasmName(pid, message.token, message.name);
                break;
              case "name_publish":
                result = this.publishSwiWasmName(pid, message.token, message.name, message.pid);
                break;
              case "worker_scope_reserve":
                result = this.reserveSwiWasmScopedWorker(pid, message.scope);
                break;
              case "worker_scope_spawn":
                result = this.spawnSwiWasmScopedWorker(pid, message.scope, message.worker, message.goal);
                break;
              case "worker_scope_close":
                this.closeSwiWasmWorkerScope(pid, message.scope);
                result = true;
                break;
              case "reserve_pid":
                result = this.reserveSwiWasmWorkerActorPid(pid);
                break;
              case "make_ref":
                result = this.reserveSwiWasmActorRef();
                break;
              case "spawn":
                result = this.spawnSwiWasmWorkerActorReady(
                  message.goal || "true",
                  message.source || "",
                  message.pid || "",
                  message.name || "",
                  "actor",
                  {
                    parentPid: pid,
                    linked: message.link !== false && String(message.link) !== "false"
                  }
                );
                break;
              case "statechart_spawn":
                result = this.spawnSwiWasmStatechartActor(
                  message.sourceKind, message.source, pid, message.name,
                  message.link !== false && String(message.link) !== "false",
                  message.supportSource, message.ioTarget,
                  message.trace !== false && String(message.trace) !== "false"
                );
                break;
              case "remote_spawn":
                result = this.spawnSwiWasmRemoteActor(message.node || "", message.goal || "true", message.source || "", pid);
                break;
              case "remote_toplevel_spawn":
                result = this.spawnSwiWasmRemoteToplevel(
                  message.node || "", message.source || "", message.session || "false", pid,
                  message.timeLimit || "infinite", message.idleLimit || "infinite", pid
                );
                break;
              case "rpc":
                result = this.requestSwiWasmWorkerRpc(message, pid);
                break;
              case "src_uri":
                result = this.loadSwiWasmUriSource(message.uri || "");
                break;
              case "toplevel_correlation":
                result = this.ensureSwiWasmRemoteActorConnection(message.node).then(function(connection) { return connection.socket.protocol === "web-prolog-sync-v1"; });
                break;
              case "synchronous_send":
                result = this.sendSwiWasmActorMessage(message.to, message.message, pid, true);
                break;
              case "send":
                result = this.sendSwiWasmActorMessage(message.to, message.message, message.from || pid);
                break;
              case "send_delayed":
                result = this.sendSwiWasmActorMessageDelayed(message.to, message.message, message.delay, message.id);
                break;
              case "cancel":
                result = this.cancelSwiWasmActorMessage(message.id);
                break;
              case "actors":
                result = this.swiWasmActorListText();
                break;
              case "register":
                result = this.registerSwiWasmActorName(message.kind, message.name, message.pid || pid);
                break;
              case "unregister":
                result = this.unregisterSwiWasmActorName(message.kind, message.name);
                break;
              case "whereis":
                result = this.whereisSwiWasmActorName(message.kind, message.name);
                break;
              case "monitor":
                result = this.monitorSwiWasmActor(pid, message.target, message.ref);
                break;
              case "demonitor":
                result = this.demonitorSwiWasmActor(pid, message.ref);
                break;
              case "exit":
                result = this.exitSwiWasmActor(message.pid || pid, message.reason || "true");
                break;
              case "abort":
                result = this.abortSwiWasmActor(message.pid || pid);
                break;
              case "input":
                result = this.requestSwiWasmActorInput(String(message.prompt || ""));
                break;
              default:
                ok = false;
                error = "unknown actor request: " + String(message.action || "");
              }
            } catch (requestError) {
              ok = false;
              error = requestError && requestError.message ? requestError.message : String(requestError);
              this.log("error", pid + " request " + String(message.action || "") + " failed: " + error, "swi-wasm");
            }
            var reply = function(replyOk, replyResult, replyError) {
              if (entry && entry.worker) {
                entry.worker.postMessage({
                  command: "reply",
                  id: message.id,
                  ok: replyOk,
                  result: replyResult,
                  error: replyError || ""
                });
              }
            };
            if (ok && result && typeof result.then === "function") {
              result.then(function(value) {
                reply(true, value, "");
              }, function(requestError) {
                var requestMessage = requestError && requestError.message ? requestError.message : String(requestError);
                this.log("error", pid + " request " + String(message.action || "") + " failed: " + requestMessage, "swi-wasm");
                reply(false, null, requestMessage);
              }.bind(this));
              return;
            }
            reply(ok, result, error);
          },
          routeSwiWasmActorMessage: function(fromPid, toText, messageText) {
            var to = localizeSwiWasmPid(toText);
            var message = String(messageText || "true");
            if (to === "main") {
              this.deliverSwiWasmMainActorMessage(message);
              this.log("transport", fromPid + " -> main: " + message, "swi-wasm", "response");
              return true;
            }
            return this.sendSwiWasmActorMessage(to, message);
          },
          resolveSwiWasmActorTarget: function(pidText) {
            var pid = String(pidText || "");
            if (pid === "self") {
              return this.isSwiWasm2Mode ? this.swiWasm2ShellPid : "main";
            }
            if (this.swiWasmActorNames[pid]) {
              return this.swiWasmActorNames[pid];
            }
            if (this.swiWasmActorServices[pid]) {
              return this.swiWasmActorServices[pid];
            }
            return localizeSwiWasmPid(pid);
          },
          swiWasmActorListText: function() {
            var shellPid = this.isSwiWasm2Mode ? String(this.swiWasm2ShellPid || "") : "main";
            var pids = [];
            if (!this.isSwiWasm2Mode ||
                (this.swiWasmActorWorkers[shellPid] &&
                 !this.swiWasmActorWorkers[shellPid].done)) {
              pids.push(qualifySwiWasmLocalPid(shellPid));
            }
            Object.keys(this.swiWasmActorWorkers || {}).sort().forEach(function(pid) {
              var entry = this.swiWasmActorWorkers[pid];
              if (pid !== shellPid && entry && !entry.done) {
                pids.push(qualifySwiWasmLocalPid(pid));
              }
            }.bind(this));
            return "[" + pids.join(",") + "]";
          },
          sendSwiWasmActorMessage: function(pidText, messageText, fromPid, correlated) {
            var self = this;
            var pid = this.resolveSwiWasmActorTarget(pidText);
            var sender = String(fromPid || (this.isSwiWasm2Mode ? this.swiWasm2ShellPid : "main"));
            if (!this.isSwiWasm2Mode && (pid === "statechart" || String(pidText) === "statechart")) {
              //  A spawned child (worker actor or toplevel) replied to the
              //  running chart.  Inject it as an external statechart event,
              //  serialized behind any in-flight engine work -- the same queue
              //  delayed timer events use (drainSwiWasmStatechartEventQueue runs
              //  it via statechart_send once the engine is idle).  This is the
              //  common funnel for both worker request-sends (action "send")
              //  and main-engine routeSwiWasmActorMessage fall-through.
              this.log("transport", String(fromPid || "?") + " -> statechart: " + String(messageText || "true"), "swi-wasm", "response");
              this.enqueueSwiWasmStatechartEvent(String(messageText || "true"));
              return true;
            }
            var remote = parseSwiWasmQualifiedServiceAddress(pid) ||
              this.parseSwiWasmRemoteActorPid(pid);
            if (remote) {
              return this.ensureSwiWasmRemoteActorConnection(remote.node).then(function(entry) {
                if (correlated && entry.socket.protocol !== "web-prolog-sync-v1") return false;
                entry.socket.send(JSON.stringify({
                  command: "send",
                  pid: remote.pid,
                  message: String(messageText || "true"),
                  browser_from: sender
                }));
                return true;
              });
            }
            var entry = this.swiWasmActorWorkers[pid];
            if (pid === "main") {
              this.deliverSwiWasmMainActorMessage(String(messageText || "true"));
              this.log("transport", sender + " -> main: " + String(messageText || "true"), "swi-wasm", "request");
              return true;
            }
            if (!entry || !entry.worker || entry.done) {
              if (/^[1-9][0-9]{9}$/.test(pid)) {
                this.log("transport", "drop message to dead SWI-WASM worker actor " + pid + ".", "swi-wasm");
                return true;
              }
              this.log("warn", "No live SWI-WASM worker actor for " + pid + ".", "swi-wasm");
              return false;
            }
            entry.worker.postMessage({
              command: "deliver",
              message: String(messageText || "true")
            });
            this.log("transport", sender + " -> " + pid + ": " + String(messageText || "true"), "swi-wasm", "request");
            return true;
          },
          sendSwiWasmActorMessageDelayed: function(pidText, messageText, delaySeconds, idText) {
            var self = this;
            var id = String(idText || "");
            var delay = Number(delaySeconds);
            if (!id) {
              id = "delay(" + this.swiWasmNextActorDelayId++ + ")";
            }
            if (!isFinite(delay) || delay < 0) {
              return false;
            }
            if (this.swiWasmActorDelayedSends[id]) {
              window.clearTimeout(this.swiWasmActorDelayedSends[id]);
            }
            this.swiWasmActorDelayedSends[id] = window.setTimeout(function() {
              delete self.swiWasmActorDelayedSends[id];
              self.sendSwiWasmActorMessage(pidText, messageText);
            }, delay * 1000);
            return true;
          },
          cancelSwiWasmActorMessage: function(idText) {
            var id = String(idText || "");
            var timer = this.swiWasmActorDelayedSends[id];
            if (!timer) {
              return false;
            }
            window.clearTimeout(timer);
            delete this.swiWasmActorDelayedSends[id];
            return true;
          },
          registerSwiWasmActorName: function(kind, nameText, pidText) {
            var registry = String(kind || "actor") === "service" ? this.swiWasmActorServices : this.swiWasmActorNames;
            var name = String(nameText || "");
            var pid = this.resolveSwiWasmActorTarget(pidText);
            if (!name || !this.swiWasmActorPidLive(pid)) {
              return false;
            }
            if ((String(kind || "actor") !== "service" && ((this.swiWasmNameReservations || Object.create(null))[name] ||
                 Object.keys(this.swiWasmNameReservations || {}).some(function(key) { return this.swiWasmNameReservations[key].pid === pid; }.bind(this)))) ||
                (Object.prototype.hasOwnProperty.call(registry, name) && registry[name] !== pid)) {
              return false;
            }
            if (Object.keys(registry).some(function(existing) {
              if (registry[existing] === pid && existing !== name) {
                return true;
              }
              return false;
            })) {
              return false;
            }
            Object.defineProperty(registry, name, {value:pid, configurable:true, writable:true, enumerable:true});
            return true;
          },
          unregisterSwiWasmActorName: function(kind, nameText) {
            var registry = String(kind || "actor") === "service" ? this.swiWasmActorServices : this.swiWasmActorNames;
            var name = String(nameText || "");
            if (!Object.prototype.hasOwnProperty.call(registry, name)) {
              return false;
            }
            delete registry[name];
            return true;
          },
          whereisSwiWasmActorName: function(kind, nameText) {
            var registry = String(kind || "actor") === "service" ? this.swiWasmActorServices : this.swiWasmActorNames;
            var name = String(nameText || "");
            return Object.prototype.hasOwnProperty.call(registry, name) ? qualifySwiWasmLocalPid(registry[name]) : "undefined";
          },
          swiWasmActorPidLive: function(pidText) {
            var pid = String(pidText || "");
            if (pid === "main") {
              return !this.isSwiWasm2Mode;
            }
            if (pid === "statechart") {
              //  The running chart is a valid monitor watcher: a child's
              //  down(Pid, Ref, Reason) routes back to it as an external event.
              return !!this.swiWasmStatechartActive;
            }
            if (this.parseSwiWasmRemoteToplevelPid(pid) || this.parseSwiWasmRemoteActorPid(pid)) {
              return true;
            }
            var entry = this.swiWasmActorWorkers[pid];
            return !!(entry && entry.worker && !entry.done);
          },
          takeSwiWasmRemoteMonitor: function(node, pid, refText) {
            var normalizedRef = String(refText || "").replace(/'/g, "");
            var monitor = this.swiWasmActorMonitors.filter(function(item) {
              var remote = this.parseSwiWasmRemoteToplevelPid(item.pid) || this.parseSwiWasmRemoteActorPid(item.pid);
              if (!remote || remote.node !== node) return false;
              // A late event for a withdrawn reference must not consume a
              // different monitor on the same actor. Keep legacy pid fallback
              // only for peers that omit the reference entirely.
              return normalizedRef ? item.ref.replace(/'/g, "") === normalizedRef
                : String(remote.pid) === String(pid);
            }.bind(this))[0];
            if (monitor) this.swiWasmActorMonitors = this.swiWasmActorMonitors.filter(function(item) { return item !== monitor; });
            return monitor;
          },
          monitorSwiWasmActor: function(watcherText, pidText, refText) {
            var watcher = this.resolveSwiWasmActorTarget(watcherText);
            var pid = this.resolveSwiWasmActorTarget(pidText);
            var ref = String(refText || "");
            var localEntry;
            if (this.trackSwiWasmStartup) this.trackSwiWasmStartup(watcher, pid, ref);
            if (!ref || !this.swiWasmActorPidLive(watcher)) {
              return false;
            }
            var remote = this.parseSwiWasmRemoteToplevelPid(pid) || this.parseSwiWasmRemoteActorPid(pid);
            if (remote) {
              var pendingMonitor = { watcher: watcher, pid: pid, ref: ref };
              this.swiWasmActorMonitors.push(pendingMonitor);
              return this.ensureSwiWasmRemoteActorConnection(remote.node).then(function(entry) {
                // Cleanup may have withdrawn it while the connection was opening.
                if (this.swiWasmActorMonitors.indexOf(pendingMonitor) < 0) return false;
                entry.socket.send(JSON.stringify({ command: "monitor", pid: remote.pid, ref: ref }));
                return true;
              }.bind(this));
            }
            localEntry = pid === "statechart" ? this.swiWasmLocalChartResult : this.swiWasmActorWorkers[pid];
            if (!this.swiWasmActorPidLive(pid)) {
              // The worker may finish between spawn's ready reply and
              // install_spawn_monitor/2. Its entry is intentionally retained,
              // so a late monitor must observe the recorded reason rather
              // than losing false/exception as the generic no_process reason.
              this.deliverSwiWasmActorDown(
                watcher,
                ref,
                pid,
                localEntry && localEntry.done
                  ? (localEntry.reason || "true")
                  : "no_process"
              );
              return true;
            }
            this.swiWasmActorMonitors.push({ watcher: watcher, pid: pid, ref: ref });
            return true;
          },
          demonitorSwiWasmActor: function(watcherText, refText) {
            var watcher = this.resolveSwiWasmActorTarget(watcherText);
            var ref = String(refText || "");
            var removed = false;
            var remoteMonitor = null;
            this.swiWasmActorMonitors = this.swiWasmActorMonitors.filter(function(monitor) {
              var keep = !(monitor.watcher === watcher && monitor.ref === ref);
              if (!keep) {
                removed = true;
                remoteMonitor = this.parseSwiWasmRemoteToplevelPid(monitor.pid) || this.parseSwiWasmRemoteActorPid(monitor.pid);
              }
              return keep;
            }.bind(this));
            if (!remoteMonitor) return Promise.resolve(removed);
            return this.ensureSwiWasmRemoteActorConnection(remoteMonitor.node).then(function(entry) {
              entry.socket.send(JSON.stringify({ command: "demonitor", ref: ref }));
              return true;
            });
          },
          cleanupSwiWasmServerMonitor: function(watcherText, refText) {
            // Local removal happens synchronously. Do not await remote transport
            // in a Prolog cleanup; retain the original result/error on failure.
            try {
              Promise.resolve(this.demonitorSwiWasmActor(watcherText, refText)).catch(function() {});
            } catch (_) {}
            // Same coordinator/worker channel as down delivery: all earlier
            // notifications precede this barrier; later ones cannot find the monitor.
            this.sendSwiWasmActorMessage(watcherText, "'$server_monitor_cleaned'(" + refText + ")");
          },
          notifySwiWasmActorMonitors: function(pidText, reasonText) {
            var pid = String(pidText || "");
            var monitors = this.swiWasmActorMonitors.filter(function(monitor) {
              return monitor.pid === pid;
            });
            this.swiWasmActorMonitors = this.swiWasmActorMonitors.filter(function(monitor) {
              return monitor.pid !== pid;
            });
            monitors.forEach(function(monitor) {
              this.deliverSwiWasmActorDown(monitor.watcher, monitor.ref, pid, reasonText || "true");
            }.bind(this));
            this.clearSwiWasmActorNamesForPid(pid);
          },
          deliverSwiWasmActorDown: function(watcherText, refText, pidText, reasonText) {
            var safeReason = sanitizeDownReasonTerm(reasonText || "true");
            var message = "down(" + qualifySwiWasmLocalPid(pidText) + "," + refText + "," + safeReason + ")";
            this.sendSwiWasmActorMessage(watcherText, message);
          },
          clearSwiWasmActorNamesForPid: function(pidText) {
            var pid = String(pidText || "");
            [this.swiWasmActorNames, this.swiWasmActorServices].forEach(function(registry) {
              Object.keys(registry).forEach(function(name) {
                if (registry[name] === pid) {
                  delete registry[name];
                }
              });
            });
          },
          terminateLinkedSwiWasmChildren: function(parentPid) {
            var parent = String(parentPid);
            if (this.releaseSwiWasmNamesForOwner) this.releaseSwiWasmNamesForOwner(parent);
            this.closeSwiWasmWorkerScopes(parent);
            Object.keys(this.swiWasmStartups || {}).forEach(function(key) {
              var scope = this.swiWasmStartups[key];
              if (scope && scope.owner === parent) {
                this.finishSwiWasmStartup(parent, JSON.parse(key)[1], false);
              }
            }.bind(this));
            Object.keys(this.swiWasmActorWorkers || {}).forEach(function(pid) {
              var child = this.swiWasmActorWorkers[pid];
              if (child && child.worker && !child.done && child.linked &&
                  String(child.parentPid || "") === parent) {
                this.exitSwiWasmActor(pid, "kill");
              }
            }.bind(this));
          },
          exitSwiWasmActor: function(pidText, reasonText) {
            var pid = this.resolveSwiWasmActorTarget(pidText);
            var reason = String(reasonText || "true");
            if (pid === "main") {
              return false;
            }
            var remoteToplevel = this.parseSwiWasmRemoteToplevelPid(pid);
            var remoteActor = this.parseSwiWasmRemoteActorPid(pid);
            if (remoteToplevel || remoteActor) {
              var remote = remoteToplevel || remoteActor;
              var cleanupRef = this.reserveSwiWasmActorRef();
              return this.ensureSwiWasmRemoteActorConnection(remote.node).then(function(entry) {
                entry.socket.send(JSON.stringify({
                  command: "exit", request_id: cleanupRef,
                  pid: remote.pid,
                  reason: reason
                }));
                return true;
              });
            }
            var entry = this.swiWasmActorWorkers[pid];
            if (!entry || !entry.worker || entry.done) {
              return true;
            }
            entry.done = true;
            entry.reason = reason;
            this.disposeSwiWasmPromiseRequest(pid);
            this.terminateLinkedSwiWasmChildren(pid);
            try {
              entry.worker.postMessage({ command: "terminate", reason: reason });
              entry.worker.terminate();
            } catch (_error) {
            }
            this.notifySwiWasmActorMonitors(pid, reason);
            this.log("transport", pid + " exited: " + reason + ".", "swi-wasm", "response");
            return true;
          },
          abortSwiWasmActor: function(pidText) {
            var pid = this.resolveSwiWasmActorTarget(pidText);
            if (pid === "main") {
              return false;
            }
            var entry = this.swiWasmActorWorkers[pid];
            if (!entry || !entry.worker || entry.done) {
              return false;
            }
            entry.worker.postMessage({ command: "abort" });
            this.log("transport", pid + " abort requested.", "swi-wasm", "request");
            return true;
          },
          deliverSwiWasmMainActorMessage: function(messageText) {
            var text = String(messageText);
            if (this.swiWasmActorMainWaiters.length > 0) {
              this.swiWasmActorMainWaiters.shift().resolve(text);
              return;
            }
            this.swiWasmActorMainMailbox.push(text);
          },
          deliverSwiWasmRemoteResult: function(messageText, targetPid) {
            if (targetPid && this.swiWasmActorWorkers[String(targetPid)]) {
              this.sendSwiWasmActorMessage(String(targetPid), String(messageText), "remote");
              return;
            }
            if (this.swiWasmStatechartOwnsActorTraffic()) {
              this.enqueueSwiWasmStatechartEvent(String(messageText));
            } else {
              this.deliverSwiWasmMainActorMessage(String(messageText));
            }
          },
          finalizeSwiWasmWorkerActor: function(pid, reason) {
            this.disposeSwiWasmPromiseRequest(pid);
            var entry = this.swiWasmActorWorkers[pid];
            if (!entry) return;
            if (!entry.done) {
              entry.done = true;
              entry.reason = reason || entry.reason || "true";
              this.notifySwiWasmActorMonitors(pid, entry.reason);
            } else if (!entry.reason && reason) {
              entry.reason = reason;
            }
            this.terminateLinkedSwiWasmChildren(pid);
            if (pid !== "main" && entry.worker) {
              try { entry.worker.terminate(); } catch (_reapError) {}
            }
          },
          receiveSwiWasmActorMessage: function(timeoutSeconds) {
            var self = this;
            if (this.swiWasmActorMainMailbox.length > 0) {
              return Promise.resolve(this.swiWasmActorMainMailbox.shift());
            }
            return new Promise(function(resolve, reject) {
              var waiter = { resolve: resolve, reject: reject, timer: null };
              var timeout = Number(timeoutSeconds);
              if (isFinite(timeout) && timeout >= 0) {
                waiter.timer = window.setTimeout(function() {
                  var index = self.swiWasmActorMainWaiters.indexOf(waiter);
                  if (index >= 0) {
                    self.swiWasmActorMainWaiters.splice(index, 1);
                  }
                  resolve(null);
                }, timeout * 1000);
              }
              waiter.resolve = function(value) {
                if (waiter.timer !== null) {
                  window.clearTimeout(waiter.timer);
                }
                resolve(value);
              };
              self.swiWasmActorMainWaiters.push(waiter);
            });
          },
          cancelSwiWasmMainActorWaiters: function(reason) {
            var waiters = this.swiWasmActorMainWaiters.splice(0);
            waiters.forEach(function(waiter) {
              if (waiter.timer !== null) {
                window.clearTimeout(waiter.timer);
              }
              waiter.reject(reason);
            });
            return waiters.length;
          },
          resetSwiWasmActorWorkers: function() {
            Object.keys(this.swiWasmActorWorkers || {}).forEach(function(pid) {
              var entry = this.swiWasmActorWorkers[pid];
              this.disposeSwiWasmPromiseRequest(pid);
              if (entry && entry.worker) {
                try {
                  entry.worker.postMessage({ command: "terminate" });
                  entry.worker.terminate();
                } catch (_error) {
                }
              }
            }.bind(this));
            this.swiWasmActorWorkers = {};
            this.swiWasmActorMainMailbox = [];
            Object.keys(this.swiWasmActorDelayedSends || {}).forEach(function(id) {
              window.clearTimeout(this.swiWasmActorDelayedSends[id]);
            }.bind(this));
            this.swiWasmActorDelayedSends = {};
            this.swiWasmActorNames = {};
            this.swiWasmActorServices = {};
            this.swiWasmRemoteActorKinds = {};
            this.swiWasmActorMonitors = [];
            this.swiWasmActorMainWaiters.splice(0).forEach(function(waiter) {
              if (waiter.timer !== null) {
                window.clearTimeout(waiter.timer);
              }
              waiter.resolve(null);
            });
          },
          installSwiWasmSharedDatabase: function(Prolog, Module) {
            if (!Prolog || !Module || !Module.FS) {
              return Promise.reject(new Error("SWI-WASM shared database requires the virtual filesystem"));
            }
            // The compatibility runtime loads its shared database during
            // startup, before the first query.  Install the actor bridge now
            // so the shared source can import the normal actor API and its
            // operators while it is compiled.
            Module.FS.writeFile("/swi_wasm_actor_bridge.pl", this.swiWasmRpcProlog());
            if (!Prolog.query("use_module('/swi_wasm_actor_bridge.pl')").once()) {
              return Promise.reject(new Error("Unable to install the SWI-WASM actor bridge for the shared database"));
            }
            var databaseUrl = this.swiWasmAssets ? this.swiWasmAssets.sharedDatabaseUrl : "/wasm/shared_db.pl";
            return (databaseUrl === null ? Promise.resolve({ok:true,text:function() { return Promise.resolve(""); }}) : fetch(databaseUrl, { cache: "no-store" })).then(function(response) {
              if (!response.ok) {
                throw new Error("HTTP " + response.status + " for /wasm/shared_db.pl");
              }
              return response.text();
            }).then(function(sourceText) {
              Module.FS.writeFile("/swi_wasm_shared_db.pl",
                ":- set_prolog_flag(double_quotes,chars).\n:- use_module('/swi_wasm_actor_bridge.pl').\n" + sourceText);
              Prolog.query("use_module(library(modules))").once();
              Prolog.query("set_module(wasm_shared_db:base(system))").once();
              Prolog.query("load_files(wasm_shared_db:'/swi_wasm_shared_db.pl',[silent(true)])").once();
              Prolog.query("add_import_module(user,wasm_shared_db,start)").once();
            });
          },
          swiWasmBehaviourProlog: function() {
            return [
              "% Browser-worker implementation of generic servers and supervisors.",
              ":- meta_predicate server_spawn(:, +, -), server_spawn(:, +, -, +), server_upgrade(+, :), server_upgrade(+, :, +), supervisor_spawn(:, -), supervisor_spawn(:, -, +), supervisor_spawn_child(+, :, -), wasm_startup_scope(0), browser_named_creation(+, -, +, -, 0).",
              "browser_named_creation(Options, Pid, PI, Inner, Goal) :-",
              "    option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
              "    ( option(name(Name), Options)",
              "    -> exclude(browser_wrapper_option([name]), Options, Inner),",
              "       Guard = named(open, none),",
              "       setup_call_cleanup((Token := swiWasmNameToken()),",
              "         ( term_string(Name, NameText),",
              "           Reservation := swiWasmNameReserve(#Token, #NameText),",
              "           browser_name_await(Reservation, Status),",
              "           (Status == \"reserved\" -> true ; throw(error(permission_error(register,actor_name,Name),PI))),",
              "           (Node == localhost, PI == statechart_spawn/2, runtime_property(implementation(swi_wasm_main)),",
              "            \\+ statechart_wasm:statechart_running -> nb_setarg(2, Guard, statechart) ; true),",
              "           once(call(Goal)),",
              "           term_string(Pid, PidText),",
              "           (Pid == statechart -> (statechart_wasm:statechart_running -> ChartLive=true ; ChartLive=false) ; ChartLive=true),",
              "           Publication := swiWasmNamePublish(#Token, #NameText, #PidText, #ChartLive),",
              "           browser_name_await(Publication, Published),",
              "           (Published == \"published\" -> Committed := swiWasmNameCommit(#Token, #NameText),",
              "              (Committed == true -> nb_setarg(1, Guard, committed) ; browser_name_error(Committed,Name,PI))",
              "           ; browser_name_error(Published,Name,PI)) ),",
              "         ( (arg(1,Guard,open),arg(2,Guard,statechart) -> catch((statechart_wasm:statechart_stop,_:=swiWasmNamedChartStopped()),_,true) ; true),",
              "           term_string(Name, ReleaseName),",
              "           catch((_ := swiWasmNameRelease(#Token, #ReleaseName)),_,true) ))",
              "    ; Inner = Options, call(Goal) ).",
              "browser_name_error(Status, Name, PI) :-",
              "    ( memberchk(Status, [connection_closed,terminated]) -> throw(error(remote_spawn_failed(Status),PI))",
              "    ; string(Status), memberchk(Status, [\"connection_closed\",\"terminated\"]) -> atom_string(Reason,Status), throw(error(remote_spawn_failed(Reason),PI))",
              "    ; throw(error(permission_error(register,actor_name,Name),PI)) ).",
              "browser_name_await(Promise, Value) :-",
              "    ( runtime_property(implementation(swi_wasm_worker))",
              "    -> swi_wasm_actor_bridge:actor_await(Promise, Value)",
              "    ; await(Promise, Value) ).",
              "server_spawn(Pred, State, Pid) :- server_spawn(Pred, State, Pid, []).",
              "% Strip only wrapper-owned unary options, preserving all other terms and sharing.",
              "browser_wrapper_spawn_options(Names, Options, SpawnOptions) :-",
              "    must_be(list, Options),",
              "    exclude(browser_wrapper_option(Names), Options, SpawnOptions).",
              "browser_wrapper_option(Names, Option) :-",
              "    nonvar(Option), compound(Option), compound_name_arity(Option, Name, 1),",
              "    memberchk(Name, Names).",
              "",
              "server_spawn(Pred0, State, Pid, Options) :-",
              "    validate_browser_wrapper_options(server, server_spawn/4, Options),",
              "    browser_named_creation(Options, Pid, server_spawn/4, Inner, server_spawn_options(Pred0, State, Pid, Inner)).",
              "server_spawn_options(Pred0, State, Pid, Options) :-",
              "    strip_module(Pred0, Module, PlainPred), Pred = Module:PlainPred,",
              "    browser_wrapper_spawn_options([initial_state], Options, BaseOptions),",
              "    ( behaviour_spawn_options(PlainPred, 4, BaseOptions, SpawnOptions) -> true ; throw(error(server_spawn_source_failed(PlainPred), server_spawn/4)) ),",
              "    ( spawn(wasm_server_loop(Pred, State), Pid, SpawnOptions) -> true ; throw(error(server_worker_spawn_failed(PlainPred), server_spawn/4)) ),",
              "    ( option(name(Name), Options) -> ( register(Name, Pid) -> true ; throw(error(server_registration_failed(Name, Pid), server_spawn/4)) ) ; true ).",
              "",
              "behaviour_spawn_options(Pred, Arity, Options, SpawnOptions) :-",
              "    wasm_behaviour_source(Options, Behaviour),",
              "    ( callback_source_option(Options, Pred/Arity) -> CallbackOptions = [] ; CallbackOptions = [src_predicates([Pred/Arity])] ),",
              "    append([src_text(Behaviour)|CallbackOptions], Options, SpawnOptions).",
              "callback_source_option(Options, PI) :- member(src_predicates(PIs), Options), memberchk(PI, PIs).",
              "",
              "wasm_behaviour_source(Source) :- Source := swiWasmBehaviourSource().",
              "% Local Workers already import these definitions. Mark only our added copy;",
              "% remote source is unchanged and has no dependency on browser loader helpers.",
              "wasm_behaviour_source(Options, Source) :-",
              "    wasm_behaviour_source(Behaviour), option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
              "    ( string_length(Behaviour, 0) -> Source = Behaviour",
              "    ; Node == localhost",
              "    -> atomic_list_concat([",
              "         ':- swi_wasm_actor_bridge:behaviour_source_boundary(begin).',",
              "         Behaviour,",
              "         ':- swi_wasm_actor_bridge:behaviour_source_boundary(end).'",
              "       ], '\\n', Source)",
              "    ; Source = Behaviour ).",
              "",
              "wasm_server_loop(Pred, State0) :-",
              "    receive({",
              "      '$call'(From, Ref, Request) ->",
              "        ( call(Pred, Request, State0, Reply, State) -> send(From, Ref-Reply), wasm_server_loop(Pred, State) ; exit(false) ) ;",
              "      '$upgrade'(From, Ref, PlainPred, Source) ->",
              "        ( catch(wasm_prepare_upgrade(PlainPred, Source, Pred1), Error, true),",
              "          ( var(Error) -> send(From, Ref-ok), wasm_server_loop(Pred1, State0)",
              "          ; send(From, Ref-error(Error)), wasm_server_loop(Pred, State0) ) ) ;",
              "      '$stop'(From, Ref) -> send(From, Ref-true) ;",
              "      '$stop'(From) -> send(From, reply(true))",
              "    }).",
              "wasm_prepare_upgrade(PlainPred, Source, user:PlainPred) :-",
              "    ( Source == '' -> true ; functor(PlainPred, Name, Extra), Arity is Extra+4, abolish(user:Name/Arity), wasm_load_upgrade_source(Source) ),",
              "    functor(PlainPred, Name, Extra), Arity is Extra+4,",
              "    ( current_predicate(user:Name/Arity) -> true ; throw(error(existence_error(procedure, user:Name/Arity), server_upgrade/3)) ).",
              "wasm_load_upgrade_source(Source) :- setup_call_cleanup(open_string(Source, Stream), wasm_read_upgrade_source(Stream), (close(Stream),set_prolog_flag(user:double_quotes,chars))).",
              "wasm_read_upgrade_source(Stream) :-",
              "    read_term(Stream, Term, [module(user)]),",
              "    ( Term == end_of_file -> true ; wasm_assert_upgrade_term(Term), wasm_read_upgrade_source(Stream) ).",
              "wasm_assert_upgrade_term((:- set_prolog_flag(double_quotes, Mode))) :- !, set_prolog_flag(user:double_quotes,Mode).",
              "wasm_assert_upgrade_term((:- Directive)) :- !, call(Directive).",
              "wasm_assert_upgrade_term(Term) :- assertz(user:Term).",
              "",
              ":- meta_predicate toplevel_call_synch(+, :, -), toplevel_call_synch(+, :, -, :), toplevel_next_synch(+, -), toplevel_next_synch(+, -, :).",
              "toplevel_call_synch(Pid, Goal, Answer) :- toplevel_call_synch(Pid, Goal, Answer, []).",
              "toplevel_call_synch(Pid, Goal, Answer, Options) :-",
              "    synchronous_options(call, Options, Caller, Query, Wait),",
              "    synchronous_pid(Pid, Key), make_ref(Ref), make_ref(Mon),",
              "    setup_call_cleanup(true,",
              "      ( install_monitor(Pid, Mon), synchronous_send(Pid, '$call'(Goal, ['$request_ref'(Ref)|Query])),",
              "        synchronous_answer(Key, Mon, Ref, Answer, Caller, Wait) ),",
              "      server_monitor_cleanup(Mon)).",
              "toplevel_next_synch(Pid, Answer) :- toplevel_next_synch(Pid, Answer, []).",
              "toplevel_next_synch(Pid, Answer, Options) :-",
              "    synchronous_options(next, Options, Caller, Query, Wait),",
              "    synchronous_pid(Pid, Key), make_ref(Ref), make_ref(Mon),",
              "    setup_call_cleanup(true,",
              "      ( install_monitor(Pid, Mon), synchronous_send(Pid, '$next'(['$request_ref'(Ref)|Query])),",
              "        synchronous_answer(Key, Mon, Ref, Answer, Caller, Wait) ),",
              "      server_monitor_cleanup(Mon)).",
              "synchronous_pid(Pid, Key) :-",
              "    must_be(nonvar, Pid),",
              "    ( integer(Pid) -> Key = Pid@localhost",
              "    ; compound(Pid), compound_name_arguments(Pid, @, [Id,Node]), Node == localhost, integer(Id)",
              "    -> Key = Pid",
              "    ; compound(Pid), compound_name_arguments(Pid, @, [Id,Node]), integer(Id), atom(Node)",
              "    -> synchronous_remote_support(Node, Supported),",
              "       ( Supported == true -> Key = Pid ; throw(error(permission_error(use,toplevel_correlation,Node),_)) )",
              "    ; throw(error(permission_error(use,toplevel_correlation,Pid),_)) ).",
              "synchronous_options(Kind, Options0, Caller, [target(Self)|Query], Receive) :-",
              "    strip_module(Options0, Caller, Options),",
              "    atom_concat(toplevel_, Kind, Prefix), atom_concat(Prefix, '_synch', Name),",
              "    (Kind == call -> Arity = 4 ; Arity = 3),",
              "    catch((must_be(list, Options), self(Self),",
              "           split_synchronous_options(Options, Kind, Self, Query, Receive)),",
              "          error(Formal, _),",
              "          throw(error(Formal, context(Name/Arity,",
              "                                     'invalid synchronous toplevel option')))).",
              "",
              "split_synchronous_options([], _, _, [], []).",
              "split_synchronous_options([Option|Options], Kind, Self, Query, Receive) :-",
              "    must_be(nonvar, Option),",
              "    (   compound(Option), compound_name_arity(Option, Name, 1),",
              "        synchronous_option(Kind, Name, Destination, Type)",
              "    ->  arg(1, Option, Value),",
              "        synchronous_option_value(Type, Value, Self),",
              "        (   Destination == query -> Query = [Option|Qs], Receive = Rs",
              "        ;   Destination == receive -> Query = Qs, Receive = [Option|Rs]",
              "        ;   Query = Qs, Receive = Rs",
              "        ),",
              "        split_synchronous_options(Options, Kind, Self, Qs, Rs)",
              "    ;   atom_concat(toplevel_, Kind, Prefix),",
              "        atom_concat(Prefix, '_synch_option', Domain), domain_error(Domain, Option)",
              "    ).",
              "",
              "synchronous_option(_, target, routing, target).",
              "synchronous_option(_, timeout, receive, number).",
              "synchronous_option(_, on_timeout, receive, callable).",
              "synchronous_option(_, limit, query, positive_integer).",
              "synchronous_option(call, template, query, term).",
              "synchronous_option(call, offset, query, nonneg).",
              "synchronous_option(call, once, query, boolean).",
              "",
              "",
              "synchronous_option_value(target, Target, Self) :- !,",
              "    must_be(nonvar, Target),",
              "    (Target == Self -> true ; domain_error(synchronous_toplevel_target, Target)).",
              "synchronous_option_value(term, _, _) :- !.",
              "synchronous_option_value(Type, Value, _) :- must_be(Type, Value).",
              "",
              "",
              "synchronous_answer(Pid, Mon, Ref, Answer, Caller, Options) :-",
              "    option(timeout(Seconds), Options, -1),",
              "    ( Seconds > 0 -> get_time(Now), Deadline is Now+Seconds ; Deadline = Seconds ),",
              "    option(on_timeout(Callback), Options, true),",
              "    once(synchronous_receive(Pid,Mon,Ref,Answer,Caller,Callback,Seconds,Deadline)).",
              "synchronous_receive(Pid,Mon,Ref,Answer,Caller,Callback,Seconds,Deadline) :-",
              "    ( Seconds > 0 -> get_time(Now), Remaining is max(0,Deadline-Now) ; Remaining = Seconds ),",
              "    receive({",
              "      '$toplevel_reply'(ReplyRef,Payload) if synchronous_payload(Payload,Pid) ->",
              "        ( ReplyRef == Ref -> Answer = Payload",
              "        ; synchronous_receive(Pid,Mon,Ref,Answer,Caller,Callback,Seconds,Deadline) ) ;",
              "      down(_,Mon,Reason) -> throw(toplevel_down(Reason))",
              "    }, [timeout(Remaining),on_timeout(once(call(Caller:Callback)))]).",
              "synchronous_payload(success(P,_,_), Pid) :- P == Pid.",
              "synchronous_payload(failure(P), Pid) :- P == Pid.",
              "synchronous_payload(error(P,_), Pid) :- P == Pid.",
              "ptcp_reply_ref(Target, Ref) :- (functor(Target,_,2) -> arg(2,Target,Ref) ; Ref=none).",
              "ptcp_next_ref(Options, Target) :-",
              "    (functor(Target,_,2) -> option('$request_ref'(Ref),Options,none), nb_setarg(2,Target,Ref) ; true).",
              "send_toplevel_answer(Target, Answer) :-",
              "    arg(1,Target,Out), ptcp_reply_ref(Target,Ref),",
              "    ( Ref == none -> send(Out,Answer) ; send(Out,'$toplevel_reply'(Ref,Answer)) ).",
              "server_promise(To, Request, Ref) :- self(Self), make_ref(Ref), send(To, '$call'(Self, Ref, Request)).",
              "server_promise(To, Request, Ref, MonRef) :-",
              "    make_ref(MonRef),",
              "    call_cleanup((install_monitor(To, MonRef), server_promise(To, Request, Ref), Sent = true),",
              "                 (Sent == true -> true ; server_monitor_cleanup(MonRef))).",
              "server_yield(Ref, Reply) :- server_yield(Ref, Reply, []).",
              "server_yield(Ref, Reply, Options) :- receive({Ref-Answer -> Reply = Answer}, Options).",
              "server_yield(Ref, MonRef, Reply, Options) :-",
              "    call_cleanup(receive({Ref-Reply0 -> Reply = Reply0 ; down(_, MonRef, Reason) -> throw(server_down(Reason))}, Options),",
              "                 server_monitor_cleanup(MonRef)).",
              "server_request(To, Request, Reply) :- server_request(To, Request, Reply, []).",
              "server_request(To, Request, Reply, Options) :- server_promise(To, Request, Ref, MonRef), server_yield(Ref, MonRef, Reply, Options).",
              "server_upgrade(To, Pred0) :- server_upgrade_source(To, Pred0, '').",
              "server_upgrade(To, Pred0, Options) :- collect_spawn_source(Options, Source), server_upgrade_source(To, Pred0, Source).",
              "server_upgrade_source(To, Pred0, Source) :-",
              "    strip_module(Pred0, _Module, PlainPred), self(Self), make_ref(Ref),",
              "    send(To, '$upgrade'(Self, Ref, PlainPred, Source)),",
              "    receive({Ref-ok -> true ; Ref-error(Error) -> throw(Error)}).",
              "server_halt(To, Reply) :- self(Self), send(To, '$stop'(Self)), receive({reply(Reply) -> true}).",
              "server_stop(To, Reply) :- server_halt(To, Reply).",
              "",
              "% Validate in place: never normalise/copy child goals, states or source terms.",
              "browser_child_acyclic(Term) :-",
              "    ( acyclic_term(Term) -> true ; representation_error(cyclic_term) ).",
              "browser_validate_child_specs(Specs0, PI) :-",
              "    catch((browser_child_acyclic(Specs0), strip_module(Specs0, _, Specs),",
              "           browser_child_specs(Specs)),",
              "          error(Formal, _), throw(error(Formal, context(PI, 'invalid child specification')))).",
              "browser_child_specs(Specs) :-",
              "    must_be(list, Specs), maplist(browser_child_spec, Specs), browser_child_ids(Specs, []).",
              "browser_child_ids([], _).",
              "browser_child_ids([child(Id,_)|Rest], Seen) :-",
              "    ( memberchk(Id, Seen) -> permission_error(duplicate, supervisor_child_id, Id)",
              "    ; browser_child_ids(Rest, [Id|Seen]) ).",
              "browser_validate_child_spec(Spec0, Spec, PI) :-",
              "    catch((browser_child_acyclic(Spec0), strip_module(Spec0, _, Spec), browser_child_spec(Spec)),",
              "          error(Formal, _), throw(error(Formal, context(PI, 'invalid child specification')))).",
              "browser_child_spec(Spec) :-",
              "    must_be(nonvar, Spec),",
              "    ( compound(Spec), compound_name_arity(Spec, child, 2)",
              "    -> arg(1, Spec, Id), arg(2, Spec, Options)",
              "    ; type_error(supervisor_child_spec, Spec) ),",
              "    must_be(atom, Id), must_be(list, Options), maplist(browser_child_option, Options),",
              "    ( option(start(_), Options) -> true ; throw(error(missing_start_option(Id), supervisor)) ).",
              "browser_child_option(Option) :-",
              "    must_be(nonvar, Option),",
              "    ( compound(Option), compound_name_arity(Option, Name, 1),",
              "      memberchk(Name, [start,restart,shutdown,type,significant])",
              "    -> arg(1, Option, Value), browser_child_value(Name, Value)",
              "    ; validate_browser_spawn_option(Option) ).",
              "browser_child_callable(Goal) :-",
              "    must_be(callable, Goal),",
              "    ( Goal = Module:Inner -> must_be(atom, Module), browser_child_callable(Inner) ; true ).",
              "browser_child_value(start, Start) :-",
              "    browser_child_callable(Start),",
              "    ( Start = server(Pred, Options)",
              "    -> browser_child_callable(Pred), validate_browser_wrapper_options(server, supervisor_spawn/3, Options)",
              "    ; Start = start_sub_supervisor(Specs, Options)",
              "    -> validate_browser_wrapper_options(supervisor, supervisor_spawn/3, Options),",
              "       browser_validate_child_specs(Specs, supervisor_spawn/3)",
              "    ; true ).",
              "browser_child_value(restart, Value) :- must_be(oneof([permanent,transient,temporary]), Value).",
              "browser_child_value(type, Value) :- must_be(oneof([worker,supervisor]), Value).",
              "browser_child_value(significant, Value) :- validate_rpc_client_value(spawn_boolean, Value).",
              "browser_child_value(shutdown, Value) :-",
              "    must_be(nonvar, Value),",
              "    ( Value == brutal_kill -> true ; Value == infinity -> true",
              "    ; number(Value), Value >= 0 -> true ; domain_error(supervisor_child_shutdown, Value) ).",
              "",
              "% JavaScript exception objects cannot cross actor mailboxes as blobs.",
              "wasm_startup_error(Error, error(supervisor_startup_error(Message), supervisor_spawn/3)) :-",
              "    blob(Error, Type), Type \\== text, Type \\== reserved_symbol, !,",
              "    Message := swiWasmStartupErrorText(#Error).",
              "wasm_startup_error(Error, Error).",
              "",
              "wasm_startup_scope(Goal) :-",
              "    setup_call_cleanup((Token := swiWasmStartupOpen()),",
              "        ( catch(once(call(Goal)), Error, (wasm_startup_error(Error, Report), throw(Report))),",
              "          _ := swiWasmStartupFinish(#Token, #true) ),",
              "        catch((_ := swiWasmStartupFinish(#Token, #false)), _, true)).",
              "",
              "supervisor_spawn(Specs, Pid) :- supervisor_spawn(Specs, Pid, []).",
              "supervisor_spawn(Specs0, Pid, Options) :-",
              "    validate_browser_wrapper_options(supervisor, supervisor_spawn/3, Options),",
              "    browser_validate_child_specs(Specs0, supervisor_spawn/3),",
              "    browser_named_creation(Options, Pid, supervisor_spawn/3, Inner, supervisor_spawn_options(Specs0, Pid, Inner)).",
              "supervisor_spawn_options(Specs0, Pid, Options) :-",
              "    strip_module(Specs0, _Caller, Specs),",
              "    option(strategy(Strategy), Options, one_for_one), option(intensity(Max), Options, 1), option(period(Period), Options, 5),",
              "    wasm_behaviour_source(Options, Behaviour),",
              "    self(Parent),",
              "    browser_wrapper_spawn_options([strategy,intensity,period], Options, SpawnOptions),",
              "    wasm_startup_scope((",
              "        spawn(wasm_supervisor_init(Parent, Specs, sup(Strategy, Max, Period, [], [])), Pid, [src_text(Behaviour)|SpawnOptions]),",
              "        wasm_wait_supervisor_ready(Pid),",
              "        ( option(name(Name), Options) -> register(Name, Pid) ; true ) )).",
              "",
              "wasm_wait_supervisor_ready(Pid) :-",
              "    receive({'$supervisor_ready'(Pid) -> true ; '$supervisor_failed'(Pid, Reason) -> throw(error(supervisor_start_failed(Pid, Reason), supervisor_spawn/3))}, [timeout(10), on_timeout(throw(error(timeout_error(supervisor_start, Pid), supervisor_spawn/3)))]).",
              "",
              "wasm_supervisor_init(Parent, Specs, State0) :-",
              "    self(Self),",
              "    catch((wasm_startup_scope(wasm_start_specs(Specs, State0, State))",
              "           -> Outcome = ready ; Outcome = failed_plain),",
              "          Error, Outcome = failed(Error)),",
              "    ( Outcome == ready",
              "    -> send(Parent, '$supervisor_ready'(Self)), wasm_supervisor_loop(State)",
              "    ; Outcome == failed_plain -> send(Parent, '$supervisor_failed'(Self, start_failed)), exit(start_failed)",
              "    ; Outcome = failed(Reason), send(Parent, '$supervisor_failed'(Self, Reason)),",
              "      exit(exception(Reason)) ).",
              "wasm_start_specs([], State, State).",
              "wasm_start_specs([Spec|Rest], State0, State) :- wasm_start_child(Spec, State0, State1), wasm_start_specs(Rest, State1, State).",
              "",
              "wasm_start_child(Spec, sup(Str, Max, Period, Children, Restarts), sup(Str, Max, Period, Children1, Restarts)) :-",
              "    wasm_spawn_child_record(Spec, Child), append(Children, [Child], Children1).",
              "wasm_spawn_child_record(child(Id, ChildOptions), child(Id, Pid, child(Id, ChildOptions))) :-",
              "    ( option(start(Start), ChildOptions) -> true ; throw(error(child_missing_start(Id), wasm_start_child/3)) ),",
              "    browser_wrapper_spawn_options([start,restart,shutdown,type,significant], ChildOptions, SpawnOptions),",
              "    ( wasm_child_start(Start, Id, SpawnOptions, Pid) -> true ; throw(error(child_spawn_failed(Id, Start), wasm_start_child/3)) ),",
              "    ( monitor(Pid, Ref) -> wasm_remember_child_monitor(Pid, Ref) ; throw(error(child_monitor_failed(Id, Pid), wasm_start_child/3)) ).",
              "wasm_child_start(server(Pred, ServerOptions), Id, ChildOptions, Pid) :- !, option(initial_state(State), ServerOptions, []), append(ServerOptions, [name(Id)|ChildOptions], Options), server_spawn(Pred, State, Pid, Options).",
              "wasm_child_start(start_sub_supervisor(Specs, SupOptions), Id, ChildOptions, Pid) :- !, append(SupOptions, [name(Id)|ChildOptions], Options), supervisor_spawn(Specs, Pid, Options).",
              "wasm_child_start(Goal, Id, ChildOptions, Pid) :- spawn(Goal, Pid, [name(Id)|ChildOptions]).",
              "",
              "wasm_remember_child_monitor(Pid, Ref) :-",
              "    (nb_current('$supervisor_child_monitors', Old) -> true ; Old = []),",
              "    nb_setval('$supervisor_child_monitors', [Pid-Ref|Old]).",
              "wasm_prune_child_monitors(sup(_,_,_,Children,_)) :-",
              "    (nb_current('$supervisor_child_monitors', Old) -> true ; Old = []),",
              "    include(wasm_current_child_pid(Children), Old, Current),",
              "    nb_setval('$supervisor_child_monitors', Current).",
              "wasm_current_child_pid(Children, Pid-_) :-",
              "    Pid \\== undefined, member(child(_,ChildPid,_), Children), Pid == ChildPid, !.",
              "wasm_current_child_monitor(Pid, Ref, sup(_,_,_,Children,_)) :-",
              "    ground(Pid-Ref), wasm_current_child_pid(Children, Pid-Ref),",
              "    nb_current('$supervisor_child_monitors', Monitors),",
              "    member(ChildPid-ChildRef, Monitors), Pid == ChildPid, Ref == ChildRef, !.",
              "wasm_supervisor_loop(State0) :- wasm_prune_child_monitors(State0), receive({",
              "    down(Pid, Ref, Reason) if wasm_current_child_monitor(Pid, Ref, State0) -> wasm_handle_down(Pid, Reason, State0, State1), wasm_supervisor_loop(State1) ;",
              "    down(_, _, _) -> wasm_supervisor_loop(State0) ;",
              "    '$sup'(From, Ref, stop) -> wasm_stop_children(State0), send(From, Ref-true) ;",
              "    '$sup'(From, Ref, Request) -> wasm_handle_supervisor_call(Request, Reply, State0, State1), send(From, Ref-Reply), wasm_supervisor_loop(State1) ;",
              "    '$sup_stop'(From) -> wasm_stop_children(State0), send(From, reply(true))",
              "  }).",
              "",
              "% Keep stopped/replaced records at their original positions.",
              "wasm_child_position(Id, Children, Before, Pid, Spec, After) :-",
              "    append(Before, [child(Id,Pid,Spec)|After], Children), !.",
              "wasm_handle_down(Pid, Reason, State0, State) :-",
              "    State0 = sup(Strategy, Max, Period, Children, Restarts),",
              "    ( ground(Pid), Pid \\== undefined, append(Before, [child(Id,Pid,Spec)|After], Children) ->",
              "      Spec = child(_, Options), option(restart(Restart), Options, permanent),",
              "      append(Before, [child(Id,undefined,Spec)|After], Marked),",
              "      ( wasm_should_restart(Restart, Reason)",
              "      -> ( wasm_note_restart(Max, Period, Restarts, Restarts1)",
              "         -> wasm_restart_attempt(Strategy, Id, Spec, Marked, sup(Strategy,Max,Period,Marked,Restarts1), State)",
              "         ; wasm_restart_failure_cleanup(Marked), exit(shutdown) )",
              "      ; ( Restart == temporary -> append(Before, After, Remaining) ; Remaining = Marked ),",
              "        State = sup(Strategy,Max,Period,Remaining,Restarts) )",
              "    ; State = State0 ).",
              "wasm_should_restart(permanent, _).",
              "wasm_should_restart(transient, Reason) :- Reason \\== true.",
              "wasm_note_restart(Max, Period, Restarts0, Restarts) :- get_time(Now), Cutoff is Now-Period, include(wasm_recent(Cutoff), Restarts0, Recent), length(Recent, Count), Count < Max, Restarts = [Now|Recent].",
              "wasm_recent(Cutoff, Time) :- Time > Cutoff.",
              "",
              "wasm_apply_strategy(one_for_one, Id, Spec, Children, sup(Str,Max,Period,_,R), sup(Str,Max,Period,NewChildren,R)) :-",
              "    wasm_child_position(Id, Children, Before, _, _, After),",
              "    wasm_restart_child_record(child(Id,undefined,Spec), Child), append(Before, [Child|After], NewChildren).",
              "wasm_apply_strategy(one_for_all, _, _, Children, sup(Str,Max,Period,_,R), sup(Str,Max,Period,NewChildren,R)) :-",
              "    wasm_stop_child_list(Children), maplist(wasm_restart_child_record, Children, NewChildren).",
              "wasm_apply_strategy(rest_for_one, Id, _, Children, sup(Str,Max,Period,_,R), sup(Str,Max,Period,NewChildren,R)) :-",
              "    wasm_child_position(Id, Children, Before, Pid, Spec, After),",
              "    Affected = [child(Id,Pid,Spec)|After],",
              "    wasm_stop_child_list(Affected), maplist(wasm_restart_child_record, Affected, Restarted),",
              "    append(Before, Restarted, NewChildren).",
              "wasm_restart_attempt(Strategy, Id, Spec, Children, State0, State) :-",
              "    catch(wasm_startup_scope(wasm_apply_strategy(Strategy, Id, Spec, Children, State0, State)),",
              "          Error, (wasm_restart_failure_cleanup(Children), exit(Error))).",
              "wasm_restart_child_record(child(Id,_,Spec), Child) :-",
              "    catch((wasm_spawn_child_record(Spec, Child) -> true ; throw(start_failed)),",
              "          Error, (wasm_startup_error(Error, Report), throw(restart_failed(Id, Report)))).",
              "wasm_restart_failure_cleanup(Children) :-",
              "    reverse(Children, Reverse), maplist(wasm_restart_stop_child, Reverse).",
              "wasm_restart_stop_child(Child) :- catch((wasm_shutdown_child(Child) -> true ; true), _, true).",
              "% One private monitor also tags the internal server stop acknowledgement.",
              "wasm_shutdown_child(child(_, undefined, _)) :- !.",
              "wasm_shutdown_child(child(_, Pid, child(_, Options))) :-",
              "    option(start(Start), Options), option(type(Type), Options, worker),",
              "    ( Type == supervisor -> Default = infinity ; Default = 5 ),",
              "    option(shutdown(Shutdown), Options, Default),",
              "    make_ref(Ref),",
              "    setup_call_cleanup(true,",
              "      ( swi_wasm_actor_bridge:install_monitor(Pid, Ref),",
              "        wasm_shutdown_request(Pid, Start, Shutdown, Ref) ),",
              "      swi_wasm_actor_bridge:supervisor_shutdown_cleanup(Ref)).",
              "wasm_shutdown_request(Pid, _, brutal_kill, Ref) :- !,",
              "    exit(Pid, kill), wasm_shutdown_wait(Ref).",
              "wasm_shutdown_request(Pid, server(_, _), Shutdown, Ref) :- !,",
              "    self(Self), (send(Pid, '$stop'(Self, Ref)) -> true ; true),",
              "    ( Shutdown == infinity -> wasm_shutdown_wait(Ref)",
              "    ; wasm_shutdown_wait(Ref, Shutdown) -> true",
              "    ; exit(Pid, shutdown), wasm_shutdown_wait(Ref) ).",
              "wasm_shutdown_request(Pid, _, _, Ref) :-",
              "    exit(Pid, shutdown), wasm_shutdown_wait(Ref).",
              "wasm_shutdown_wait(Ref) :- receive({down(_, Ref, _) -> true}).",
              "wasm_shutdown_wait(Ref, Seconds) :-",
              "    Got = got(false),",
              "    receive({down(_, Ref, _) -> nb_setarg(1, Got, true)}, [timeout(Seconds)]),",
              "    arg(1, Got, true).",
              "wasm_stop_child_list([]).",
              "wasm_stop_child_list([Child|Rest]) :-",
              "    wasm_shutdown_child(Child), wasm_stop_child_list(Rest).",
              "wasm_stop_children(sup(_,_,_,Children,_)) :-",
              "    reverse(Children, Reverse), wasm_stop_child_list(Reverse).",
              "",
              "wasm_handle_supervisor_call(which_children, Children, State, State) :- State = sup(_,_,_,Children,_).",
              "wasm_handle_supervisor_call(count_children, counts(Total,Active), State, State) :- State = sup(_,_,_,Children,_), length(Children, Total), include(wasm_child_running, Children, Running), length(Running, Active).",
              "wasm_handle_supervisor_call(start_child(Spec0), Reply, State0, State) :-",
              "    catch((browser_validate_child_spec(Spec0, Spec, supervisor_spawn_child/3), Valid=true), Error, Valid=error(Error)),",
              "    ( Valid = error(Invalid) -> Reply=error(Invalid), State=State0",
              "    ; State0=sup(_,_,_,Children,_), Spec=child(Id,_),",
              "      ( memberchk(child(Id,_,_), Children) -> Reply=error(already_present), State=State0",
              "      ; catch((wasm_startup_scope(wasm_start_child(Spec, State0, NewState)) -> Outcome=ok ; Outcome=error(start_failed)),",
              "              StartError, (wasm_startup_error(StartError, Report), Outcome=error(Report))),",
              "        ( Outcome == ok -> Reply=ok, State=NewState ; Reply=Outcome, State=State0 ) ) ).",
              "wasm_handle_supervisor_call(terminate_child(Id), Reply, State0, State) :-",
              "    State0=sup(Str,Max,Period,Children,R),",
              "    ( wasm_child_position(Id, Children, Before, Pid, Spec, After)",
              "    -> wasm_shutdown_child(child(Id,Pid,Spec)),",
              "       append(Before, [child(Id,undefined,Spec)|After], NewChildren),",
              "       Reply=ok, State=sup(Str,Max,Period,NewChildren,R)",
              "    ; Reply=error(not_found), State=State0 ).",
              "wasm_handle_supervisor_call(delete_child(Id), Reply, State0, State) :-",
              "    State0=sup(Str,Max,Period,Children,R),",
              "    ( wasm_child_position(Id, Children, Before, Pid, _, After)",
              "    -> ( Pid == undefined -> append(Before, After, NewChildren), Reply=ok, State=sup(Str,Max,Period,NewChildren,R)",
              "       ; Reply=error(running), State=State0 )",
              "    ; Reply=error(not_found), State=State0 ).",
              "wasm_handle_supervisor_call(restart_child(Id), Reply, State0, State) :-",
              "    State0=sup(Str,Max,Period,Children,R),",
              "    ( wasm_child_position(Id, Children, Before, Pid, Spec, After)",
              "    -> ( Pid == undefined",
              "       -> catch((wasm_startup_scope(wasm_spawn_child_record(Spec, Child)) -> Outcome=ok ; Outcome=error(start_failed)),",
              "                Error, (wasm_startup_error(Error, Report), Outcome=error(Report))),",
              "          ( Outcome == ok",
              "          -> append(Before, [Child|After], NewChildren), Reply=ok, State=sup(Str,Max,Period,NewChildren,R)",
              "          ; Reply=Outcome, State=State0 )",
              "       ; Reply=error(running), State=State0 )",
              "    ; Reply=error(not_found), State=State0 ).",
              "wasm_child_running(child(_,Pid,_)) :- Pid \\== undefined.",
              "",
              "wasm_supervisor_call(Sup, Request, Reply) :-",
              "    self(Self), make_ref(Ref), make_ref(MonRef),",
              "    setup_call_cleanup(true,",
              "      ( install_monitor(Sup, MonRef), send(Sup, '$sup'(Self,Ref,Request)),",
              "        receive({Ref-Answer -> Reply = Answer ; down(_, MonRef, Reason) -> throw(supervisor_down(Reason))},",
              "                [timeout(10), on_timeout(throw(supervisor_call_timeout(Sup,Request)))]) ),",
              "      server_monitor_cleanup(MonRef)).",
              "supervisor_spawn_child(Sup, Spec0, Reply) :- browser_validate_child_spec(Spec0, Spec, supervisor_spawn_child/3), wasm_supervisor_call(Sup, start_child(Spec), Reply).",
              "supervisor_terminate_child(Sup, Id, Reply) :- wasm_supervisor_call(Sup, terminate_child(Id), Reply).",
              "supervisor_delete_child(Sup, Id, Reply) :- wasm_supervisor_call(Sup, delete_child(Id), Reply).",
              "supervisor_respawn_child(Sup, Id, Reply) :- wasm_supervisor_call(Sup, restart_child(Id), Reply).",
              "supervisor_which_children(Sup, Children) :- wasm_supervisor_call(Sup, which_children, Children).",
              "supervisor_count_children(Sup, Counts) :- wasm_supervisor_call(Sup, count_children, Counts).",
              "supervisor_halt(Sup) :- wasm_supervisor_call(Sup, stop, _).",
              "supervisor_stop(Sup) :- supervisor_halt(Sup)."
            ].join("\n");
          },
          swiWasmRpcProlog: function() {
            return [
              "% library(wasm), lists, apply pre-loaded at startup",
              "% Experimental browser-only worker actor bridge.",
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
              ":- op(800, xfx, !).",
              ":- op(200, xfx, @).",
              ":- op(1000, xfy, if).",
              ":- op(990, xfx, :=).",
              ":- op(100, fx, #).",
              ":- use_module(library(wasm)).",
              ":- use_module(library(apply)).",
              ":- use_module(library(error)).",
              ":- use_module(library(lists)).",
              ":- use_module(library(option)).",
              ":- meta_predicate spawn(:), spawn(:, -), spawn(:, -, +), toplevel_call(+, :), toplevel_call(+, :, +), toplevel_call_synch(+, :, -), toplevel_call_synch(+, :, -, :), toplevel_next_synch(+, -), toplevel_next_synch(+, -, :), receive(:), receive(:, +), with_io_target(+, 0), parallel(:), first_solution(?, :), first_solution(?, :, +), yield(+, -, :), with_worker_scope(-, 0), spawn_scoped_worker(+, 0, -).",
              ":- dynamic deferred/1, io_target/1, retiring_server_monitor/1, retiring_supervisor_shutdown/1, retiring_scope_worker/2, closing_worker_scope/1, suppress_shared_override_warnings/0.",
              ":- multifile user:message_hook/3.",
              "",
              "self(main@localhost).",
              "runtime_property(implementation(swi_wasm_main)).",
              "runtime_property(persistent(false)).",
              "runtime_property(inbound_addressable(false)).",
              "runtime_property(dom(true)).",
              "runtime_property(actor_isolation(cooperative_engine)).",
              "runtime_property(hard_termination(false)).",
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
              "    swi_wasm_actor_bridge:suppress_shared_override_warnings,",
              "    member(url(File:_), Lines),",
              "    atom(File),",
              "    sub_atom(File, _, _, 0, 'swi_wasm_shared_db.pl').",
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
              "browser_spawn_option_type(src_list, list).",
              "browser_spawn_option_type(src_predicates, predicate_indicators).",
              "browser_spawn_option_type(src_uri, atom_or_string).",
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
              "    %  Bind Pid BEFORE term_string(Goal, ...): the spawned goal must",
              "    %  carry the qualified local pid, not an unbound variable.",
              "    %  Otherwise a goal like self(S), S ! Pid-Result sends a message",
              "    %  whose pid slot is a fresh var, which receive/1's subsumes_term",
              "    %  matching cannot match against a caller that binds Pid (e.g.",
              "    %  parallel/1's par_yield) -- the receive defers it and hangs.",
              "    (   Node == localhost",
              "    ->  PidText := swiWasmActorReservePid(),",
              "        term_string(LocalPid, PidText),",
              "        Pid = LocalPid@localhost,",
              "        term_string(Goal, GoalText),",
              "        collect_spawn_source(Options, ExtraSource),",
              "        ( option(name(Name), Options) -> term_string(Name, NameText) ; NameText = \"\" ),",
              "        option(link(Link), Options, true),",
              "        term_string(Link, LinkText),",
              "        SpawnPromise := swiWasmActorSpawnWithPid(#PidText, #GoalText, #ExtraSource, #NameText, #LinkText),",
              "        await(SpawnPromise, SpawnedText),",
              "        ( SpawnedText = null -> throw(error(resource_error(swi_wasm_worker_actor), spawn/3)) ; term_string(SpawnedPid, SpawnedText), SpawnedPid == LocalPid )",
              "    ;   collect_remote_spawn_source(Goal, Options, ExtraSource),",
              "        term_string(Goal, GoalText),",
              "        term_string(Node, NodeText),",
              "        Promise := swiWasmActorRemoteSpawn(#NodeText, #GoalText, #ExtraSource),",
              "        await(Promise, RemotePidText),",
              "        term_string(Pid, RemotePidText)",
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
              "    Token := swiWasmWorkerScopeOpen(),",
              "    Scope = workers(Token, [], open, _),",
              "    call_cleanup(call(Goal), close_worker_scope(Scope)).",
              "",
              "spawn_scoped_worker(Scope, Goal, Pid) :-",
              "    arg(1, Scope, Token),",
              "    Reservation := swiWasmWorkerScopeReserve(#Token),",
              "    await(Reservation, PidText),",
              "    term_string(LocalPid, PidText), Pid = LocalPid@localhost,",
              "    arg(2, Scope, Pids), nb_setarg(2, Scope, [Pid|Pids]),",
              "    wire_text(Goal, GoalText),",
              "    Startup := swiWasmWorkerScopeSpawn(#Token, #PidText, #GoalText),",
              "    await(Startup, _).",
              "",
              "scoped_worker_ref(none, _, _) :- !.",
              "scoped_worker_ref(_, Pid, Ref) :- Ref == Pid.",
              "",
              "release_scoped_worker(none, _) :- !.",
              "release_scoped_worker(Scope, Pid) :-",
              "    arg(2, Scope, Pids), selectchk(Pid, Pids, Rest), nb_setarg(2, Scope, Rest),",
              "    arg(1, Scope, Token), term_string(Pid, PidText),",
              "    _ := swiWasmWorkerScopeRelease(#Token, #PidText).",
              "",
              "tidy_worker_scope(none, Pids) :- !, worker_tidy_all(Pids).",
              "tidy_worker_scope(Scope, _) :-",
              "    close_worker_scope(Scope), arg(4, Scope, Closed),",
              "    await(Closed, _).",
              "",
              "close_worker_scope(Scope) :-",
              "    ( arg(3, Scope, open)",
              "    -> nb_setarg(3, Scope, closing),",
              "       arg(1, Scope, Token), arg(2, Scope, Pids), assertz(closing_worker_scope(Token)),",
              "       forall(member(Pid, Pids),",
              "              (assertz(retiring_scope_worker(Token, Pid)), flush_scoped_worker_messages(Pid))),",
              "       Closed := swiWasmWorkerScopeClose(#Token), nb_linkarg(4, Scope, Closed)",
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
              "collect_spawn_source(Options, Source) :-",
              "    spawn_source_texts(Options, Texts),",
              "    atomic_list_concat(Texts, '\\n', Source).",
              "",
              "collect_remote_spawn_source(Goal, Options, Source) :-",
              "    collect_spawn_source(Options, Source0),",
              "    (   Source0 \\== ''",
              "    ->  Source = Source0",
              "    ;   strip_module(Goal, _, PlainGoal),",
              "        default_remote_spawn_source(PlainGoal, Source)",
              "    ->  true",
              "    ;   Source = ''",
              "    ).",
              "",
              "default_remote_spawn_source(echo_actor, \"echo_actor :-\\n    receive({\\n        echo(From, Msg) ->\\n            From ! echo(Msg),\\n            echo_actor\\n    }).\").",
              "",
              "spawn_source_texts(Options,Texts) :- spawn_source_texts(Options,Options,Texts).",
              "spawn_source_texts([], _, []).",
              "spawn_source_texts([Option|Options], All, Texts) :-",
              "    spawn_source_option(Option, Raw), !,",
              "    ( (Option=src_list(_);Option=src_predicates(_)) -> browser_materialized_source(All,Raw,Text) ; Text=Raw ),",
              "    spawn_source_texts(Options, All, Rest),",
              "    Texts = [Text|Rest].",
              "spawn_source_texts([_|Options], All, Texts) :- spawn_source_texts(Options, All, Texts).",
              "",
              "spawn_source_option(src_text(Text0), Text) :- browser_native_text(Text0,Text).",
              "spawn_source_option(src_list(Terms), Text) :-",
              "    findall(ClauseText, (member(Term, Terms), clause_source_text(Term, ClauseText)), ClauseTexts),",
              "    atomic_list_concat(ClauseTexts, '\\n', Text).",
              "spawn_source_option(src_predicates(Indicators), Text) :-",
              "    findall(ClauseText,",
              "            ( member(Name/Arity, Indicators),",
              "              functor(Head, Name, Arity),",
              "              catch(user:clause(Head, Body), _, fail),",
              "              (Body == true -> Clause = Head ; Clause = (Head :- Body)),",
              "              clause_source_text(Clause, ClauseText)",
              "            ),",
              "            ClauseTexts),",
              "    atomic_list_concat(ClauseTexts, '\\n', Text).",
              "spawn_source_option(src_uri(URI0), Text) :- browser_uri_atom(URI0, URI),",
              "    term_string(URI, URIText),",
              "    Promise := swiWasmLoadUriSource(#URIText),",
              "    await(Promise, Text).",
              "",
              "clause_source_text(Clause, Text) :-",
              "    copy_term(Clause, Copy),",
              "    numbervars(Copy, 0, _, [singletons(true)]),",
              "    with_output_to(string(Body), write_term(Copy, [quoted(true), numbervars(true)])),",
              "    string_concat(Body, '.', Text).",
              "",
              "install_spawn_monitor(Pid, Options) :-",
              "    option(monitor(true), Options, false),",
              "    !,",
              "    term_string(Pid, PidText),",
              "    Promise := swiWasmActorMonitor(#PidText, #PidText),",
              "    await(Promise, true).",
              "install_spawn_monitor(_, _).",
              "",
              "actors(Pids) :-",
              "    PidsText := swiWasmActorActors(),",
              "    term_string(Pids, PidsText).",
              "",
              "make_ref(Ref) :-",
              "    RefText := swiWasmActorMakeRef(),",
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
              "%  The chart is addressed as the pid `statechart`.  In the main",
              "%  engine the statechart_wasm module is loaded, so deliver the",
              "%  message straight into the chart's event queue.  Inside a spawned",
              "%  worker (which has no statechart_wasm module) route it back to the",
              "%  coordinator, which forwards it to the chart (routeSwiWasmActorMessage).",
              "send(statechart, Message) :-",
              "    !,",
              "    (   current_predicate(statechart_wasm:statechart_send/1)",
              "    ->  statechart_wasm:statechart_send(Message), sync_local_statechart_status",
              "    ;   send_worker_actor(statechart, Message)",
              "    ).",
              "",
              "send(statechart, Message, _) :-",
              "    !,",
              "    (   current_predicate(statechart_wasm:statechart_send/1)",
              "    ->  statechart_wasm:statechart_send(Message), sync_local_statechart_status",
              "    ;   send_worker_actor(statechart, Message)",
              "    ).",
              "",
              "send(Pid, Message) :- send_worker_actor(Pid, Message).",
              "",
              "send(Pid, Message, Options) :-",
              "    option(delay(Delay), Options),",
              "    !,",
              "    must_be_transportable_term(Message),",
              "    delayed_send_id(Options, Id),",
              "    term_string(Pid, PidText),",
              "    wire_text(Message, MessageText),",
              "    term_string(Id, IdText),",
              "    Sent := swiWasmActorSendDelayed(#PidText, #MessageText, #Delay, #IdText),",
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
              "    Cancelled := swiWasmActorCancel(#IdText),",
              "    Cancelled == true.",
              "",
              "send_worker_actor(Pid, Message) :-",
              "    must_be_transportable_term(Message),",
              "    term_string(Pid, PidText),",
              "    wire_text(Message, MessageText),",
              "    Promise := swiWasmActorSend(#PidText, #MessageText),",
              "    await(Promise, Sent),",
              "    (   Sent == true",
              "    ->  true",
              "    ;   throw(error(existence_error(actor, Pid), send/2))",
              "    ).",
              "",
              "monitor(Pid, Ref) :- make_ref(Ref), install_monitor(Pid, Ref).",
              "",
              "install_monitor(Pid, Ref) :-",
              "    term_string(Pid, PidText),",
              "    term_string(Ref, RefText),",
              "    Promise := swiWasmActorMonitor(#PidText, #RefText),",
              "    await(Promise, Monitored),",
              "    Monitored == true.",
              "",
              "demonitor(Ref) :- demonitor(Ref, []).",
              "",
              "demonitor(Ref, Options) :-",
              "    term_string(Ref, RefText),",
              "    Promise := swiWasmActorDemonitor(#RefText),",
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
              "exit(Reason) :- exit(main, Reason).",
              "",
              "exit(Pid, Reason) :-",
              "    term_string(Pid, PidText),",
              "    term_string(Reason, ReasonText),",
              "    Promise := swiWasmActorExit(#PidText, #ReasonText),",
              "    await(Promise, Exited),",
              "    Exited == true.",
              "",
              "register(Name, Pid) :- register_name(actor, Name, Pid).",
              "register_service(Name, Pid) :- register_name(service, Name, Pid).",
              "",
              "register_name(Kind, Name, Pid) :-",
              "    term_string(Name, NameText),",
              "    term_string(Pid, PidText),",
              "    Registered := swiWasmActorRegister(#Kind, #NameText, #PidText),",
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
              "    _ := swiWasmActorUnregister(#Kind, #NameText).",
              "",
              "whereis(Name, Pid) :- whereis_name(actor, Name, Pid).",
              "whereis_service(Name, Pid) :- whereis_name(service, Name, Pid).",
              "",
              "whereis_name(Kind, Name, Pid) :-",
              "    term_string(Name, NameText),",
              "    PidText := swiWasmActorWhereis(#Kind, #NameText),",
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
              "    collect_spawn_source(Options, ExtraSource),",
              "    option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
              "    option(time_limit(TimeLimit0), Options, infinite),",
              "    option(idle_limit(IdleLimit0), Options, infinite),",
              "    normalize_ptcp_limit(time_limit, TimeLimit0, TimeLimit),",
              "    normalize_ptcp_limit(idle_limit, IdleLimit0, IdleLimit),",
              "    (   Node == localhost",
              "    ->  self(Self),",
              "        option(session(Session), Options, false),",
              "        option(target(Target), Options, Self),",
              "        PidText := swiWasmActorReservePid(),",
              "        term_string(LocalPid, PidText),",
              "        Pid = LocalPid@localhost,",
              "        Lifecycle = ptcp_options(Session, TimeLimit, IdleLimit),",
              "        term_string(swi_wasm_actor_bridge:ptcp(Pid, Target, Lifecycle), GoalText),",
              "        SpawnPromise := swiWasmActorSpawnWithPid(#PidText, #GoalText, #ExtraSource),",
              "        await(SpawnPromise, SpawnedText),",
              "        ( SpawnedText = null -> throw(error(resource_error(swi_wasm_worker_actor), toplevel_spawn/2)) ; term_string(SpawnedPid, SpawnedText), SpawnedPid == LocalPid )",
              "    ;   term_string(Node, NodeText),",
              "        option(session(Session), Options, true),",
              "        term_string(Session, SessionText),",
              "        term_string(TimeLimit, TimeLimitText),",
              "        term_string(IdleLimit, IdleLimitText),",
              "        Promise := swiWasmRemoteToplevelSpawn(#NodeText, #ExtraSource, #SessionText, #TimeLimitText, #IdleLimitText),",
              "        await(Promise, RemotePidText),",
              "        term_string(Pid, RemotePidText)",
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
              "ptcp(Pid, Target, Session) :-",
              "    catch(state_1(Pid, Target, Session), '$abort_goal', ptcp(Pid, Target, Session)).",
              "",
              "state_1(Pid, Target0, Session) :-",
              "    receive({",
              "        '$call'(Goal, Options) ->",
              "            option(template(Template0), Options, Goal),",
              "            strip_module(Template0, _, Template),",
              "            option(offset(Offset), Options, 0),",
              "            ( option(limit(N), Options) -> must_be(positive_integer, N), Limit = count(N) ; Limit = all ),",
              "            option(once(Once), Options, false),",
              "            option(target(Target1), Options, Target0),",
              "            option('$request_ref'(RequestRef), Options, none), Target = target(Target1,RequestRef),",
              "            state_2(Goal, Template, Offset, Limit, Once, Target, Pid, Answer),",
              "            send_toplevel_answer(Target, Answer),",
              "            (   arg(3, Answer, true)",
              "            ->  state_3(Limit, Target)",
              "            ;   true",
              "            )",
              "        }),",
              "    (   Session == false",
              "    ->  true",
              "    ;   state_1(Pid, Target0, Session)",
              "    ).",
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
      "            ptcp_next_ref(Options2, Target),",
              "            (   option(limit(NewLimit), Options2)",
              "            ->  must_be(positive_integer, NewLimit), nb_setarg(1, Limit, NewLimit)",
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
              "    ->  normalize_resource_error(Error, PublicError), Answer = error(PublicError)",
              "    ;   var(Det)",
              "    ->  Answer = success(Slice, true)",
              "    ;   Det == true",
              "    ->  Answer = success(Slice, false)",
              "    ).",
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
              "apply_once_answer(_, Answer, Answer).",
              "",
              "add_pid(success(Slice, More), Pid, success(Pid, Slice, More)).",
              "add_pid(failure, Pid, failure(Pid)).",
              "add_pid(error(Term), Pid, error(Pid, Term)).",
              "",
              "solution_limit(Options, Limit) :- ( option(limit(Limit), Options) -> must_be(positive_integer, Limit) ; Limit = none ).",
              "validate_solution_limit(Options) :- solution_limit(Options, _).",
              "validate_once_options(Options) :- must_be(list, Options), forall((member(Option, Options), nonvar(Option), Option = once(Value)), must_be(boolean, Value)).",
              "toplevel_call(Pid, Goal) :- toplevel_call(Pid, Goal, []).",
              "toplevel_call(Pid, Goal, Options) :- validate_once_options(Options), validate_solution_limit(Options),",
              "    term_string(Pid, PidText),",
              "    (   remote_toplevel_pid_text(PidText)",
              "    ->  term_string(Goal, GoalText),",
              "        option(template(Template0), Options, Goal),",
              "        strip_module(Template0, _, Template), term_string(Template, TemplateText),",
              "        solution_limit(Options, Limit), option(offset(Offset), Options, 0), option(once(Once), Options, false),",
              "        Promise := swiWasmRemoteToplevelCall(#PidText, #GoalText, #TemplateText, #Limit, #Offset, #Once),",
              "        await(Promise, true)",
              "    ;   send(Pid, '$call'(Goal, Options))",
              "    ).",
              "synchronous_remote_support(Node, Supported) :-",
              "    term_string(Node, NodeText), Promise := swiWasmToplevelCorrelation(#NodeText), await(Promise, Supported).",
              "synchronous_send(Pid, Message) :-",
              "    term_string(Pid, PidText), term_string(Message, MessageText),",
              "    Promise := swiWasmSynchronousSend(#PidText, #MessageText), await(Promise, Sent),",
              "    ( Sent == true -> true ; Pid = _@Node, throw(error(permission_error(use,toplevel_correlation,Node),_)) ).",
              "remote_toplevel_pid_text(Text) :-",
              "    ( sub_string(Text, 0, _, _, \"remote_toplevel(\")",
              "    ; sub_string(Text, _, _, _, \"@'\")",
              "    ).",
              "",
              "toplevel_next(Pid) :- toplevel_next(Pid, []).",
              "toplevel_next(Pid, Options) :- validate_solution_limit(Options),",
              "    term_string(Pid, PidText),",
              "    (   remote_toplevel_pid_text(PidText)",
              "    ->  ( option(limit(Limit), Options) -> term_string(Limit, LimitText) ; LimitText = \"default\" ),",
              "        Promise := swiWasmRemoteToplevelNext(#PidText, #LimitText),",
              "        await(Promise, true)",
              "    ;   send(Pid, '$next'(Options))",
              "    ).",
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
              "    Aborted := swiWasmActorAbort(#PidText),",
              "    Aborted == true.",
              "",
              "statechart_spawn(Pid, Options) :-",
              "    validate_browser_wrapper_options(statechart, statechart_spawn/2, Options),",
              "    browser_named_creation(Options, Pid, statechart_spawn/2, Inner, browser_statechart_spawn_options(Pid, Inner)).",
              "browser_statechart_spawn_options(Pid, Options) :-",
              "    statechart_spawn_source(Options, SourceKind, Source),",
              "    validate_statechart_text_source(SourceKind, Source),",
              "    collect_statechart_support_source(Options, SupportSource),",
              "    option(trace(Trace), Options, true), term_string(Trace, TraceText),",
              "    option(node(Node0), Options, localhost), browser_uri_atom(Node0, Node),",
              "    (   Node \\== localhost",
              "    ->  statechart_remote_goal(SourceKind, Source, Trace, Options, Goal),",
              "        term_string(Goal, GoalText), term_string(Node, NodeText),",
              "        Promise := swiWasmActorRemoteSpawn(#NodeText, #GoalText, #SupportSource),",
              "        await(Promise, PidText), term_string(Pid, PidText),",
              "        maybe_register_toplevel_name(Options, Pid),",
              "        install_spawn_monitor(Pid, Options)",
              "    ;   statechart_wasm:statechart_running",
              "    ->  ( option(name(Name), Options) -> term_string(Name, NameText) ; NameText = \"\" ),",
              "        option(link(Link), Options, true), term_string(Link, LinkText),",
              "        ( option(io_target(IoTarget), Options) -> term_string(IoTarget, IoTargetText) ; IoTargetText = \"\" ),",
              "        Promise := swiWasmStatechartSpawnWorker(#SourceKind, #Source, #SupportSource, #NameText, #LinkText, #IoTargetText, #TraceText),",
              "        await(Promise, ResultText), statechart_spawn_worker_result(ResultText, Pid),",
              "        install_spawn_monitor(Pid, Options)",
              "    ;   statechart_local_xml(SourceKind, Source, XML),",
              "        configure_statechart_io_target(Options),",
              "        statechart_wasm:set_trace_enabled(Trace),",
              "        statechart_wasm:statechart_start(text(XML), SupportSource),",
              "        Pid = statechart,",
              "        (statechart_wasm:statechart_running -> ChartLive = true ; ChartLive = false),",
              "        _ := swiWasmNamedChartStarted(#ChartLive),",
              "        install_spawn_monitor(Pid, Options),",
              "        maybe_register_toplevel_name(Options, Pid)",
              "    ).",
              "",
              "validate_statechart_text_source(text, XML) :-",
              "    !,",
              "    sxml_schema:sxml_validate_text(XML, Diagnostics),",
              "    (   Diagnostics == []",
              "    ->  true",
              "    ;   throw(error(sxml_validation_error(Diagnostics), context(statechart_spawn/2, 'the document does not conform to the SXML 0.2 grammar')))",
              "    ).",
              "validate_statechart_text_source(_, _).",
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
              "sync_local_statechart_status :-",
              "    (statechart_wasm:statechart_running -> Live = true ; Live = false),",
              "    _ := swiWasmSyncChartStatus(#Live).",
              "",
              "statechart_halt(Pid, Reply) :- statechart_halt(Pid, Reply, 5).",
              "statechart_halt(statechart, Reply, _Timeout) :-",
              "    !,",
              "    statechart_wasm:statechart_stop,",
              "    _ := swiWasmNamedChartStopped(),",
              "    Reply = stopped.",
              "statechart_halt(Pid, _, _) :-",
              "    throw(error(existence_error(statechart, Pid), statechart_halt/3)).",
              "",
              "statechart_spawn_source(Options, text, XML) :-",
              "    member(src_text(XML0), Options), browser_source_text(XML0,XML),",
              "    !.",
              "statechart_spawn_source(Options, uri, URI) :-",
              "    member(src_uri(URI0), Options), browser_uri_atom(URI0, URI),",
              "    !.",
              "statechart_spawn_source(_, _, _) :-",
              "    throw(error(domain_error(statechart_source_option, src_text_or_src_uri), statechart_spawn/2)).",
              "",
              "statechart_local_xml(text, XML, XML).",
              "statechart_local_xml(uri, URI, XML) :-",
              "    URIText := swiResolveAssetUrl(#URI),",
              "    XML := swiRpcGet(#URIText),",
              "    (   XML = null",
              "    ->  throw(error(existence_error(source_sink, URI), statechart_spawn/2))",
              "    ;   true",
              "    ).",
              "",
              "statechart_remote_goal(text, Source, Trace, Options, Goal) :-",
              "    statechart_remote_goal_io(statechart_actor:interpret_text_trace(Trace, Source), Options, Goal).",
              "statechart_remote_goal(uri, Source, Trace, Options, Goal) :-",
              "    statechart_remote_goal_io(statechart_actor:interpret_trace(Trace, Source), Options, Goal).",
              "statechart_remote_goal_io(Goal0, Options, Goal) :-",
              "    ( option(io_target(Target), Options) -> Goal = actors:with_io_target(Target, Goal0) ; Goal = Goal0 ).",
              "",
              "configure_statechart_io_target(Options) :-",
              "    retractall(io_target(_)),",
              "    ( option(io_target(Target), Options) -> assertz(io_target(Target)) ; true ).",
              "",
              "collect_statechart_support_source(Options, Source) :-",
              "    findall(Text, (member(Option, Options), statechart_support_source_option(Option, Raw), browser_materialized_source(Options,Raw,Text)), Texts),",
              "    atomic_list_concat(Texts, '\\n', Source).",
              "statechart_support_source_option(src_list(Terms), Text) :- spawn_source_option(src_list(Terms), Text).",
              "statechart_support_source_option(src_predicates(Indicators), Text) :- statechart_predicates_source(Indicators, Text).",
              "statechart_predicates_source(Indicators, Text) :-",
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
              "    _ := swiWasmActorTerminalOutput(#Text, #TermText).",
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
              "        Promise := swiWasmActorInput(#PromptText),",
              "        await(Promise, AnswerText),",
              "        AnswerText \\== null,",
              "        language_read(AnswerText, Answer)",
              "    ).",
              "",
              "%  Async inline-terminal reader, called by the user-module read/1",
              "%  shim (consulted with the user program).  Yields for a line via",
              "%  swiWasmActorInput (the inline terminal prompt), then parses it as",
              "%  a term.  read/1 itself must be redefined in `user`, not here: the",
              "%  bridge-module copy cannot override the built-in for user calls.",
              "swi_wasm_read_term(Term) :-",
              "    PromptText = \"|: \",",
              "    Promise := swiWasmActorInput(#PromptText),",
              "    await(Promise, Line),",
              "    swi_wasm_read_line_term(Line, Term).",
              "swi_wasm_read_line_term(Line, end_of_file) :- ( Line == null ; Line == \"\" ), !.",
              "swi_wasm_read_line_term(Line, Term) :-",
              "    ( string_concat(Body, \".\", Line) -> true ; Body = Line ),",
              "    language_read(Body, Term).",
              "",
              "%  Lazy solution driver for the inline terminal.  Prolog.forEach is",
              "%  the only SWI-WASM query API that lets the goal yield (await) for",
              "%  input/2, sleep/1 and rpc/3, but it drives backtracking to",
              "%  exhaustion -- so every solution's side effects (e.g. an",
              "%  interactive meta-interpreter's input/2 prompts) would run before",
              "%  the first answer is shown.  swi_wasm_drive/1 makes the goal pause",
              "%  between solutions on an awaited JS promise (swiWasmAwaitMore),",
              "%  resumed only when the user asks for the next answer with ';' --",
              "%  matching the lazy node toplevel.  deterministic/1 is read right",
              "%  after the goal so the final, choicepoint-free solution prints '.'",
              "%  instead of ' ; false'.",
              "swi_wasm_drive(Goal) :-",
              "    setup_call_cleanup(true, swi_wasm_drive_goal(Goal), swi_wasm_flush_output).",
              "swi_wasm_drive_goal(Goal) :-",
              "    catch(call(Goal), Error, swi_wasm_query_exception(Error)),",
              "    deterministic(Det),",
              "    swi_wasm_flush_output,",
              "    swi_wasm_note_det(Det),",
              "    swi_wasm_more_gate(Det).",
              "",
              "% Flush Prolog buffers before JS presents results. Cleanup also covers",
              "% failure/cut/interruption; a flush error must not replace the query error.",
              "swi_wasm_flush_output :-",
              "    catch(flush_output(user_output), _, true),",
              "    catch(flush_output(user_error), _, true).",
              "swi_wasm_query_exception(Error) :-",
              "    swi_wasm_flush_output,",
              "    term_to_atom(Error, Text),",
              "    _ := swiWasmNoteException(#Text),",
              "    throw(Error).",
              "",
              "swi_wasm_more_gate(true) :- !.",
              "swi_wasm_more_gate(false).",
              "swi_wasm_more_gate(false) :- swi_wasm_await_more, fail.",
              "",
              "swi_wasm_note_det(true)  :- _ := swiWasmNoteDet(#\"true\").",
              "swi_wasm_note_det(false) :- _ := swiWasmNoteDet(#\"false\").",
              "",
              "swi_wasm_await_more :-",
              "    Promise := swiWasmAwaitMore(),",
              "    await(Promise, _).",
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
              "             term_string(Ref, RefText), _ := swiWasmServerMonitorCleanup(#RefText)), _, true) ).",
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
              "    Promise := swiWasmActorReceive(#Timeout),",
              "    await(Promise, MessageText),",
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
              "%  record is erased only when a clause is selected, so a control",
              "%  exception escaping from a guard leaves it in the mailbox.  Ordinary",
              "%  guard exceptions are non-matches (Semantic Contracts D2).",
              "guard_exception(E) :- control_exception(E), !, throw(E).",
              "guard_exception(_) :- fail.",
              "control_exception(E) :- var(E), !, fail.",
              "control_exception('$abort_goal').",
              "control_exception('$ptcp_time_limit').",
              "control_exception('$aborted').",
              "control_exception(unwind(_)).",
              "",
              "%  Canonical term text (Semantic Contracts D5), as in the native node's",
              "%  wire_text.pl: quoted, operator-independent, no portray hooks, no",
              "%  numbervars, explicit variable names; read with double_quotes=string.",
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
              "    ).",
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
              "rpc(URL, Goal) :- rpc(URL, Goal, []).",
              "",
              "rpc(URL0, Goal, Opts) :-",
              "    validate_rpc_client_options(rpc, Opts), browser_rpc_uri(URL0, URL),",
              "    term_variables(Goal, Vars),",
              "    Template =.. [v|Vars],",
              "    wire_texts([Goal, Template], [GoalAtom, TplAtom]),",
              "    solution_limit(Opts, Lim),",
              "    web_rpc_base_url(URL, Opts, BaseRPCURL),",
              "    collect_rpc_load(Opts, Parts),",
              "    Offset = 0,",
              "    rpc_transport_options(Opts, RemoteTimeout, Once, HTTPTimeout),",
              "    web_rpc_page(Template, Offset, Lim, BaseRPCURL, GoalAtom, TplAtom, Parts, RemoteTimeout, Once, HTTPTimeout).",
              "",
              "web_rpc_page(Template, Offset, Lim, BaseRPCURL, GoalAtom, TplAtom, Parts, RemoteTimeout, Once, HTTPTimeout) :-",
              "    web_rpc_call_url(BaseRPCURL, GoalAtom, TplAtom, Offset, Lim, Parts, RemoteTimeout, Once, FinalURL),",
              "    Promise := swiRpcGetAsync(#FinalURL, #HTTPTimeout),",
              "    await(Promise, Resp),",
              "    (Resp = null -> throw(rpc_error(fetch_failed)) ; true),",
              "    (   catch(wire_read(Resp, Response), _, fail)",
              "    ->  true",
              "    ;   throw(rpc_error(parse_failed))",
              "    ),",
              "    (   Response = success(Slice, true)",
              "    ->  (   member(Bound, Slice), Template = Bound",
              "        ;   Once == false,",
              "            length(Slice, Count), NewOffset is Offset + Count,",
              "            web_rpc_page(Template, NewOffset, Lim, BaseRPCURL, GoalAtom, TplAtom, Parts, RemoteTimeout, Once, HTTPTimeout)",
              "        )",
              "    ;   Response = success(Slice, false)",
              "    ->  member(Bound, Slice), Template = Bound",
              "    ;   Response = failure",
              "    ->  fail",
              "    ;   Response = error(Err)",
              "    ->  throw(Err)",
              "    ;   throw(rpc_error(unexpected_response))",
              "    ).",
              "",
              "web_rpc_call_url(BaseRPCURL, GoalAtom, TplAtom, Offset, Lim, Parts, RemoteTimeout, Once, FinalURL) :-",
              "    GoalEnc := encodeURIComponent(#GoalAtom),",
              "    TplEnc  := encodeURIComponent(#TplAtom),",
              "    atomic_list_concat([BaseRPCURL,'/call?goal=(',GoalEnc,')&template=',TplEnc,",
              "                        '&format=prolog&offset=',Offset], NoLimitURL),",
              "    rpc_url_option(NoLimitURL, limit, Lim, BaseURL),",
              "    rpc_url_option(BaseURL, timeout, RemoteTimeout, TimeoutURL),",
              "    rpc_url_option(TimeoutURL, once, Once, OptionURL),",
              "    (   Parts = []",
              "    ->  FinalURL = OptionURL",
              "    ;   atomic_list_concat(Parts, '\\n', LoadText),",
              "        LtEnc := encodeURIComponent(#LoadText),",
              "        atomic_list_concat([OptionURL,'&src_text=',LtEnc], FinalURL)",
              "    ).",
              "",
              "promise(URL, Goal, Ref) :- promise(URL, Goal, Ref, []).",
              "",
              "promise(URL0, Goal, Ref, Opts) :-",
              "    validate_rpc_client_options(promise, Opts), browser_rpc_uri(URL0, URL),",
              "    (member(template(Template), Opts) -> true ; Template = Goal),",
              "    (member(offset(Offset), Opts) -> true ; Offset = 0),",
              "    solution_limit(Opts, Lim),",
              "    rpc_transport_options(Opts, RemoteTimeout, Once, HTTPTimeout),",
              "    web_rpc_url(URL, Goal, Template, Offset, Lim, Opts, RemoteTimeout, Once, FinalURL),",
              "    RefText := swiPromiseStart(#FinalURL, #HTTPTimeout),",
              "    atom_number(RefText, Ref).",
              "",
              "promise_cleanup(Ref) :-",
              "    must_be(integer, Ref), number_string(Ref, RefText), _ := swiPromiseCleanup(#RefText).",
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
              "      ( Claim := swiPromiseClaim(#RefText),",
              "        ( Claim == missing_promise -> throw(error(existence_error(promise, Ref), context(yield/3, 'unknown, consumed or expired promise')))",
              "        ; Claim == busy_promise -> throw(error(permission_error(collect,promise,Ref), context(yield/3, 'promise already has a collector')))",
              "        ; true ) ),",
              "      ( Promise := swiPromiseWait(#RefText, #Claim, #Timeout),",
              "        await(Promise, ResponseText),",
              "        ( ResponseText == null -> true ; ResponseText == \"missing_promise\" -> true",
              "        ; Status := swiPromiseCommit(#RefText, #Claim),",
              "          ( Status == committed -> true",
              "          ; throw(error(existence_error(promise, Ref), context(yield/3, 'promise disposed before collection'))) ) ) ),",
              "      (_ := swiPromiseRelease(#RefText, #Claim))),",
              "    (   ResponseText == \"missing_promise\"",
              "    ->  throw(error(existence_error(promise, Ref), context(yield/3, 'unknown or consumed promise')))",
              "    ;   ResponseText = null",
              "    ->  option(on_timeout(OnTimeout), Options, true),",
              "        ( once(call(Caller:OnTimeout))",
              "        -> (var(Message) -> Message = timeout ; true)",
              "        ; throw(error(timeout_callback_failed(Ref), context(yield/3, 'on_timeout goal failed'))) )",
              "    ;   web_parse_rpc_response(ResponseText, Message)",
              "    ).",
              "",
              "web_rpc_url(URL, Goal, Template, Offset, Lim, Opts, RemoteTimeout, Once, FinalURL) :-",
              "    wire_texts([Goal, Template], [GoalAtom, TplAtom]),",
              "    web_rpc_base_url(URL, Opts, BaseRPCURL),",
              "    GoalEnc := encodeURIComponent(#GoalAtom),",
              "    TplEnc  := encodeURIComponent(#TplAtom),",
              "    atomic_list_concat([BaseRPCURL,'/call?goal=(',GoalEnc,')&template=',TplEnc,",
              "                        '&format=prolog&offset=',Offset], NoLimitURL),",
              "    rpc_url_option(NoLimitURL, limit, Lim, BaseURL),",
              "    collect_rpc_load(Opts, Parts),",
              "    rpc_url_option(BaseURL, timeout, RemoteTimeout, TimeoutURL),",
              "    rpc_url_option(TimeoutURL, once, Once, OptionURL),",
              "    (   Parts = []",
              "    ->  FinalURL = OptionURL",
              "    ;   atomic_list_concat(Parts, '\\n', LoadText),",
              "        LtEnc := encodeURIComponent(#LoadText),",
              "        atomic_list_concat([OptionURL,'&src_text=',LtEnc], FinalURL)",
              "    ).",
              "",
              "rpc_transport_options(Opts, RemoteTimeout, Once, HTTPTimeout) :-",
              "    (member(timeout(RemoteTimeout0), Opts) -> normalize_optional_timeout(RemoteTimeout0, RemoteTimeout) ; RemoteTimeout = -1),",
              "    (member(once(Once0), Opts) -> normalize_boolean(Once0, Once) ; Once = false),",
              "    (member(http_timeout(HTTPTimeout0), Opts) -> normalize_optional_timeout(HTTPTimeout0, HTTPTimeout) ; HTTPTimeout = -1).",
              "",
              "normalize_optional_timeout(Value, Timeout) :- must_be(number, Value), Timeout is max(0, Value).",
              "normalize_boolean(true, true) :- !.",
              "normalize_boolean(false, false) :- !.",
              "normalize_boolean(Value, _) :- throw(error(domain_error(boolean, Value), rpc/3)).",
              "",
              "rpc_url_option(URL, limit, none, URL) :- !.",
              "rpc_url_option(URL, _, -1, URL) :- !.",
              "rpc_url_option(URL, once, false, URL) :- !.",
              "rpc_url_option(URL, Key, Value, FinalURL) :-",
              "    atomic_list_concat([URL,'&',Key,'=',Value], FinalURL).",
              "",
              "web_rpc_base_url(URL, Opts, BaseRPCURL) :-",
              "    BaseRPCURL := swiResolveRpcBase(#URL).",
              "",
              "web_parse_rpc_response(Resp, Message) :-",
              "    (   catch(wire_read(Resp, Message), _, fail)",
              "    ->  true",
              "    ;   throw(rpc_error(parse_failed))",
              "    ).",
              "",
              "collect_rpc_load(Opts, Parts) :-",
              "    findall(Part, rpc_load_part(Opts, Part), Parts).",
              "",
              "rpc_load_part(Opts, Text) :-",
              "    member(src_text(T), Opts),",
              "    browser_native_text(T,S),",
              "    Text := swiEnsureFinalFullStop(#S).",
              "",
              "rpc_load_part(Opts, Text) :-",
              "    member(src_list(Terms), Opts),",
              "    maplist([Term,A]>>(term_to_atom(Term,TA),atom_concat(TA,'.',A)), Terms, Atoms),",
              "    atomic_list_concat(Atoms,'\\n',Text).",
              "",
              "rpc_load_part(Opts, Text) :-",
              "    member(src_uri(URI0), Opts), browser_uri_atom(URI0, URI),",
              "    term_string(URI, URIText),",
              "    ResolvedURI := swiResolveRpcLoadUri(#URIText),",
              "    Text := swiRpcGet(#ResolvedURI),",
              "    (Text = null -> throw(rpc_error(fetch_failed)) ; true).",
              "",
              "rpc_load_part(Opts, Text) :-",
              "    member(src_predicates(Inds), Opts),",
              "    findall(CT, (member(N/A, Inds), rpc_clause_text(N,A,CT)), CTs),",
              "    atomic_list_concat(CTs,'\\n',Text).",
              "",
              "rpc_clause_text(Name, Arity, Text) :-",
              "    functor(Head, Name, Arity),",
              "    catch(user:clause(Head, Body), _, fail),",
              "    (Body == true",
              "    ->  term_to_atom(Head, HA), atom_concat(HA, '.', Text)",
              "    ;   term_to_atom(Head, HA), term_to_atom(Body, BA),",
              "        atomic_list_concat([HA,' :-\\n    ',BA,'.'], Text)",
              "    )."
            ].concat(this.swiWasmBehaviourProlog().split("\n")).join("\n");
          },
          preloadSwiWasmStatechart: function(Prolog, Module) {
            var self = this;
            if (self.swiWasmStatechartLoaded) {
              return Promise.resolve(true);
            }
            if (!Module || !Module.FS) {
              self.swiWasmStatechartLoadError = "SWI-WASM virtual filesystem not ready";
              return Promise.resolve(false);
            }
            var names = [
              "sxml_schema.pl",
              "statechart_wasm_runtime.pl",
              "statechart_wasm_model.pl",
              "statechart_wasm_exec.pl",
              "statechart_wasm.pl"
            ];
            try { Module.FS.mkdir("/wasm"); } catch(_) { /* exists */ }
            return Promise.all(names.map(function(name) {
              // cache: 'no-store' so a rebuilt node always reaches the
              // browser; statechart_wasm modules embed their own build
              // tag in directives that run at consult time, so a stale
              // copy silently breaks subtle things like sleep/1.
              return fetch((self.swiWasmAssets ? self.swiWasmAssets.prologBaseUrl : "/wasm/") + name, { cache: "no-store" }).then(function(r) {
                if (!r.ok) throw new Error("HTTP " + r.status + " for /wasm/" + name);
                return r.text().then(function(src) { return { name: name, src: src }; });
              });
            })).then(function(files) {
              files.forEach(function(f) {
                Module.FS.writeFile("/wasm/" + f.name, f.src);
              });
              //  Load the actor bridge into the main engine so charts can
              //  spawn worker actors/toplevels through <spawn> (invoke/1) and
              //  chart scripts can drive them (Pid ! Msg, toplevel_call, ...).
              //  Harmless if a prior query already consulted it -- consult/1
              //  just reloads the swi_wasm_actor_bridge module.
              try {
                Module.FS.writeFile("/swi_wasm_actor_bridge.pl", self.swiWasmRpcProlog());
                Prolog.query("consult('/swi_wasm_actor_bridge.pl')").once();
              } catch(e) {
                console.warn("[SWI-INIT] statechart actor bridge consult threw:", e);
              }
              var consultOk = false;
              try {
                consultOk = !!Prolog.query("use_module('/wasm/statechart_wasm.pl')").once();
              } catch(e) {
                console.warn("[SWI-INIT] statechart_wasm consult threw:", e);
              }
              if (!consultOk) {
                throw new Error("use_module('/wasm/statechart_wasm.pl') failed");
              }
              // Expose a JS-side trace receiver so the in-browser
              // Prolog can stream statechart events back to the Vue
              // app via library(wasm)'s :=/2.
              window.wasmStatechartTrace = function(text) {
                try { self.handleSwiWasmTrace(text); } catch(e) {
                  console.warn("[SWI-WASM] trace dispatch threw:", e);
                }
              };
              window.wasmStatechartDelayedEvents = {};
              window.wasmStatechartSchedule = function(eventText, delaySeconds, idText) {
                var id = String(idText || "");
                var delay = Number(delaySeconds);
                if (!id || !isFinite(delay) || delay < 0) {
                  return false;
                }
                window.wasmStatechartCancel(id);
                window.wasmStatechartDelayedEvents[id] = window.setTimeout(function() {
                  delete window.wasmStatechartDelayedEvents[id];
                  self.enqueueSwiWasmStatechartEvent(String(eventText || "timeout"));
                }, delay * 1000);
                return true;
              };
              window.wasmStatechartCancel = function(idText) {
                var id = String(idText || "");
                var timer = window.wasmStatechartDelayedEvents[id];
                if (timer === undefined) {
                  return true;
                }
                window.clearTimeout(timer);
                delete window.wasmStatechartDelayedEvents[id];
                return true;
              };
              window.wasmStatechartCancelAll = function() {
                Object.keys(window.wasmStatechartDelayedEvents).forEach(function(id) {
                  window.clearTimeout(window.wasmStatechartDelayedEvents[id]);
                });
                window.wasmStatechartDelayedEvents = {};
                return true;
              };
              // No JS-side sleep wiring needed: library(wasm)
              // exports a sleep/1 that yields via promise_sleep +
              // await when the Prolog engine is in async context.
              // Importing library(wasm) into statechart_wasm makes
              // that visible as statechart_wasm:sleep/1.
              // Install the Prolog trace hook that bridges every
              // statechart event to the JS callback.  term_to_atom/2
              // gives us the canonical Prolog-term text that
              // humanizeStatechartTrace knows how to parse.
              var hookOk = false;
              try {
                hookOk = !!Prolog.query(
                  "statechart_wasm:set_trace_hook(" +
                  "[E]>>(term_to_atom(E, A), _ := wasmStatechartTrace(#A)))"
                ).once();
              } catch(e) {
                console.warn("[SWI-INIT] set_trace_hook threw:", e);
              }
              if (!hookOk) {
                throw new Error("set_trace_hook/1 failed");
              }
              self.swiWasmStatechartLoaded = true;
              self.swiWasmStatechartLoadError = "";
              return true;
            }).catch(function(err) {
              self.swiWasmStatechartLoadError = String(err);
              console.warn("[SWI-INIT] statechart_wasm preload failed:", err);
              self.log("warn", "Statechart WASM modules unavailable: " + String(err), "swi-wasm");
              return false;
            });
          },
          acceptSwiWasmRemoteIo: function(socket, message) {
            var status = "error";
            try {
              var event = message.event;
              if (event && event.type === "output" && typeof this.emitSwiWasmOutput === "function") {
                status = this.emitSwiWasmOutput(event.data, event.kind, "remote") === false ? "error" : "ok";
              }
            } finally {
              // Both remote connections render through this terminal. Only
              // then may the writer continue and send its next actor message.
              socket.send(JSON.stringify({ command: "browser_io_reply",
                request_id: message.request_id, status: status }));
            }
          },
          prologQuotedText: function(text) {
            return "'" + String(text == null ? "" : text)
              .replace(/\\/g, "\\\\")
              .replace(/\r/g, "\\r")
              .replace(/\n/g, "\\n")
              .replace(/\t/g, "\\t")
              .replace(/'/g, "''") + "'";
          },
          toplevelSpawnOptionsText: function(sourceText, session, lifecycle) {
            var options = [];
            if (session !== false) {
              options.push("session(true)");
            }
            if (String(sourceText || "") !== "") {
              options.push("src_text(" + this.prologQuotedText(sourceText) + ")");
            }
            if (lifecycle && String(lifecycle.timeLimit || "infinite") !== "infinite") {
              options.push("time_limit(" + Number(lifecycle.timeLimit) + ")");
            }
            if (lifecycle && String(lifecycle.idleLimit || "infinite") !== "infinite") {
              options.push("idle_limit(" + Number(lifecycle.idleLimit) + ")");
            }
            return "[" + options.join(",") + "]";
          },
          toplevelCallOptionsText: function(options) {
            var value = options || {};
            var terms = [];
            if (value.template !== undefined) {
              terms.push("template(" + String(value.template) + ")");
            }
            if (value.offset !== undefined) {
              terms.push("offset(" + Number(value.offset) + ")");
            }
            if (value.limit !== undefined) {
              terms.push("limit(" + Number(value.limit) + ")");
            }
            if (value.once !== undefined) {
              terms.push("once(" + (value.once === true || value.once === "true" ? "true" : "false") + ")");
            }
            if (value.format !== undefined) terms.push("format(" + String(value.format) + ")");
            return "[" + terms.join(",") + "]";
          },
  };

  function createState() { return {
            swiWasmAssets: null,
            swiWasm2ShellPid: "",
            swiWasm2ShellReady: false,
            swiWasm2QueryPending: false,
            swiWasm2LoadedSource: null,
            swiWasmProlog: null,
            swiWasmModule: null,
            swiWasmOutputBuffer: "",
            //  Lazy paging state (see swi_wasm_drive/1 and runSwiWasmQuery).
            swiWasmMorePending: null,
            swiWasmMoreRequested: false,
            swiWasmLastDet: "false",
            swiWasmQueryException: null,
            swiWasmFinalized: false,
            swiWasmPagingStopped: false,
            swiWasmActorWorkers: {},
            swiWasmReservedWorkerActorPids: {},
            swiWasmReservedActorRefs: {},
            swiWasmNextActorDelayId: 1,
            swiWasmActorMainMailbox: [],
            swiWasmActorMainWaiters: [],
            swiWasmActorNames: {},
            swiWasmActorServices: {},
            swiWasmActorMonitors: [],
            swiWasmActorDelayedSends: {},
            swiWasmRemoteActorConnections: {},
            swiWasmRemoteActorKinds: {},
            swiWasmActorInputQueue: [],
            swiWasmActorInputActive: null,
            swiWasmInputSaved: null,
            swiWasmStatechartLoaded: false,
            swiWasmStatechartLoadError: "",
            swiWasmStatechartActive: false,
            swiWasmLocalChartResult: null,
            swiWasmChartPending: false,
            swiWasmStatechartDelayedQueue: [],
            swiWasmQueryPending: false,
            swiWasmQueryAbortRequested: false
  }; }
  // The existing Vue host consumes these same methods and state. Presentation
  // callbacks below are the only UI boundary; create() needs no Vue or terminal.
  methods.loadSwiWasmEngineBundle = function() {
    var url = this.swiWasmAssets ? this.swiWasmAssets.engineUrl : "/swipl-bundle.js";
    return new Promise(function(resolve, reject) {
      var script = document.createElement("script");
      script.src = url;
      script.onload = resolve;
      script.onerror = function() { reject(new Error("Unable to load SWI-WASM engine: " + url)); };
      document.head.appendChild(script);
    });
  };

  function create(options) {
    options = options || {};
    var node = Object.assign(createState(), methods);
    var disposed = false, opening = null, pending = null;
    var inputWaiters = [];
    var origin = options.baseUrl || (typeof location !== "undefined" ? location.href : "http://localhost/");
    function asset(value) { return new URL(value, origin).href; }
    node.swiWasmAssets = {
      workerUrl: asset(options.workerUrl || "/swi_wasm_actor_worker.js"),
      engineUrl: asset(options.engineUrl || "/swipl-bundle.js"),
      prologBaseUrl: asset(options.prologBaseUrl || "/wasm/"),
      sharedDatabaseUrl: options.sharedDatabaseUrl === null ? null : asset(options.sharedDatabaseUrl || "/wasm/shared_db.pl")
    };
    node.isSwiWasm2Mode = true;
    function emit(type, data) {
      if (!disposed && options.onEvent) return options.onEvent(Object.assign({type:type}, data || {}));
      return false;
    }
    function settle(message, error) {
      if (!pending) return;
      var current = pending; pending = null;
      if (error) current.reject(error); else current.resolve(message);
    }
    node.log = function(level, text, scope, direction) { emit("log", {level:level,text:text,scope:scope,direction:direction}); };
    node.logSwiWasmWorkerTraffic = function(message, direction) { emit("traffic", {message:message,direction:direction}); };
    node.emitSwiWasmOutput = function(text, kind, source) { return emit("output", {data:String(text == null ? "" : text),kind:kind,source:source}); };
    node.swiWasmHostEvent = function(type, data) {
      emit(type, data);
      if (type === "shell_error" || type === "error") settle(null, new Error(data.error));
    };
    node.handleSwiWasmTrace = function(text) { emit("statechart_trace", {data:text}); };
    node.swiWasmStatechartOwnsActorTraffic = function() { return false; };
    node.startSwiWasmLocalChart = function(live) { node.swiWasmStatechartActive = live; };
    node.stopSwiWasmLocalChart = function() { node.swiWasmStatechartActive = false; };
    node.enqueueSwiWasmStatechartEvent = function(text) { emit("statechart_event", {data:text}); };
    node.requestSwiWasmActorInput = function(prompt) {
      var response = options.onInput ? null : new Promise(function(resolve) { inputWaiters.push(resolve); });
      emit("prompt", {data:String(prompt)});
      return response || Promise.resolve(options.onInput(String(prompt)));
    };
    node.handleSwiWasm2ToplevelMessage = function(pid, message) {
      if (pid !== node.swiWasm2ShellPid) return false;
      if (message.type === "output" && Object.prototype.hasOwnProperty.call(message,"data")) {
        node.emitSwiWasmOutput(message.data); return true;
      }
      if (message.type === "prompt") {
        node.requestSwiWasmActorInput(message.data || "").then(function(answer) {
          var entry = node.swiWasmActorWorkers[pid];
          if (!disposed && entry && !entry.done && answer !== null) {
            entry.worker.postMessage({command:"toplevel_respond",pid:Number(pid),input:String(answer)});
          }
        });
        return true;
      }
      if (["success","failure","timeout","stop","abort","halted"].indexOf(message.type) >= 0 ||
          (message.type === "error" && Object.prototype.hasOwnProperty.call(message,"data"))) {
        node.swiWasm2QueryPending = message.more === true;
        emit("answer", {message:message}); settle(message); return true;
      }
      return message.type === "responded";
    };
    function alive() { if (disposed) throw new Error("Browser node is disposed"); }
    node.open = function(session) {
      alive();
      if (opening) {
        var existing = node.swiWasmActorWorkers[node.swiWasm2ShellPid];
        if (existing && !existing.done) return opening;
        opening = null;
      }
      session = session || {};
      var pid = node.reserveSwiWasmWorkerActorPid();
      node.swiWasm2ShellPid = pid;
      opening = node.spawnSwiWasmWorkerActorReady(
        "swi_wasm_actor_bridge:ptcp(" + qualifySwiWasmLocalPid(pid) + ",terminal,true)",
        String(session.source || ""), pid, "", "shell_toplevel").catch(function(error) {
          node.cleanupSwiWasm2ShellEntry(pid, node.swiWasmActorWorkers[pid]);
          if (node.swiWasm2ShellPid === pid) opening = null;
          throw error;
        });
      return opening;
    };
    function command(name, fields) {
      alive();
      if (!opening || !node.swiWasm2ShellReady) return Promise.reject(new Error("Open a session first"));
      if (pending) return Promise.reject(new Error("A query is already pending"));
      return new Promise(function(resolve,reject) {
        pending = {resolve:resolve,reject:reject};
        try {
          node.swiWasmActorWorkers[node.swiWasm2ShellPid].worker.postMessage(Object.assign(
            {command:name,pid:Number(node.swiWasm2ShellPid)},fields || {}));
        } catch(error) { settle(null,error); }
      });
    }
    node.query = function(goal, queryOptions) {
      if (node.swiWasm2QueryPending) return Promise.reject(new Error("Stop or exhaust the preceding query first"));
      return command("toplevel_call", {goal:String(goal),options:typeof queryOptions === "string" ? queryOptions : node.toplevelCallOptionsText(queryOptions || {})});
    };
    node.next = function() {
      if (!node.swiWasm2QueryPending) return Promise.reject(new Error("No pending continuation"));
      return command("toplevel_next");
    };
    function interrupt(name) {
      alive();
      if (!pending) return command(name);
      var current = pending;
      node.swiWasmActorWorkers[node.swiWasm2ShellPid].worker.postMessage({command:name,pid:Number(node.swiWasm2ShellPid)});
      // The outstanding query's promise receives the interruption response.
      return Promise.resolve();
    }
    node.stop = function() { return interrupt("toplevel_stop"); };
    node.abort = function() { return interrupt("toplevel_abort"); };
    node.input = function(text) { alive(); var resolve=inputWaiters.shift(); if (!resolve) throw new Error("No pending input"); resolve(text); };
    node.dispose = function() {
      if (disposed) return;
      disposed = true;
      settle(null,new Error("Browser node disposed"));
      inputWaiters.splice(0).forEach(function(resolve) { resolve(null); });
      Object.values(node.swiWasmRemoteActorConnections || {}).forEach(function(entry) {
        if (entry.socket) entry.socket.close();
      });
      Object.values(node.swiWasmActorWorkers || {}).forEach(function(entry) {
        if (entry.rejectReady) entry.rejectReady(new Error("Browser node disposed"));
      });
      node.resetSwiWasmActorWorkers();
    };
    return node;
  }

  return {
    create:create, createState:createState, methods:methods,
    helpers:{splitTopLevelArgs:splitTopLevelArgs,unwrapPrologCompound:unwrapPrologCompound,stripRuntimeErrorScaffolding:stripRuntimeErrorScaffolding,exceptionDisplayTerm:exceptionDisplayTerm,sanitizeDownReasonTerm:sanitizeDownReasonTerm,normalizeNodeUrl:normalizeNodeUrl,isLoopbackHost:isLoopbackHost,
      resolveBrowserRpcBaseUri:resolveBrowserRpcBaseUri,resolveBrowserRpcLoadUri:resolveBrowserRpcLoadUri,
      parseSwiWasmQualifiedServiceAddress:parseSwiWasmQualifiedServiceAddress,
      qualifySwiWasmLocalPid:qualifySwiWasmLocalPid,localizeSwiWasmPid:localizeSwiWasmPid}
  };
});
