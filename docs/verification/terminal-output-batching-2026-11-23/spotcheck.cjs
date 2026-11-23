'use strict';
// Spot-check: candidate page on N2 (ISOTOPE), N6, N7, and SWI-WASM mode.
// SPOT=name:origin:candidatefile|-:mode[,...]   mode = actor|isotope|wasm
const fs = require('node:fs');
const {chromium} = require('playwright');

const specs = process.env.SPOT.split(',').map(s => {
  const [name, host, file, mode] = s.split('|');
  return {name, origin: 'https://' + host, file, mode};
});
const goals = [
  'write(a),write(b).',
  'writeln(a),writeln(b).',
  'write(a),nl,nl,writeln(b),write(c).',
  "format('a~nb~n~n'),write(c).",
];
const report = [];

async function idle(page, timeout = 30000) {
  await page.waitForFunction(() => !vm.terminalBusy, null, {timeout});
}
async function run(page, goal, timeout) {
  await page.evaluate(goal => { vm.terminal.clear(); vm.terminal.exec(goal); }, goal);
  await page.waitForTimeout(400);
  await idle(page, timeout);
  return page.evaluate(() => vm.terminal.get_output());
}

(async () => {
  const browser = await chromium.launch({headless: true, executablePath: process.env.CHROME_PATH});
  try {
    for (const spec of specs) {
      const context = await browser.newContext({viewport: {width: 1600, height: 1100}});
      const page = await context.newPage();
      page.setDefaultTimeout(30000);
      const received = [];
      const errors = [];
      page.on('pageerror', e => errors.push(String(e)));
      page.on('websocket', ws => ws.on('framereceived', f => {
        try { const m = JSON.parse(f.payload); if (m.type === 'output') received.push(m); } catch (_) {}
      }));
      page.on('response', async r => {
        if (!/toplevel_(call|next|poll|spawn)/.test(r.url())) return;
        try { const m = await r.json(); if (m && m.type === 'output') received.push(m); } catch (_) {}
      });
      if (spec.file && spec.file !== '-') {
        const body = fs.readFileSync(spec.file);
        await page.route(spec.origin + '/demonstrator*', route =>
          route.fulfill({contentType: 'text/html', body}));
      }
      const row = {node: spec.name, mode: spec.mode, candidate: spec.file !== '-', cases: []};
      try {
        const url = spec.origin + '/demonstrator' + (spec.mode === 'wasm' ? '?node=swi-wasm' : '');
        await page.goto(url);
        await page.waitForFunction(() => typeof vm !== 'undefined' && vm.terminal, null, {timeout: 60000});
        const dismiss = page.getByRole('button', {name: 'Dismiss', exact: true});
        if (await dismiss.isVisible().catch(() => false)) await dismiss.click();
        if (spec.mode === 'isotope') await page.evaluate(() => vm.chooseProfileMode('isotope'));
        await page.waitForTimeout(spec.mode === 'wasm' ? 8000 : 1000);
        row.transport = await page.evaluate(() => ({transportMode: vm.transportMode,
          dock: vm.activeDockLabel, wasm: !!vm.isBrowserSwiWasmMode,
          hasQueue: typeof vm.queueNodeOutput === 'function'}));
        await run(page, 'true.');
        for (const goal of goals) {
          received.length = 0;
          const output = await run(page, goal);
          row.cases.push({goal, output, outputMessages: received.slice(0, 6).map(m =>
            ({hasStdout: typeof m.stdout === 'string', stdout: m.stdout, data: m.data, kind: m.kind}))});
        }
        received.length = 0;
        const t0 = Date.now();
        const burst = await run(page, `between(1,${process.env.BURST_N || 2000},I), writeln(I), fail ; true.`, Number(process.env.BURST_TIMEOUT || 30000));
        row.burst2000 = {ms: Date.now() - t0, tail: burst.slice(-30),
          logEntries: await page.evaluate(() => vm.logEntries.length), messages: received.length};
      } catch (e) {
        row.error = String(e).slice(0, 500);
      } finally {
        row.pageErrors = errors.slice(0, 5);
        report.push(row);
        await context.close();
      }
      console.log(JSON.stringify(row, null, 1));
    }
  } finally {
    await browser.close();
    if (process.env.SPOT_REPORT) fs.writeFileSync(process.env.SPOT_REPORT, JSON.stringify(report, null, 2) + '\n');
  }
})().catch(e => { console.error(e); process.exitCode = 1; });
