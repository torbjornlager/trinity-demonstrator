// Run against a local ACTOR demonstrator whose WebSocket prompts include prompt_ref.
// Usage: node ws_prompt_browser.cjs http://localhost:PORT
'use strict';
const assert = require('node:assert/strict');
const {chromium} = require('playwright-core');

async function main() {
  const origin = new URL(process.argv[2]).origin;
  assert.match(new URL(origin).hostname, /^(localhost|127\.0\.0\.1)$/);
  const browser = await chromium.launch({executablePath: process.env.CHROME_PATH});
  const page = await browser.newPage({viewport: {width: 1600, height: 1100}});
  page.setDefaultTimeout(8000);
  const socketErrors = [];
  page.on('console', message => {
    if (message.type() === 'error') socketErrors.push(message.text());
  });
  page.on('websocket', socket => socket.on('socketerror', error => socketErrors.push(error)));
  try {
    await page.addInitScript(() => {
      const state = window.promptWireProbe = {replies: [], events: [], socket: null};
      const NativeWebSocket = window.WebSocket;
      window.WebSocket = class extends NativeWebSocket {
        constructor(url, protocols) {
          super(url, protocols);
          if (new URL(this.url).pathname !== '/ws') return;
          state.socket = this;
          this.addEventListener('message', event => state.events.push(JSON.parse(event.data)));
        }

        send(message) {
          if (this === state.socket) {
            const frame = JSON.parse(message);
            if (frame.command === 'toplevel_respond') state.replies.push(frame);
          }
          return super.send(message);
        }
      };
      // Replay at the wire boundary without recording it as a UI submission.
      state.replay = frame => NativeWebSocket.prototype.send.call(state.socket, JSON.stringify(frame));
    });

    await page.goto(origin + '/demonstrator');
    const dismiss = page.getByRole('button', {name: 'Dismiss', exact: true});
    if (await dismiss.isVisible()) await dismiss.click();
    await page.waitForFunction(() => typeof vm !== 'undefined' && vm.terminal && vm.transportMode === 'actor');
    const command = text => page.evaluate(text => { vm.terminal.exec(text); }, text);
    const prompt = text => page.waitForFunction(text =>
      vm.queryState === 'prompt' && vm.terminal.get_prompt().includes(text), text);
    const binding = (name, value) => page.waitForFunction(([name, value]) =>
      vm.queryState !== 'prompt' && vm.lastBindings[name] === value, [name, value]);

    await command('input(first,A),input(second,B).');
    await prompt('first');
    await command('original.');
    await prompt('second');
    await page.waitForFunction(() => promptWireProbe.events.some(event => event.type === 'responded'));
    const initial = await page.evaluate(() => ({
      replies: promptWireProbe.replies,
      prompts: promptWireProbe.events.filter(event => event.type === 'prompt')
    }));
    assert.equal(initial.replies.length, 1);
    const first = initial.replies[0];
    assert.equal(typeof first.prompt_ref, 'string');
    assert.equal(first.prompt_ref, initial.prompts[0].prompt_ref);
    assert.notEqual(first.prompt_ref, initial.prompts[1].prompt_ref);

    const beforeReplay = await page.evaluate(first => {
      const index = promptWireProbe.events.length;
      promptWireProbe.replay(first);
      return index;
    }, first);
    await page.waitForFunction(index => promptWireProbe.events.slice(index).some(event =>
      event.code === 'invalid_prompt_ref'), beforeReplay);
    await prompt('second');
    await command('current.');
    await binding('B', 'current');
    assert.equal(await page.evaluate(() => vm.lastBindings.A), 'original');
    const secondReply = await page.evaluate(() => promptWireProbe.replies[1]);
    assert.equal(secondReply.prompt_ref, initial.prompts[1].prompt_ref);

    console.log('Browser kept the current prompt after replay and echoed the fresh reference.');
  } catch (error) {
    console.error(socketErrors.slice(-8));
    console.error(await page.evaluate(() => typeof vm === 'undefined' ? null : ({
      output: vm.terminal?.get_output(), queryState: vm.queryState,
      transport: vm.transportMode, events: promptWireProbe?.events.map(event => event.type),
      log: vm.logEntries.slice(0, 5)
    })).catch(() => null));
    throw error;
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
