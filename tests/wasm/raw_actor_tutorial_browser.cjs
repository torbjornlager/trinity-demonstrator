'use strict';
// Exercise the actual tutorial UI against selected nodes. Optional candidate
// files replace only the iframe document; all runtime and WebSocket traffic is real.
const {chromium} = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const nodes = (process.env.TUTORIAL_NODES || '3,4,5,7').split(',').map(Number);
const rows = [];

(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.CHROME_PATH});
  try {
    for (const node of nodes) {
      const page = await browser.newPage();
      const sockets = [];
      page.on('websocket', socket => {
        const events = [];
        sockets.push(events);
        for (const [event, direction] of [['framesent','sent'], ['framereceived','received']]) {
          socket.on(event, frame => {
            try { events.push({direction, message:JSON.parse(frame.payload)}); } catch (_) {}
          });
        }
      });
      try {
        const origin = `https://n${node}.elfenbenstornet.se`;
        const tutorial = node === 7 ? '/demonstrator/actor-api-tutorial.html' : '/actor-api-tutorial';
        if (process.env.CANDIDATE_ROOT) {
          await page.route(origin + tutorial, route => route.fulfill({
            contentType:'text/html',
            body:fs.readFileSync(path.join(process.env.CANDIDATE_ROOT, `n${node}`, 'actor-api-tutorial.html'))
          }));
        }
        await page.goto(origin + '/demonstrator');
        await page.waitForFunction(() => typeof webPrologTutorialBridge === 'object');
        const dismiss = page.getByRole('button', {name:'Dismiss', exact:true});
        if (await dismiss.isVisible()) await dismiss.click();
        await page.evaluate(tutorial => {
          const frame = document.createElement('iframe');
          frame.id = 'audit-api-frame';
          frame.src = tutorial;
          document.body.appendChild(frame);
        }, tutorial);
        const frame = page.frameLocator('#audit-api-frame');
        await frame.locator('[data-run-actor-demo]').click();
        await frame.locator('[data-actor-demo-status]').filter({hasText:/Complete.*two pushed outputs/})
          .waitFor({timeout:20000});
        const events = sockets.find(events => events.some(e =>
          e.direction === 'sent' && e.message.command === 'spawn' && e.message.goal === 'echo_actor'));
        assert.ok(events, 'The tutorial must spawn its own echo actor');
        const output = events.filter(e => e.direction === 'received' && e.message.type === 'output');
        assert.deepEqual(output.map(e => String(e.message.stdout || e.message.data).trim()), ['first','second']);
        assert.ok(events.some(e => e.direction === 'received' && ['down','exit'].includes(e.message.type)));
        rows.push({node:`N${node}`, result:'pass', events,
          status:await frame.locator('[data-actor-demo-status]').textContent()});
        console.log(`N${node}: tutorial raw actor output and termination pass`);
      } finally {
        await page.close();
        if (process.env.TUTORIAL_REPORT) fs.writeFileSync(process.env.TUTORIAL_REPORT, JSON.stringify(rows,null,2)+'\n');
      }
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
