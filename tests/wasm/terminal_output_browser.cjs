'use strict';
// Real Chrome regression for terminal output against live ACTOR nodes.
// CANDIDATE_HTML replaces only the demonstrator page; node traffic is real.
//   node tests/wasm/terminal_output_browser.cjs
//   CANDIDATE_HTML=web/demonstrator.html TERMINAL_NODES=3,5 node tests/wasm/terminal_output_browser.cjs
// The endless-output Abort check is skipped on N5 unless TERMINAL_FLOOD_N5=1:
// on 23 November it stalled production N5 for about five minutes (see
// docs/verification/terminal-output-batching-2026-11-23/REPORT.md).
const fs = require('node:fs');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');

const nodes = (process.env.TERMINAL_NODES || '3,5').split(',').map(Number);
const candidate = process.env.CANDIDATE_HTML ? fs.readFileSync(process.env.CANDIDATE_HTML) : null;
const rows = [];
// N5 (Trealla) blocks while reaping aborted sessions with large queued output,
// so flooding production N5 takes the whole node down. Opt in explicitly.
const floodN5 = process.env.TERMINAL_FLOOD_N5 === '1';

// Program output is a character stream; answers start on a fresh line.
const streamCases = [
  ['write(a),write(b).', 'ab'],
  ['write(a),sleep(0.2),write(b).', 'ab'],
  ['writeln(a),writeln(b).', 'a\nb'],
  ['self(Me),Me ! a,Me ! b,flush.', 'Shell got a\nShell got b'],
  ['write(a),nl,nl,writeln(b),write(c).', 'a\n\nb\nc'],
  ["format('a~nb~n~n'),write(c).", 'a\nb\n\nc'],
  ['write(after_previous_query).', 'after_previous_query'],
];

async function idle(page, timeout = 30000) {
  await page.waitForFunction(() => !vm.terminalBusy, null, {timeout});
}

async function run(page, goal) {
  await page.evaluate(goal => { vm.terminal.clear(); vm.terminal.exec(goal); }, goal);
  await page.waitForTimeout(300);
  await idle(page);
  return page.evaluate(() => vm.terminal.get_output());
}

// Largest gap between page.evaluate round trips while the terminal is busy.
async function maxRoundTrip(page, ms) {
  let worst = 0;
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const t = Date.now();
    await page.evaluate(() => 1);
    worst = Math.max(worst, Date.now() - t);
    await page.waitForTimeout(100);
  }
  return worst;
}

(async () => {
  const browser = await chromium.launch({headless: true, executablePath: process.env.CHROME_PATH});
  try {
    for (const node of nodes) {
      const origin = `https://n${node}.elfenbenstornet.se`;
      const context = await browser.newContext({viewport: {width: 1600, height: 1100}});
      const page = await context.newPage();
      page.setDefaultTimeout(30000);
      const sent = [];
      page.on('websocket', socket => socket.on('framesent', frame => {
        try { sent.push({at: Date.now(), message: JSON.parse(frame.payload)}); } catch (_) {}
      }));
      if (candidate) {
        await page.route(origin + '/demonstrator', route =>
          route.fulfill({contentType: 'text/html', body: candidate}));
      }
      try {
        await page.goto(origin + '/demonstrator');
        await page.waitForFunction(() => typeof vm !== 'undefined' && vm.terminal);
        const dismiss = page.getByRole('button', {name: 'Dismiss', exact: true});
        if (await dismiss.isVisible()) await dismiss.click();
        await run(page, 'true.');

        for (const [goal, expected] of streamCases) {
          const answer = goal.startsWith('self(Me)') ? 'Me =' : 'true.';
          const output = await run(page, goal);
          assert.ok(output.includes('\n' + expected + '\n' + answer),
            JSON.stringify({node, goal, expected, output}));
          rows.push({node, check: goal, passed: true});
        }

        // A burst of output must neither freeze the page nor bloat the logger.
        const lines = 5000;
        await page.evaluate(n => {
          vm.terminal.clear();
          vm.terminal.exec(`between(1,${n},I), writeln(I), fail ; true.`);
        }, lines);
        const burstRoundTrip = await maxRoundTrip(page, 1500);
        await idle(page);
        const burst = await page.evaluate(() => ({
          output: vm.terminal.get_output(),
          logEntries: vm.logEntries.length,
        }));
        assert.ok(burst.output.endsWith(`\n${lines - 1}\n${lines}\ntrue.`), burst.output.slice(-80));
        assert.ok(burstRoundTrip < 1000, `page blocked ${burstRoundTrip} ms during burst`);
        assert.ok(burst.logEntries <= 1000, `logger holds ${burst.logEntries} entries`);
        rows.push({node, check: `${lines}-line burst`, roundTripMs: burstRoundTrip, passed: true});

        if (node === 5 && !floodN5) {
          rows.push({node, check: 'abort under flood', skipped: 'set TERMINAL_FLOOD_N5=1 to run'});
        } else {
          // During endless output the Abort button must still respond at once.
          await page.evaluate(() => {
            vm.terminal.clear();
            vm.terminal.exec('between(1,inf,I), writeln(I), fail.');
          });
          await page.waitForTimeout(1500);
          const floodRoundTrip = await maxRoundTrip(page, 1500);
          const clickedAt = Date.now();
          await page.getByRole('button', {name: 'Abort', exact: true}).click({timeout: 2000});
          await page.waitForTimeout(500);
          const abort = sent.find(entry => entry.at >= clickedAt && /abort/.test(entry.message.command || ''));
          assert.ok(abort, 'no abort command sent within 500 ms of the click');
          assert.ok(floodRoundTrip < 1000, `page blocked ${floodRoundTrip} ms during flood`);
          rows.push({node, check: 'abort under flood', roundTripMs: floodRoundTrip,
            abortSentMs: abort.at - clickedAt, passed: true});
        }
        // Closing the context ends the session; how quickly the node itself
        // stops producing output is a node property, not checked here.
      } finally {
        await context.close();
      }
      for (const row of rows.filter(row => row.node === node)) console.log(JSON.stringify(row));
    }
  } finally {
    await browser.close();
    if (process.env.TERMINAL_REPORT) fs.writeFileSync(process.env.TERMINAL_REPORT, JSON.stringify(rows, null, 2) + '\n');
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
