# The Box Shop — a statechart with a voice interface

A browser-only demo of the form-filling agent in
[`12 boxshop-2.xml`](../../examples/statecharts/12%20boxshop-2.xml).
The XML in this directory is an unchanged copy of that example. A real SWI-WASM
statechart actor owns the dialogue, welcome/colour/size slots, eight-second
retries, unrecognised-input fallback and final order message. Nothing is bought
or stored by the demo.

The interface offers optional browser speech recognition, spoken chart output,
a text field and choice buttons. All input paths pass through the same Prolog
grammar and send the same `says(color(...))` / `says(size(...))` events. The UI
observes the actual chart trace to highlight its state and update the box preview;
it does not implement a second dialogue state machine in JavaScript.

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

Press **Start shopping**, then type, tap a colour, or press **Tap to speak**.
Try “blue”, “a blue box”, “small”, or “large, please”. Answer one question at a
time. The grammar maps “large” to `big` and “little” to `small`. Other replies
are delivered as `says(unknown)` so the chart itself handles the retry.
**Start over** creates a fresh session; **End session** cancels speech, stops
recognition and disposes the chart's Workers and timers.

## Speech behaviour

Speech recognition uses the browser's `SpeechRecognition` or prefixed equivalent.
It is optional, starts only on an explicit microphone click, and never restarts
itself automatically. Unsupported browsers, blocked permissions and service
errors leave text and buttons available. Status messages distinguish service
startup, audio capture, detected speech, missing final results and a manual stop;
“listening” alone does not establish that usable audio reached recognition. Recognition may use the browser vendor's
online service; this app provides no server, API key or separate speech account.
See [MDN's recognition documentation](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition).

Spoken replies use `speechSynthesis` and prefer a local English voice when one is
available. Prompts are batched briefly and replace stale utterances; starting
recognition interrupts speech to avoid echo. Speech and recognition stop when
the page is hidden. The chart keeps its original timer: it retries eight seconds
after entering a question, including time spent speaking or waiting for microphone
permission. Background messages remain in the transcript but are not spoken.

## Source layout

- `boxshop-2.xml`: the unmodified dialogue and its Prolog datamodel.
- `boxshop.pl`: a bounded, whole-utterance DCG mapping words to semantic events.
- `boxshop.js`: Worker lifecycle, event acknowledgements, transcript and preview.
- `voice.js`: browser speech transport, cancellation and stale-callback guards.
- `index.html` / `boxshop.css`: accessible controls and a responsive CSS box.

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

The browser suite requires Playwright on Node's module path. It uses real WASM
and the exact XML to check both actual eight-second timeouts, unknown replies,
slot selection, completion, restart, End, mobile layout and resource cancellation.
Only the browser speech service is stubbed: tests exercise interim/final
recognition events, spoken output, denied/absent APIs, stale results and hidden
page behaviour. Live microphone transcription and audible voice quality must be
checked manually in a browser with working speech services.

The homepage's `tools/package_boxshop.py` builds a self-contained static snapshot,
checks the XML against its committed original, verifies the runtime package,
retains licenses and records source revisions and all file hashes. Release builds
require committed application source and a clean runtime. `--working-tree` is
available for local previews. It never fetches or publishes on its own.
