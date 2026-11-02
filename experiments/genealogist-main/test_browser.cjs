const assert = require('node:assert/strict');
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH,
    headless: true,
  });
  try {
    const page = await browser.newPage({ acceptDownloads: true });
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(process.env.DEMO_URL || 'http://localhost:8094/');
    await page.waitForFunction(() => !document.getElementById('ask').disabled);
    const run = (goal) => page.evaluate((goal) => node.query(goal, { limit: 1 }), goal);
    if (process.env.WORKER_URL) {
      const worker = await browser.newPage();
      await worker.goto(process.env.WORKER_URL);
      await worker.waitForFunction(() => !document.getElementById('ask').disabled);
      const collect = (target, goal) =>
        target.evaluate(async (goal) => {
          let answer = await node.query(goal, { limit: 1 });
          const rows = [];
          while (true) {
            if (answer.type === 'success') rows.push(...answer.data);
            else if (answer.type !== 'failure') throw new Error(JSON.stringify(answer));
            if (!answer.more) return rows;
            answer = await node.next();
          }
        }, goal);
      for (const goal of [
        'ancestor_descendant(mike, Who)',
        'siblings(X,Y)',
        'parent_child(Who,sally)',
      ]) {
        assert.deepEqual(await collect(page, goal), await collect(worker, goal));
      }
      await worker.close();
      console.log('PASS answer parity with the Worker actor version');
    }
    assert.equal(
      await page.locator('#people-count').textContent(),
      '5 people · 4 facts'
    );
    assert.deepEqual(
      await page.evaluate(() => ({
        main: !!node.swiWasmProlog,
        worker: node.isSwiWasm2Mode,
        workers: Object.keys(node.swiWasmActorWorkers).length,
      })),
      { main: true, worker: false, workers: 0 }
    );
    assert.equal((await run('current_module(dom)')).type, 'success');
    const domAnswer = await run(
      "E := document[getElementById(#'graph-note')], append_html(E, span([id='dom-probe'], 'DOM works'))"
    );
    assert.equal(domAnswer.type, 'success');
    assert.equal(await page.locator('#dom-probe').textContent(), 'DOM works');
    await run("E := document[getElementById(#'dom-probe')], _ := E[remove()]");
    await page.locator('#ask').click();
    await page.waitForFunction(() => !document.getElementById('next').disabled);
    assert.match(await page.locator('#answers').textContent(), /Who = tom/);
    await page.locator('#next').click();
    await page.waitForFunction(
      () =>
        document.getElementById('answers').textContent.includes('Who = sally') &&
        !document.getElementById('next').disabled
    );
    assert.match(await page.locator('#answers').textContent(), /Who = sally/);
    await page.locator('#stop').click();
    await page.waitForFunction(() => !document.getElementById('add').disabled);
    console.log('PASS startup, main-thread engine, DOM library, UI paging and Stop');
    await page.locator('#parent').fill('erica');
    await page.locator('#child').fill('alex');
    await page.locator('#add').click();
    await page.waitForFunction(
      () => document.getElementById('people-count').textContent === '6 people · 5 facts'
    );
    assert.equal((await run('once(ancestor_descendant(mike,alex))')).type, 'success');
    let answer = await run('add_relationship(father,alex,mike)');
    assert.equal(answer.type, 'error');
    assert.match(answer.data, /acyclic_family/);
    await page
      .getByRole('button', {
        name: 'Remove mother relationship from erica to alex',
        exact: true,
      })
      .click();
    await page.waitForFunction(
      () => document.getElementById('people-count').textContent === '5 people · 4 facts'
    );
    assert.equal((await run('ancestor_descendant(mike,alex)')).type, 'failure');
    console.log('PASS form add/remove, persistent edits and rejected cycle');
    assert.equal((await run('writeln(hello),fail')).type, 'failure');
    assert.match(await page.locator('#output').textContent(), /hello/);
    assert.equal((await run('throw(probe_error)')).type, 'error');
    assert.equal((await run('(')).type, 'error');
    assert.equal((await run('true')).type, 'success');
    assert.equal(
      (await run(`X = 'mary jane', L = [a,b], N is 2+3`)).data[0].X,
      "'mary jane'"
    );
    await page.evaluate(() => node.stop());
    // Paging must not execute side effects of future alternatives.
    await run('retractall(page_effect(_)),member(X,[a,b,c]),assertz(page_effect(X))');
    await page.evaluate(() => node.stop());
    assert.equal((await run('findall(X,page_effect(X),Xs)')).data[0].Xs, '[a]');
    console.log(
      'PASS output, failure, error recovery, term formatting and lazy side effects'
    );
    await page.locator('#goal').fill('read(X)');
    await page.locator('#ask').click();
    await page.locator('#input-dialog').waitFor({ state: 'visible' });
    await page.locator('#input-value').fill('hello.');
    await page.getByRole('button', { name: 'Send response', exact: true }).click();
    await page.waitForFunction(() => !document.getElementById('ask').disabled);
    assert.match(await page.locator('#answers').textContent(), /X = hello/);
    await page.locator('#goal').fill('read(X)');
    await page.locator('#ask').click();
    await page.locator('#input-dialog').waitFor({ state: 'visible' });
    await page.getByRole('button', { name: 'Abort query', exact: true }).click();
    await page.waitForFunction(() => !document.getElementById('ask').disabled);
    assert.equal((await run('true')).type, 'success');
    await page.locator('#goal').fill('sleep(10)');
    await page.locator('#ask').click();
    await page.waitForFunction(() => !document.getElementById('abort').disabled);
    await page.locator('#abort').click();
    await page.waitForFunction(() => !document.getElementById('ask').disabled);
    assert.equal((await run('true')).type, 'success');
    console.log(
      'PASS interactive input, input cancellation and cooperative Abort recovery'
    );
    const [download] = await Promise.all([
      page.waitForEvent('download'),
      page.locator('#download').click(),
    ]);
    await download.saveAs(process.env.SAVED_PROLOG || '/tmp/genealogist-main-saved.pl');
    if (process.env.SCREENSHOT)
      await page.screenshot({ path: process.env.SCREENSHOT, fullPage: true });
    assert.deepEqual(errors, []);
    console.log('PASS download and no uncaught browser errors');
  } finally {
    await browser.close();
  }
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
