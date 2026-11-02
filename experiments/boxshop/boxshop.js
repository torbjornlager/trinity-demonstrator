import { BrowserVoice } from './voice.js';

const $ = (id) => document.getElementById(id);
const palette = {
  red: '#bd6354',
  blue: '#6b91ad',
  green: '#74927a',
  yellow: '#d8b45e',
  purple: '#9a83ad',
  orange: '#ca8c55',
  black: '#50534e',
  white: '#dad8c9',
};
const state = {
  loaded: false,
  node: null,
  pid: null,
  generation: 0,
  starting: false,
  busy: false,
  phase: null,
  color: null,
  size: null,
  lastPrompt: '',
};
let chartSource = '',
  supportSource = '',
  pendingEvent = null;
let speechTimer = null,
  speechBatch = [];

const voice = new BrowserVoice({
  onTranscript(text) {
    $('voice-status').textContent = 'Heard “' + text + '”. Microphone off.';
    void sendReply(text, 'voice');
  },
  onNotice(text) {
    $('voice-status').textContent = text;
  },
  onChange() {
    renderControls();
  },
});

function renderControls() {
  const waiting = Boolean(state.pid && ['Color', 'Size'].includes(state.phase));
  const editable = waiting && !state.busy && !state.starting;
  $('start').hidden = Boolean(state.node) || state.starting;
  $('start').disabled = !state.loaded || state.starting;
  $('restart').disabled =
    !state.loaded || state.starting || (!state.node && !state.phase);
  $('end').disabled = !state.node && !state.starting;
  $('reply').disabled = !editable;
  $('send').disabled = !editable;
  $('reply-help').textContent =
    state.phase === 'Size'
      ? 'Try “small” or “large, please”.'
      : 'Try “blue” or “a blue box”. Answer one question at a time.';
  $('reply').placeholder =
    state.phase === 'Size' ? 'Try “large, please”' : 'Try “blue, please”';
  $('microphone').disabled = !editable || !voice.canListen;
  $('microphone').setAttribute('aria-pressed', String(voice.listening));
  $('microphone').replaceChildren();
  const icon = document.createElement('span');
  icon.setAttribute('aria-hidden', 'true');
  icon.textContent = '◉';
  $('microphone').append(icon, voice.listening ? ' Stop listening' : ' Tap to speak');
  $('spoken').disabled = !voice.canSpeak;
  $('replay').disabled =
    !state.lastPrompt || !voice.spoken || voice.listening || state.busy;
  for (const button of $('choices').querySelectorAll('button'))
    button.disabled = !editable;
  $('live-dot').classList.toggle('active', waiting || state.starting);
  if (state.starting) $('session-status').textContent = 'Opening the browser engine…';
  else if (state.phase === 'Respond')
    $('session-status').textContent = 'Order complete. Thanks for stopping by.';
  else if (state.phase === 'Color')
    $('session-status').textContent = 'Choosing a colour · 8-second retry';
  else if (state.phase === 'Size')
    $('session-status').textContent = 'Choosing a size · 8-second retry';
}

function message(role, text, origin = '') {
  $('conversation-empty')?.remove();
  const item = document.createElement('div');
  item.className = 'message ' + role;
  const label = document.createElement('small');
  label.textContent =
    role === 'assistant'
      ? 'BOX SHOP'
      : role === 'user'
        ? origin === 'voice'
          ? 'YOU · VOICE'
          : 'YOU'
        : 'SESSION';
  item.append(label, document.createTextNode(text));
  $('conversation').append(item);
  while ($('conversation').children.length > 100)
    $('conversation').firstElementChild.remove();
  $('conversation').scrollTop = $('conversation').scrollHeight;
}

function clearSpeechBatch() {
  clearTimeout(speechTimer);
  speechTimer = null;
  speechBatch = [];
}

function output(text) {
  for (const line of String(text)
    .split(/\r?\n/)
    .filter((line) => line.trim())) {
    message('assistant', line);
    state.lastPrompt = line;
    speechBatch.push(line);
  }
  // A single transition can print both a welcome and a question. Speak them
  // together and replace stale prompts, rather than building an unbounded queue.
  clearTimeout(speechTimer);
  const generation = state.generation;
  speechTimer = setTimeout(() => {
    const text = speechBatch.join(' ');
    speechBatch = [];
    speechTimer = null;
    if (generation === state.generation && text && !document.hidden) voice.speak(text);
  }, 70);
  renderControls();
}

