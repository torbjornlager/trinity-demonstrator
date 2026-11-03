# The Box Shop — a statechart with a voice interface

A browser-only demo of the form-filling agent in
[`12 boxshop-2.xml`](../../examples/statecharts/12%20boxshop-2.xml).
The browser runs `boxshop-voice.xml`, a voice adaptation that uses `speak/2`
for each utterance. The SWI-WASM statechart actor owns slot selection, the
silence retries, the unrecognised-input fallback and the final order.
The chat displays spoken prompts and recognised replies. The Statechart,
Grammar and Logger tabs show the running XML, the reply grammar and live events.

## Run

With an extracted, verified swi-wasm-node runtime package:

```sh
python3 experiments/boxshop/serve.py \
  --runtime-package /path/to/swi-wasm-node-package --port 8094
```

Open http://localhost:8094/. For the website snapshot, use the same committed
runtime as the Genealogist examples (SWI-Prolog 10.1.19 / swipl-wasm 8.2.5).
The Python server serves files only. The engine, chart and order state run in
the browser's Workers.

Press **(Re)start**, wait for the question, then press the **microphone icon** beneath the chat.
Try “blue”, “a blue box”, “small” or “large, please”. The grammar maps “large”
to `big` and “little” to `small`. Other replies become `says(unknown)`.
**(Re)start** opens a fresh session. **End** stops speech, recognition and the
chart's Workers and timers.

## Speech behaviour

The browser needs speech recognition, speech synthesis and a working microphone.
Recognition starts on an explicit microphone click. The chat explains how to
recover from unsupported recognition, blocked permissions and missing audio input.
Recognition may use the browser vendor's online service.
See [MDN's recognition documentation](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition).

Spoken replies use `speechSynthesis` and prefer a local English voice when one is
available. Prompts are batched briefly and replace stale utterances. The
microphone becomes available after the prompt finishes, and replies reach
the chart after recognition ends. Speech and recognition stop when
the page is hidden. The chart retries for silence only when the recognizer
reports `no-speech` after a microphone attempt. Waiting to tap the microphone
or waiting for a prompt to finish does not trigger a retry.

## Source layout

- `boxshop-voice.xml`: the running chart, whose utterances call `speak/2`.
- `boxshop-2.xml`: the original chart for comparison.
- `boxshop.pl`: a bounded, whole-utterance DCG mapping words to semantic events.
- `boxshop.js`: Worker lifecycle, browser speech adapter, transcript and inspector tabs.
- `voice.js`: browser speech transport, cancellation and stale-callback guards.
- `index.html` / `boxshop.css`: accessible controls and a responsive two-panel layout.

The browser escapes input as a Prolog text value, and the grammar never executes
it as a goal. All output and trace text use text nodes. A sent actor event is
acknowledged by its real `external_event` trace and subsequent stable chart
configuration before another reply is accepted. Restart generations filter late
callbacks from old Workers and speech recognizers.

The source uses the local Prettier configuration. From the repository root:

```sh
npx prettier@3.9.10 --write 'experiments/boxshop/*.{js,cjs,css,html}'
```

## Verification and packaging

```sh
swipl -f none -q -s experiments/boxshop/test_boxshop.pl -g run_tests -t halt
DEMO_URL=http://localhost:8094/ CHROME_PATH=/path/to/chrome \
  node experiments/boxshop/test_browser.cjs
```

The browser suite uses Playwright, the real WASM engine and the voice chart.
It checks a complete order, numeric rejection, spoken output, the inspector tabs,
restart, End and remedies for unavailable microphone access. Speech events are
simulated. Live microphone transcription and audible output require a manual test.

The homepage's `tools/package_boxshop.py` builds a self-contained static snapshot,
checks the reference chart against its committed original, verifies the runtime package,
retains licenses and records source revisions and all file hashes. Release builds
require committed application source and a clean runtime. `--working-tree` is
available for local previews. It never fetches or publishes on its own.
