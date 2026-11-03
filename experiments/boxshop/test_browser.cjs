// Real SWI-WASM and the voice chart; only browser speech services are stubbed.
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
      let speechAllowed = false;
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
            // Model WebKit's initial gesture restriction. Later chart prompts
            // arrive on a worker callback, outside the (Re)start click.
            if (window.event?.type === 'click') speechAllowed = true;
            if (!speechAllowed) return;
            if (utterance.volume !== 0) window.__spoken.push(utterance.text);
            speaking = utterance;
            timer = setTimeout(() => {
              speaking = null;
              utterance.onend?.({ type: 'end' });
            }, 150);
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
          if (speaking) throw new Error('Recognition started during speech');
          setTimeout(() => {
            this.onstart?.();
            if (window.__recognitionError) {
              this.onerror?.({ error: window.__recognitionError });
              this.onend?.();
            }
          }, 0);
        }
        abort() {
          this.onend?.();
        }
      };
    });
    const base = process.env.DEMO_URL || 'http://localhost:8094/';
    await page.goto(base);
    const start = page.getByRole('button', { name: '(Re)start', exact: true });
    const end = page.getByRole('button', { name: 'End', exact: true });
    const mic = page.locator('#microphone');
    const conversation = page.locator('#conversation');
    const status = page.locator('#voice-status');

    await page
      .locator('#chart-source')
      .getByText(/speak\(/)
      .waitFor();
    const chart = fs.readFileSync(path.join(__dirname, 'boxshop-voice.xml'), 'utf8');
    assert.equal(await page.locator('#chart-source').textContent(), chart);
    assert.equal(await page.locator('input, textarea, [contenteditable]').count(), 0);
    await page.getByRole('tab', { name: 'Statechart' }).press('ArrowRight');
    await page
      .locator('#grammar-source')
      .getByText(/tokenize_atom/)
      .waitFor();
    await page.getByRole('tab', { name: 'Logger' }).click();
    assert.equal(await page.locator('#logger-panel').isVisible(), true);

    const hear = async (text, final = true) => {
      await mic.click();
      await page.waitForFunction(() =>
        document.getElementById('voice-status').textContent.startsWith('Listening…')
      );
      await page.evaluate(
        ({ text, final }) => {
          const result = [{ transcript: text }];
          result.isFinal = final;
          const recognition = window.__recognizers.at(-1);
          recognition.onresult({ resultIndex: 0, results: [result] });
          setTimeout(() => recognition.onend(), 250);
        },
        { text, final }
      );
    };

    await start.click();
    await conversation.getByText('What color do you want?').first().waitFor();
    await page.waitForFunction(() =>
      window.__spoken.some((text) => text.includes('What color do you want?'))
    );
    assert.equal(await page.evaluate(() => window.__recognizers.length), 0);
    const silence = conversation.getByText('I did not hear you.');
    // Waiting longer than the old state timer must leave the chat unchanged.
    await page.waitForTimeout(8200);
    assert.equal(await silence.count(), 0);
    await page.evaluate(() => {
      window.__recognitionError = 'no-speech';
    });
    await mic.click();
    await silence.waitFor();
    await page.evaluate(() => {
      window.__recognitionError = null;
    });
    await page.waitForFunction(() =>
      window.__spoken.some((text) => text.includes('I did not hear you.'))
    );
    await hear('blue', false);
    const misunderstood = conversation.getByText('I did not understand.');
    await misunderstood.first().waitFor();
    assert.equal(
      await conversation.locator('.message.user').first().textContent(),
      'blue'
    );
    assert.equal(await page.locator('#chart-state').textContent(), 'Color');
    await hear('blue 123');
    await misunderstood.nth(1).waitFor();
    await hear("I'd like a blue box, please!");
    assert.equal(await conversation.getByText('What size do you want?').count(), 0);
    await conversation.getByText('What size do you want?').first().waitFor();
    await hear('large');
    await conversation.getByText('You want a big blue box!').waitFor();
    await page.waitForFunction(() =>
      window.__spoken.includes('You want a big blue box!')
    );
    await page
      .locator('#trace')
      .getByText(/external_event\(says\(size\(big\)\)\)/)
      .waitFor();
    assert.equal(await mic.isDisabled(), true);

    await start.click();
    await conversation.getByText('What color do you want?').first().waitFor();
    await page.evaluate(() => {
      window.__recognitionError = 'not-allowed';
    });
    await mic.click();
    await status.getByText(/Microphone unavailable.*Allow microphone access/).waitFor();
    assert.equal(await status.getAttribute('data-problem'), 'true');
    await end.click();
    assert.equal(await mic.isDisabled(), true);
    assert.equal(await end.isDisabled(), true);

    const unsupported = await browser.newPage({
      viewport: { width: 375, height: 800 },
    });
    await unsupported.addInitScript(() => {
      window.SpeechRecognition = undefined;
      window.webkitSpeechRecognition = undefined;
    });
    await unsupported.goto(base);
    await unsupported
      .locator('#voice-status')
      .getByText(/Microphone unavailable.*Chrome/)
      .waitFor();
    assert.equal(await unsupported.locator('#start').isDisabled(), true);
    assert.equal(
      await unsupported.evaluate(
        () => document.documentElement.scrollWidth > innerWidth
      ),
      false
    );
    assert.deepEqual(errors, []);
    console.log(
      'PASS speech-only conversation, speak/2 output, tabs, restart/end, and microphone remedies'
    );
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