function choices(phase) {
  $('choices').replaceChildren();
  const values =
    phase === 'Color' ? Object.keys(palette) : phase === 'Size' ? ['small', 'big'] : [];
  for (const value of values) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = value[0].toUpperCase() + value.slice(1);
    if (phase === 'Color') button.style.setProperty('--swatch', palette[value]);
    else button.className = 'size-choice';
    button.addEventListener('click', () => {
      void sendReply(value, 'choice');
    });
    $('choices').append(button);
  }
}

function product() {
  $('selected-color').textContent = state.color
    ? state.color[0].toUpperCase() + state.color.slice(1)
    : 'Your choice';
  $('selected-size').textContent = state.size
    ? state.size[0].toUpperCase() + state.size.slice(1)
    : 'Your choice';
  $('box').style.setProperty('--box-color', palette[state.color] || '#93a89c');
  $('box').dataset.size = state.size || '';
  $('order-complete').hidden = state.phase !== 'Respond';
  $('order-summary').textContent =
    state.color && state.size ? `A ${state.size} ${state.color} box.` : '';
  for (const step of document.querySelectorAll('[data-state]')) {
    const id = step.dataset.state;
    step.classList.toggle('active', id === state.phase);
    step.classList.toggle(
      'done',
      (id === 'Welcome' && Boolean(state.pid)) ||
        (id === 'Color' && Boolean(state.color)) ||
        (id === 'Size' && Boolean(state.size))
    );
    if (id === state.phase) step.setAttribute('aria-current', 'step');
    else step.removeAttribute('aria-current');
  }
}

function trace(text) {
  const line = document.createElement('li');
  line.textContent = text;
  $('trace').append(line);
  while ($('trace').children.length > 180) $('trace').firstElementChild.remove();
  $('trace').scrollTop = $('trace').scrollHeight;
  $('last-event').textContent = text;
  if (pendingEvent && text === `external_event(${pendingEvent.event})`)
    pendingEvent.seen = true;

  // These observations come from the real chart trace, not from a second
  // JavaScript dialogue controller. The fixed chart uses simple atom slots.
  const color = /^execution\(assert\(color\(([a-z]+)\)\)\)$/.exec(text);
  const size = /^execution\(assert\(size\((small|big)\)\)\)$/.exec(text);
  if (color) state.color = color[1];
  if (size) state.size = size[1];
  const configuration = /^configuration\(\[(.*)\]\)$/.exec(text);
  if (configuration) {
    const leaf = configuration[1].split(',').at(-1).replaceAll("'", '').trim();
    $('chart-state').textContent = leaf;
    if (['Welcome', 'Color', 'Size', 'Respond'].includes(leaf)) {
      if (state.phase !== leaf) choices(leaf);
      state.phase = leaf;
      if (pendingEvent?.seen && ['Color', 'Size', 'Respond'].includes(leaf)) {
        const pending = pendingEvent;
        pendingEvent = null;
        clearTimeout(pending.timer);
        pending.resolve();
      }
    }
  }
  product();
  renderControls();
}

function cancelPending(reason) {
  if (!pendingEvent) return;
  const pending = pendingEvent;
  pendingEvent = null;
  clearTimeout(pending.timer);
  pending.reject(new Error(reason));
}

function retire() {
  state.generation++;
  cancelPending('Session ended');
  clearSpeechBatch();
  voice.cancel();
  const old = state.node;
  state.node = null;
  state.pid = null;
  state.starting = false;
  state.busy = false;
  old?.dispose();
}

async function start() {
  if (!state.loaded || state.starting) return;
  retire();
  const generation = state.generation;
  state.starting = true;
  state.phase = null;
  state.color = null;
  state.size = null;
  state.lastPrompt = '';
  $('conversation').replaceChildren();
  $('trace').replaceChildren();
  $('reply').value = '';
  $('chart-state').textContent = 'Starting';
  $('last-event').textContent = 'Starting the statechart…';
  choices(null);
  product();
  renderControls();
  $('voice-status').textContent = voice.canListen
    ? 'Microphone off. Tap to speak after the assistant asks a question.'
    : 'Speech input is unavailable in this browser. You can type or tap a choice.';
  const node = SwiWasmNode.create({
    workerUrl: new URL('runtime/swi_wasm_actor_worker.js', location.href).href,
    engineUrl: new URL('runtime/swipl-bundle.js', location.href).href,
    prologBaseUrl: new URL('runtime/wasm/', location.href).href,
    sharedDatabaseUrl: null,
    onEvent(event) {
      if (generation !== state.generation) return false;
      if (event.type === 'output') output(event.data);
      if (event.type === 'statechart_trace') trace(event.data);
      return true;
    },
  });
  state.node = node;
  try {
    await node.open({ source: supportSource });
    if (generation !== state.generation) return;
    const answer = await node.query(
      'statechart_spawn(Pid,[trace(true),src_text(' +
        node.prologQuotedText(chartSource) +
        ')])'
    );
    if (generation !== state.generation) return;
    if (answer.type !== 'success' || !answer.data[0]?.Pid)
      throw new Error(answer.data || 'The statechart did not start');
    state.pid = answer.data[0].Pid;
    state.starting = false;
    product();
    renderControls();
  } catch (error) {
    if (generation !== state.generation) return;
    retire();
    state.phase = 'Error';
    choices(null);
    renderControls();
    $('chart-state').textContent = 'Stopped';
    $('session-status').textContent = 'Could not start. Try Start shopping again.';
    message('system', error.message);
  }
}

