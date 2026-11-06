// Published editor example and reported remote variant, through the real UI.
// Requires Playwright, CHROME_PATH; UI_REPORT writes bounded diagnostic evidence.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {chromium} = require('playwright');
const rows = [];
(async () => {
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH, headless: true});
  try {
    for (const node of (process.env.UI_NODES || '3,4,5').split(',')) {
      const origin = `https://n${node}.elfenbenstornet.se`;
      const peer = `https://n${node === '3' ? '4' : '3'}.elfenbenstornet.se`;
      const context = await browser.newContext({viewport: {width: 1600, height: 1100}});
      const page = await context.newPage();
      page.setDefaultTimeout(20000);
      const row = {node, origin, peer, checks: [], status: 'running'};
      rows.push(row);
      try {
        await page.goto(origin + '/demonstrator');
        await page.getByRole('button', {name: 'Dismiss', exact: true}).click();
        await page.locator('.project-link').filter({hasText: '06 ping-pong.pl'}).click();
        await page.waitForFunction(() => vm.wsPid && !vm.wsSpawnPromise && !vm.terminalBusy &&
          vm.wsLoadedText.includes('ping_pong :-'));
        async function query(goal) {
          const before = await page.evaluate(() => vm.terminal.get_output().length);
          await page.evaluate(goal => { vm.terminal.exec(goal); }, goal);
          await page.waitForTimeout(100);
          await page.waitForFunction(() => !vm.terminalBusy);
          return page.evaluate(before => ({output: vm.terminal.get_output().slice(before),
            bindings: {...vm.lastBindings}}), before);
        }
        async function baseline() {
          return (await query('actors(UiActors).')).bindings.UiActors;
        }
        const before = await baseline();
        assert.ok(before);
        await page.locator('.terminal-examples-button').click();
        await page.locator('.terminal-examples-item').filter({hasText: 'ping_pong.'}).click();
        await page.waitForFunction(() => !vm.terminalBusy && vm.terminal.get_output().includes('Pong finished.'));
        const localOutput = await page.evaluate(() => vm.terminal.get_output());
        assert.equal((localOutput.match(/Ping received pong\./g) || []).length, 3, localOutput);
        assert.equal((localOutput.match(/Pong received ping\./g) || []).length, 3, localOutput);
        // The published example is intentionally asynchronous. Poll for retirement.
        let after;
        for (let attempt = 0; attempt < 20; attempt++) {
          after = await baseline();
          if (after === before) break;
          await page.waitForTimeout(100);
        }
        assert.equal(after, before);
        row.checks.push({name: 'published Queries menu ping-pong', status: 'pass', baseline: before});
        const source = await page.evaluate(() => vm.prologText);
        const variant = source.replace('    self(Self),', '    self(Self),\n    writeln(Self),') + `
ui_write(Term) :- write(Term).
ui_down(P) :- receive({down(P,_,Reason)->(Reason==true->true;throw(unexpected_exit(Reason)))},
    [timeout(8),on_timeout(throw(missing_completion))]).
ui_remote(URL) :-
    spawn(pong,Pong,[src_predicates([pong/0]),monitor(true)]),
    Options=[node(URL),src_predicates([ping/2]),monitor(true)],
    spawn(ping(3,Pong),Ping,Options),ui_down(Ping),ui_down(Pong).
`;
        assert.ok(variant.includes('    writeln(Self),'));
        assert.equal(await page.evaluate(source => vm.loadTutorialProgramIntoCurrentSession(source), variant), true);
        const remoteBaseline = await baseline();
        for (const url of [peer + '/', peer]) {
          const result = await query(`ui_remote('${url}').`);
          assert.equal((result.output.match(/Ping received pong\./g) || []).length, 3, result.output);
          assert.equal((result.output.match(/Pong received ping\./g) || []).length, 3, result.output);
          assert.match(result.output, /Ping finished\./);
          assert.match(result.output, /Pong finished\./);
          assert.match(result.output, /true\./);
          assert.equal((result.output.match(new RegExp('@[^\\n]*' + peer.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length, 3, result.output);
          assert.doesNotMatch(result.output, /Permission error|terminal-error|<js>/);
          assert.equal(await baseline(), remoteBaseline);
          row.checks.push({name: 'remote writeln(Self)', uri: url, output: result.output, baseline: remoteBaseline, status: 'pass'});
        }
        const write = await query(`spawn(ui_write(ui_write_probe),P,[node('${peer}/'),src_predicates([ui_write/1]),monitor(true)]),ui_down(P),UiWrite=passed.`);
        assert.match(write.output, /ui_write_probe/);
        assert.equal(write.bindings.UiWrite, 'passed');
        assert.equal(await baseline(), remoteBaseline);
        row.checks.push({name: 'copied write/1', status: 'pass'});
        const fresh = await query('AfterUiRegression=ready.');
        assert.equal(fresh.bindings.AfterUiRegression, 'ready');
        row.fresh_query = true;
        row.status = 'pass';
        console.log('N' + node, 'published menu, URI aliases, copied I/O, actor baseline and fresh query: pass');
      } catch (error) {
        row.status = 'fail'; row.error = String(error.stack || error);
        row.snapshot = await page.evaluate(() => ({output: vm.terminal.get_output(), logs: vm.logEntries.slice(0, 8)})).catch(() => null);
        throw error;
      } finally {
        await context.close();
        if (process.env.UI_REPORT) fs.writeFileSync(process.env.UI_REPORT, JSON.stringify(rows, null, 2) + '\n');
      }
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
