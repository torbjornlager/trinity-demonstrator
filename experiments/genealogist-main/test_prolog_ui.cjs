const assert = require('node:assert/strict');
const {chromium} = require('playwright');
(async () => {
  const browser = await chromium.launch({executablePath:process.env.CHROME_PATH,headless:true});
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.goto(process.env.DEMO_URL || 'http://localhost:8095/genealogist-main/');
    await page.waitForFunction(() => !document.getElementById('ask').disabled);
    const ask = async (goal, expected) => {
      const count = await page.locator('.answer').count();
      await page.locator('#goal').fill(goal); await page.locator('#ask').click();
      await page.waitForFunction(count => document.querySelectorAll('.answer').length > count &&
        (!document.getElementById('ask').disabled || !document.getElementById('next').disabled), count);
      const text = await page.locator('.answer').last().textContent();
      assert.match(text, expected);
    };
    const stop = async () => {
      if (await page.locator('#stop').isEnabled()) {
        await page.locator('#stop').click();
        await page.waitForFunction(() => !document.getElementById('ask').disabled);
      }
    };
    if (process.env.WORKER_URL) {
      const worker = await browser.newPage(); await worker.goto(process.env.WORKER_URL);
      await worker.waitForFunction(() => !document.getElementById('ask').disabled);
      const geometry = target => target.evaluate(() => ({
        viewBox:document.getElementById('family-graph').getAttribute('viewBox'),
        people:[...document.querySelectorAll('.person')].map(p => ({
          name:p.querySelector('.name').textContent,
          generation:p.querySelector('.role').textContent,
          coordinates:p.getAttribute('transform').match(/-?[0-9]+(?:\.[0-9]+)?/g).map(x=>Math.round(Number(x)*1e6)/1e6)
        }))
      }));
      assert.deepEqual(await geometry(page), await geometry(worker)); await worker.close();
      console.log('PASS Prolog diagram geometry matches the Worker version');
    }
    // Prolog attaches accessible SVG event handlers and shortcut bindings.
    const mike = page.getByRole('button', {name:'Ask about Mike’s descendants',exact:true});
    await mike.focus(); await page.keyboard.press('Enter');
    assert.equal(await page.locator('#goal').inputValue(), 'ancestor_descendant(mike, Who)');
    await page.getByRole('button',{name:'Sally’s parents',exact:true}).click();
    assert.equal(await page.locator('#goal').inputValue(), 'parent_child(Who, sally)');
    await page.locator('#goal').press('Enter');
    await page.waitForFunction(() => document.getElementById('answers').textContent.includes('Who = trude'));
    await stop();
    console.log('PASS Prolog-bound SVG keyboard, shortcut and query Enter events');

    await page.locator('#parent').fill('erica');await page.locator('#child').fill('alex');
    await page.locator('#add').click();
    await page.waitForFunction(() => document.getElementById('people-count').textContent === '6 people · 5 facts');
    await page.locator('#parent').fill('alex');await page.locator('#child').fill('mike');
    await page.locator('#role').selectOption('father');await page.locator('#add').click();
    await page.waitForFunction(() => document.getElementById('update-message').textContent.includes('cycle'));
    assert.equal(await page.locator('#people-count').textContent(), '6 people · 5 facts');
    await page.getByRole('button',{name:'Remove mother relationship from erica to alex',exact:true}).click();
    await page.waitForFunction(() => document.getElementById('people-count').textContent === '5 people · 4 facts');
    console.log('PASS native form edits, Prolog error feedback and bound Remove events');

    await ask("  X = 'a  b', L = [a,b], string_codes(S,[104,105])  ", /X = 'a  b'[\s\S]*L = \[a,b\][\s\S]*S = "hi"/);
    await stop();
    await ask('retractall(ui_effect(_)), member(X,[a,b]), assertz(ui_effect(X))', /X = a/);
    await stop();
    await ask('findall(X,ui_effect(X),Xs)', /Xs = \[a\]/);
    await stop();
    await ask('fail', /FAILUREfalse/);
    await ask('(', /ERROR/);
    await ask('true', /SUCCESStrue/);
    await ask("write('<img src=x>'),flush_output", /SUCCESStrue/);
    assert.match(await page.locator('#output').textContent(), /<img src=x>/);
    assert.equal(await page.locator('#output img').count(), 0);
    console.log('PASS native term rendering, quoted whitespace, lazy effects, errors and text-safe output');

    await page.locator('#goal').fill('get_time(S), repeat, get_time(T), T-S > 10, !');
    const started = Date.now(); await page.locator('#ask').click();
    await page.waitForFunction(() => !document.getElementById('abort').disabled);
    await page.locator('#clear').click();
    assert.equal(await page.locator('#answer-count').textContent(), '0');
    await page.locator('#abort').click();
    await page.waitForFunction(() => !document.getElementById('ask').disabled);
    assert.ok(Date.now()-started < 3000, 'Prolog event handlers remain usable while the query yields');
    await ask('true', /SUCCESStrue/);
    console.log('PASS Prolog-bound Clear and cooperative Abort during a CPU query');

    await ask('assertz(father_child(sally,mike))', /SUCCESStrue/);
    assert.match(await page.locator('#graph-note').textContent(), /Cycle detected/);
    await page.getByRole('button',{name:'Remove father relationship from sally to mike',exact:true}).click();
    await page.waitForFunction(() => !document.getElementById('graph-note').textContent.includes('Cycle'));
    await ask('retractall(mother_child(_,_)),retractall(father_child(_,_))', /SUCCESStrue/);
    assert.equal(await page.locator('#people-count').textContent(), '0 people · 0 facts');
    assert.equal(await page.locator('#graph-empty').isVisible(), true);
    assert.equal(await page.locator('#family-graph').isVisible(), false);
    await page.locator('#clear').click();
    assert.equal(await page.locator('.answer').count(), 0);
    assert.equal(await page.locator('#answer-count').textContent(), '0');
    assert.deepEqual(errors, []);
    console.log('PASS native cycle layout, empty-family rendering and Clear');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
