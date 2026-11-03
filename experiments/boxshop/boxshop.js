import { BrowserVoice } from './voice.js';

const $ = (id) => document.getElementById(id);
const state = {
  loaded: false,
  node: null,
  pid: null,
  generation: 0,
  starting: false,
  busy: false,
  phase: null,
};
let chartSource = '',
  supportSource = '',
  pendingEvent = null;
let speechTimer = null,
  speechBatch = [];

const microphoneUnavailable =
  'Microphone unavailable. Open this HTTPS page directly in Chrome or another browser with speech recognition.';

const voice = new BrowserVoice({
  onTranscript(text) {
    voiceStatus('Reply recognised. Microphone off.');
    void sendReply(text);
  },
  onUnconfirmed(text) {
    voiceStatus('Microphone off. Tap to speak again.');
    void sendReply(text, false);
  },
  onNotice: voiceStatus,
  onChange: renderControls,
});

function voiceStatus(text, problem = false) {
  const status = $('voice-status');
  status.textContent = text;
  status.dataset.problem = String(problem);
  if (problem) log(text);
}

function renderControls() {
  const waiting = state.pid && ['Color', 'Size'].includes(state.phase);
  $('start').disabled = !state.loaded || !voice.canListen || !voice.canSpeak;
  $('end').disabled = !state.node && !state.starting;
  $('microphone').disabled =
    !waiting ||
    state.busy ||
    state.starting ||
    !voice.canListen ||
    speechTimer !== null ||
    Boolean(voice.utterance);
  $('microphone').setAttribute('aria-pressed', String(voice.listening));
  $('microphone').title = voice.listening ? 'Stop listening' : 'Start listening';
  if (state.starting) $('session-status').textContent = 'Starting the conversation…';
  else if (state.phase === 'Respond')
    $('session-status').textContent = 'Order complete.';
  else if (waiting)
    $('session-status').textContent =
      speechTimer !== null || voice.utterance
        ? 'The Box Shop is speaking…'
        : 'Waiting for your reply.';
}

function message(role, text) {
  const item = document.createElement('div');
  item.className = 'message ' + role;
  item.textContent = text;
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
    log(line);
    const prefix = 'BOXSHOP SPEAK: ';
    if (!line.startsWith(prefix)) continue;
    const spoken = line.slice(prefix.length);
    message('assistant', spoken);
    speechBatch.push(spoken);
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
    renderControls();
  }, 70);
  renderControls();
}

function log(text) {
  const line = document.createElement('li');
  line.textContent = text;
  $('trace').append(line);
  while ($('trace').children.length > 180) $('trace').firstElementChild.remove();
  $('trace').scrollTop = $('trace').scrollHeight;
}

function trace(text) {
  log(text);
  if (pendingEvent && text === `external_event(${pendingEvent.event})`)
    pendingEvent.seen = true;

  const configuration = /^configuration\(\[(.*)\]\)$/.exec(text);
  if (configuration) {
    const leaf = configuration[1].split(',').at(-1).replaceAll("'", '').trim();
    $('chart-state').textContent = leaf;
    if (['Welcome', 'Color', 'Size', 'Respond'].includes(leaf)) {
      state.phase = leaf;
      if (pendingEvent?.seen && ['Color', 'Size', 'Respond'].includes(leaf)) {
        const pending = pendingEvent;
        pendingEvent = null;
        clearTimeout(pending.timer);
        pending.resolve();
      }
    }
  }
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
  if (!state.loaded || !voice.canListen || !voice.canSpeak) return;
  retire();
  const generation = state.generation;
  state.starting = true;
  state.phase = null;
  $('conversation').replaceChildren();
  $('trace').replaceChildren();
  $('chart-state').textContent = 'Starting';
  renderControls();
  voiceStatus('Microphone off. Tap to speak after the question.');
  voice.prepareSpeech();
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
    // Supply the browser-specific speech transport alongside the chart.
    const answer = await node.query(`
      statechart_spawn(Pid, [
        trace(true),
        src_text(${node.prologQuotedText(chartSource)}),
        src_list([
          (speak(Template, Arguments) :-
            format(string(Text), Template, Arguments),
            format('BOXSHOP SPEAK: ~s~n', [Text]))
        ])
      ])
    `);
    if (generation !== state.generation) return;
    if (answer.type !== 'success' || !answer.data[0]?.Pid)
      throw new Error(answer.data || 'The statechart did not start');
    state.pid = answer.data[0].Pid;
    state.starting = false;
    renderControls();
  } catch (error) {
    if (generation !== state.generation) return;
    retire();
    state.phase = 'Error';
    renderControls();
    $('chart-state').textContent = 'Stopped';
    $('session-status').textContent = 'Could not start. Try (Re)start again.';
    message('system', error.message);
  }
}

