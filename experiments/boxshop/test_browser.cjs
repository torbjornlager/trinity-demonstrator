// Real SWI-WASM and the original chart; only browser speech services are stubbed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH,
    headless: true,
  });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(String(error)));
    await page.addInitScript(() => {
      window.__spoken = [];
      window.__recognizers = [];
      let speaking = null,
        timer = null;
      Object.defineProperty(window, 'speechSynthesis', {
        value: {
          getVoices: () => [{ lang: 'en-US', localService: true }],
          cancel() {
            clearTimeout(timer);
            const old = speaking;
            speaking = null;
            old?.onerror?.({ type: 'error', error: 'canceled' });
          },
          speak(utterance) {
            window.__spoken.push(utterance.text);
            speaking = utterance;
            timer = setTimeout(() => utterance.onend?.({ type: 'end' }), 10);
          },
        },
      });
      window.SpeechSynthesisUtterance = class {
        constructor(text) {
          this.text = text;
        }
      };
      window.SpeechRecognition = class {
        constructor() {
          window.__recognizers.push(this);
        }
        start() {
          setTimeout(() => {
            this.onstart?.();
            if (window.__recognitionError)
              this.onerror?.({ error: window.__recognitionError });
          }, 0);
        }
        abort() {
          this.onend?.();
        }
      };
    });
    const base = process.env.DEMO_URL || 'http://localhost:8094/';
    await page.goto(base);
    await page.waitForFunction(() => !document.getElementById('start').disabled);
    const chart = await (
      await page.request.get(new URL('boxshop-2.xml', base).href)
    ).body();
    assert.deepEqual(chart, fs.readFileSync(path.join(__dirname, 'boxshop-2.xml')));
    assert.deepEqual(
      chart,
      fs.readFileSync(
        path.resolve(__dirname, '../../examples/statecharts/12 boxshop-2.xml')
      )
    );
    assert.equal(await page.evaluate(() => window.__recognizers.length), 0);
    await page.locator('#start').click();
    const ready = (phase) =>
      page.waitForFunction(
        (phase) =>
          document.getElementById('chart-state').textContent === phase &&
          !document.getElementById('send').disabled,
        phase
      );
    await ready('Color');
    assert.match(
      await page.locator('#conversation').textContent(),
      /Welcome to the box shop!/
    );
    assert.doesNotMatch(await page.locator('#conversation').textContent(), /Warning:/);
    await page.waitForFunction(() =>
      window.__spoken.some((text) => text.includes('What color do you want?'))
    );
    console.log(
      'PASS unchanged XML, native chart startup, real prompts and spoken-output integration'
    );

    await page.waitForFunction(
      () =>
        document
          .getElementById('conversation')
          .textContent.includes('I did not hear you.'),
      undefined,
      { timeout: 12000 }
    );
    assert.equal(await page.locator('#chart-state').textContent(), 'Color');
    const beforeHidden = await page.evaluate(() => window.__spoken.length);
    const hiddenRetries = await page
      .locator('.message.assistant')
      .filter({ hasText: 'I did not hear you.' })
      .count();
    await page.evaluate(() => {
      Object.defineProperty(document, 'hidden', { value: true, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    });
    await page.waitForFunction(
      (count) =>
        [...document.querySelectorAll('.message.assistant')].filter((e) =>
          e.textContent.includes('I did not hear you.')
        ).length > count,
      hiddenRetries,
      { timeout: 12000 }
    );
    await page.waitForTimeout(120);
    assert.equal(await page.evaluate(() => window.__spoken.length), beforeHidden);
    await page.evaluate(() => {
      delete document.hidden;
      document.dispatchEvent(new Event('visibilitychange'));
    });
    console.log('PASS chart keeps running in the background without speaking');
    const type = async (text) => {
      await page.locator('#reply').fill(text);
      await page.locator('#send').click();
      await page.waitForFunction(
        () =>
          !document.getElementById('send').disabled ||
          document.getElementById('chart-state').textContent === 'Respond'
      );
    };
    await type('a sandwich');
    await page.waitForFunction(() =>
      document
        .getElementById('conversation')
        .textContent.includes('I did not understand.')
    );
    assert.equal(await page.locator('#selected-color').textContent(), 'Your choice');
    console.log(
      'PASS actual eight-second Color retry and native unrecognised-input fallback'
    );

    await page.locator('#microphone').click();
    await page.waitForFunction(() => window.__recognizers.length === 1);
    await page.evaluate(() => {
      const interim = [{ transcript: 'blu' }];
      interim.isFinal = false;
      window.__recognizers[0].onresult({ resultIndex: 0, results: [interim] });
    });
    assert.match(await page.locator('#voice-status').textContent(), /Hearing/);
    await page.evaluate(() => {
      const result = [{ transcript: 'Blue please' }];
      result.isFinal = true;
      window.__recognizers[0].onresult({ resultIndex: 0, results: [result] });
    });
    await ready('Size');
    assert.equal(await page.locator('#selected-color').textContent(), 'Blue');
    assert.equal(
      await page.locator('#microphone').getAttribute('aria-pressed'),
      'false'
    );
    assert.match(await page.locator('#conversation').textContent(), /YOU · VOICE/);
    const retries = await page
      .locator('.message.assistant')
      .filter({ hasText: 'I did not hear you.' })
      .count();
    await page.waitForFunction(
      (count) =>
        [...document.querySelectorAll('.message.assistant')].filter((e) =>
          e.textContent.includes('I did not hear you.')
        ).length > count,
      retries,
      { timeout: 12000 }
    );
    await type('large, please');
    await page.locator('#order-complete').waitFor({ state: 'visible' });
    assert.equal(await page.locator('#order-summary').textContent(), 'A big blue box.');
    assert.match(
      await page.locator('#conversation').textContent(),
      /You want a big blue box!/
    );
    assert.equal(await page.locator('#send').isEnabled(), false);
    await page.waitForFunction(() => !document.getElementById('replay').disabled);
    const utterances = await page.evaluate(() => window.__spoken.length);
    await page.locator('#replay').click();
    assert.equal(await page.evaluate(() => window.__spoken.length), utterances + 1);
    console.log(
      'PASS speech transcript → Prolog event → Size, Size timeout, alias and order completion'
    );

    await page.locator('#restart').click();
    await ready('Color');
    assert.equal(await page.locator('#selected-color').textContent(), 'Your choice');
    await page.locator('#microphone').click();
    await page.waitForFunction(() => window.__recognizers.length === 2);
    await page.locator('#restart').click();
    await ready('Color');
    await page.evaluate(() => {
      const stale = [{ transcript: 'red' }];
      stale.isFinal = true;
      window.__recognizers[1].onresult({ resultIndex: 0, results: [stale] });
    });
    assert.equal(await page.locator('#selected-color').textContent(), 'Your choice');
    await page.evaluate(() => {
      window.__recognitionError = 'not-allowed';
    });
    await page.locator('#microphone').click();
    await page.waitForFunction(() =>
      document.getElementById('voice-status').textContent.includes('denied')
    );
    await page.getByRole('button', { name: 'Green', exact: true }).click();
    await ready('Size');
    await page.getByRole('button', { name: 'Small', exact: true }).click();
    await page.locator('#order-complete').waitFor({ state: 'visible' });
    assert.equal(
      await page.locator('#order-summary').textContent(),
      'A small green box.'
    );
    console.log(
      'PASS restart, stale speech-result rejection, denied microphone and button fallback'
    );

    await page.locator('#end').click();
    const messages = await page.locator('.message').count();
    await page.waitForTimeout(8300);
    assert.equal(await page.locator('.message').count(), messages);
    assert.equal(await page.locator('#chart-state').textContent(), 'Ended');
    await page.locator('#start').click();
    await page.locator('#end').click();
    await page.waitForTimeout(300);
    assert.equal(await page.locator('#chart-state').textContent(), 'Ended');
    console.log('PASS End cleans timers and cancellation during startup');
    assert.deepEqual(errors, []);
    await page.close();

    const fallback = await browser.newPage({ viewport: { width: 375, height: 900 } });
    await fallback.addInitScript(() => {
      for (const key of [
        'SpeechRecognition',
        'webkitSpeechRecognition',
        'speechSynthesis',
        'SpeechSynthesisUtterance',
      ])
        Object.defineProperty(window, key, { value: undefined, configurable: true });
    });
    fallback.on('pageerror', (error) => errors.push(String(error)));
    await fallback.goto(base);
    await fallback.waitForFunction(() => !document.getElementById('start').disabled);
    await fallback.locator('#start').click();
    await fallback.waitForFunction(() => !document.getElementById('send').disabled);
    assert.equal(await fallback.locator('#microphone').isEnabled(), false);
    assert.equal(await fallback.locator('#spoken').isEnabled(), false);
    assert.match(await fallback.locator('#voice-status').textContent(), /unavailable/);
    await fallback.locator('#reply').fill('purple');
    await fallback.locator('#send').click();
    await fallback.waitForFunction(
      () =>
        document.getElementById('chart-state').textContent === 'Size' &&
        !document.getElementById('send').disabled
    );
    await fallback.locator('#reply').fill('small');
    await fallback.locator('#send').click();
    await fallback.locator('#order-complete').waitFor({ state: 'visible' });
    assert.equal(
      await fallback.locator('#order-summary').textContent(),
      'A small purple box.'
    );
    assert.ok(
      await fallback.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
    );
    await fallback.locator('summary').click();
    assert.ok(
      await fallback.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
    );
    if (process.env.SCREENSHOT)
      await fallback.screenshot({ path: process.env.SCREENSHOT, fullPage: true });
    assert.deepEqual(errors, []);
    console.log(
      'PASS unavailable speech APIs, typed-only order, mobile layout and inspector'
    );
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