async function sendReply(text, origin = 'typed') {
  const reply = String(text).trim().slice(0, 160);
  if (
    !reply ||
    state.busy ||
    state.starting ||
    !state.pid ||
    !['Color', 'Size'].includes(state.phase)
  )
    return;
  const generation = state.generation,
    node = state.node,
    pid = state.pid;
  state.busy = true;
  voice.stopListening();
  voice.cancelSpeech();
  clearSpeechBatch();
  $('reply').value = '';
  message('user', reply, origin);
  renderControls();
  try {
    const parsed = await node.query(
      'boxshop_event(' + node.prologQuotedText(reply) + ', Event)'
    );
    if (generation !== state.generation) return;
    if (parsed.type !== 'success')
      throw new Error(parsed.data || 'Could not parse the reply');
    const event = parsed.data[0].Event;
    // Sending to an actor is asynchronous. Wait for its corresponding external
    // event and stable configuration before accepting another UI reply.
    const changed = new Promise((resolve, reject) => {
      pendingEvent = {
        event,
        seen: false,
        resolve,
        reject,
        timer: setTimeout(() => {
          pendingEvent = null;
          reject(new Error('The chart did not respond. Please start over.'));
        }, 5000),
      };
    });
    // Observe rejection immediately if the transport fails before the trace arrives.
    changed.catch(() => {});
    const sent = await node.query(pid + ' ! ' + event);
    if (sent.type !== 'success')
      throw new Error(sent.data || 'Could not send the reply');
    await changed;
  } catch (error) {
    if (generation !== state.generation) return;
    retire();
    state.phase = 'Error';
    choices(null);
    $('chart-state').textContent = 'Stopped';
    $('session-status').textContent = 'Session stopped. Start a new conversation.';
    message('system', error.message);
  } finally {
    if (generation === state.generation) state.busy = false;
    renderControls();
  }
}

$('start').addEventListener('click', () => {
  void start();
});
$('restart').addEventListener('click', () => {
  void start();
});
$('end').addEventListener('click', () => {
  retire();
  state.phase = 'Ended';
  choices(null);
  product();
  renderControls();
  $('chart-state').textContent = 'Ended';
  $('session-status').textContent = 'Session ended. Start again whenever you like.';
  message('system', 'Session ended. Your next conversation starts with a fresh chart.');
});
$('reply-form').addEventListener('submit', (event) => {
  event.preventDefault();
  void sendReply($('reply').value);
});
$('microphone').addEventListener('click', () => {
  if (voice.listening) {
    voice.stopListening();
    $('voice-status').textContent = 'Microphone off.';
  } else voice.listen();
});
$('spoken').addEventListener('change', () => {
  voice.setSpoken($('spoken').checked);
  renderControls();
});
$('replay').addEventListener('click', () => voice.speak(state.lastPrompt));
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearSpeechBatch();
    voice.cancel();
  }
});
window.addEventListener('pagehide', retire);

async function boot() {
  $('spoken').checked = voice.canSpeak;
  renderControls();
  try {
    [chartSource, supportSource] = await Promise.all(
      ['boxshop-2.xml', 'boxshop.pl'].map(async (name) => {
        const response = await fetch(name);
        if (!response.ok) throw new Error('Cannot load ' + name);
        return response.text();
      })
    );
    if (!window.SwiWasmNode) throw new Error('The browser runtime did not load');
    $('chart-source').textContent = chartSource;
    state.loaded = true;
    renderControls();
    if (!voice.canListen)
      $('voice-status').textContent =
        'Speech input is unavailable in this browser. You can always type or use the choices.';
  } catch (error) {
    $('session-status').textContent = 'Could not load the demo. Reload to try again.';
    $('voice-status').textContent = error.message;
  }
}

if (document.readyState === 'loading')
  document.addEventListener('DOMContentLoaded', boot, { once: true });
else void boot();