async function sendReply(text, confirmed = true) {
  const reply = text.trim().slice(0, 160);
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
  clearSpeechBatch();
  message('user', reply);
  renderControls();
  try {
    // A provisional result is evidence of an attempt, not a confirmed reply.
    let event = 'says(unknown)';
    if (confirmed) {
      const parsed = await node.query(
        'boxshop_event(' + node.prologQuotedText(reply) + ', Event)'
      );
      if (generation !== state.generation) return;
      if (parsed.type !== 'success')
        throw new Error(parsed.data || 'Could not parse the reply');
      event = parsed.data[0].Event;
    }
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
$('end').addEventListener('click', () => {
  retire();
  state.phase = 'Ended';
  renderControls();
  $('chart-state').textContent = 'Ended';
  $('session-status').textContent = 'Session ended. Start again whenever you like.';
  voiceStatus('Microphone off.');
  message('system', 'Session ended.');
});
$('microphone').addEventListener('click', () => {
  if (voice.listening) {
    voice.stopListening();
    voiceStatus('Listening stopped. Tap to speak again when ready.');
  } else voice.listen();
});
const tabs = [...document.querySelectorAll('[role="tab"]')];

function selectTab(selected) {
  for (const tab of tabs) {
    const active = tab === selected;
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
    $(tab.getAttribute('aria-controls')).hidden = !active;
  }
  selected.focus();
}

for (const [index, tab] of tabs.entries()) {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (event) => {
    const next = {
      ArrowLeft: (index - 1 + tabs.length) % tabs.length,
      ArrowRight: (index + 1) % tabs.length,
      Home: 0,
      End: tabs.length - 1,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    selectTab(tabs[next]);
  });
}

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearSpeechBatch();
    voice.cancel();
  }
});
window.addEventListener('pagehide', retire);

async function boot() {
  renderControls();
  try {
    [chartSource, supportSource] = await Promise.all(
      ['boxshop-voice.xml', 'boxshop.pl'].map(async (name) => {
        const response = await fetch(name);
        if (!response.ok) throw new Error('Cannot load ' + name);
        return response.text();
      })
    );
    if (!window.SwiWasmNode) throw new Error('The browser runtime did not load');
    $('chart-source').textContent = chartSource;
    state.loaded = true;
    renderControls();
    $('grammar-source').textContent = supportSource;
    $('session-status').textContent =
      voice.canListen && voice.canSpeak
        ? 'Press (Re)start to begin.'
        : 'Speech is unavailable.';
    if (!voice.canListen) voiceStatus(microphoneUnavailable, true);
    else if (!voice.canSpeak)
      voiceStatus(
        'Spoken output is unavailable. Try a browser with speech synthesis enabled.',
        true
      );
    else voiceStatus('Microphone off until you tap to speak.');
  } catch (error) {
    $('session-status').textContent = 'Could not load the demo. Reload to try again.';
    voiceStatus(error.message, true);
  }
}

if (document.readyState === 'loading')
  document.addEventListener('DOMContentLoaded', boot, { once: true });
else void boot();
