// Protect responsiveness and output ordering without needing a live node.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../web/demonstrator.html'), 'utf8');
const timers = new Map();
let nextTimer = 1;
function method(name, nextName) {
  const start = source.indexOf(name + ': function');
  assert.ok(start >= 0, name);
  const body = source.slice(source.indexOf('function', start), source.indexOf('\n          ' + nextName + ': function', start)).trim().replace(/,$/, '');
  return Function('setTimeout', 'clearTimeout', 'nowTime', 'return (' + body + ');')(
    fn => { const id = nextTimer++; timers.set(id, fn); return id; },
    id => timers.delete(id), () => '12:00:00');
}
const host = {
  queueTerminalOutput: method('queueTerminalOutput', 'flushTerminalOutput'),
  flushTerminalOutput: method('flushTerminalOutput', 'discardTerminalOutput'),
  discardTerminalOutput: method('discardTerminalOutput', 'echoSwiWasmOutput')
};
const echoes = [];
const term = {echo: text => echoes.push(text)};
for (let i = 0; i < 2000; i++) host.queueTerminalOutput(term, String(i));
assert.equal(echoes.length, 0, 'receiving output does not render synchronously');
assert.equal(timers.size, 1, 'one scheduled render for a burst');
const tick = [...timers.entries()][0]; timers.delete(tick[0]); tick[1]();
assert.equal(echoes[0].split('\n').length, 200, 'each scheduled render has a bounded amount of work');
host.flushTerminalOutput(term);
assert.equal(echoes.join('\n'), Array.from({length: 2000}, (_, i) => String(i)).join('\n'), 'completion flush preserves all output in wire order');
assert.equal(timers.size, 0);
host.queueTerminalOutput(term, 'old shell output');
host.discardTerminalOutput();
assert.equal(timers.size, 0, 'Abort or session replacement cancels queued rendering');
host.queueTerminalOutput(term, 'fresh shell output');
host.flushTerminalOutput(term);
assert.equal(echoes.at(-1), 'fresh shell output', 'retired output cannot leak into the fresh query');

const logger = {
  log: method('log', 'formatJavaScriptObject'),
  clearLogger: method('clearLogger', 'clearTerminal'),
  normalizeLogKind: k => k,
  focusTerminalSoon() {},
  activeDockLabel: 'actor', nextLogId: 1, logEntries: [], logDisplayLimit: 200
};
for (let i = 0; i < 2000; i++) assert.equal(logger.log('info', String(i)), i + 1);
assert.equal(logger.logEntries.length, 0, 'wire messages do not trigger individual logger renders');
const logTick = [...timers.entries()][0]; timers.delete(logTick[0]); logTick[1]();
assert.equal(logger.logEntries.length, 2000, 'batching keeps the complete log');
assert.deepEqual(logger.logEntries.map(e => e.id), Array.from({length: 2000}, (_, i) => 2000 - i));
const filteredLogs = method('filteredLogs', 'transportModeLabel');
logger.matchingLogs = logger.logEntries;
assert.equal(filteredLogs.call(logger).length, 200, 'initial logger DOM remains bounded');
logger.logDisplayLimit += 200;
assert.equal(filteredLogs.call(logger).length, 400, 'older entries remain available');
logger.log('info', 'before Clear');
logger.clearLogger();
assert.equal(logger.log('info', 'after Clear'), 1);
const clearTick = [...timers.entries()][0]; timers.delete(clearTick[0]); clearTick[1]();
assert.deepEqual(logger.logEntries.map(e => e.message), ['after Clear'], 'Clear also removes pending entries');
console.log('terminal streaming and logger regressions passed');
