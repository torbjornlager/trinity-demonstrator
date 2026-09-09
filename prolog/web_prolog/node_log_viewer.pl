:- module(node_log_viewer, []).

/** <module> Secret interaction-log viewer.

Exposes a token-gated viewer for the durable interaction log at:

  - GET /__viewer/<token>               — HTML viewer
  - GET /__viewer/<token>/data          — JSON tail of recent events
  - GET /__viewer/<token>/csv           — CSV export of recent events
  - GET /__viewer/<token>/tag/owner     — set the `wp_owner` cookie
  - GET /__viewer/<token>/tag/clear     — clear the `wp_owner` cookie

The token is read from the `WEB_PROLOG_VIEWER_TOKEN` environment
variable; when unset the routes return 404.
*/

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_header)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(readutil)).

:- use_module(node_interaction_log, [current_interaction_log_file/1]).
:- use_module(node_owner_tag, [viewer_token/1, secure_eq_text/2]).


:- http_handler(root('__viewer'), viewer_dispatch, [prefix]).


viewer_dispatch(Request) :-
    memberchk(path(Path), Request),
    atom_concat('/__viewer', Tail0, Path),
    !,
    dispatch_viewer(Tail0, Request).
viewer_dispatch(Request) :-
    http_404([], Request).


dispatch_viewer(Tail, Request) :-
    (   viewer_token(Token)
    ->  parse_viewer_tail(Tail, Token, Action),
        run_viewer_action(Action, Request)
    ;   http_404([], Request)
    ).


parse_viewer_tail('', _, not_found) :- !.
parse_viewer_tail('/', _, not_found) :- !.
parse_viewer_tail(Tail, Token, Action) :-
    atom_string(Tail, TailStr),
    split_string(TailStr, "/", "", ["", PathTokenStr|Rest]),
    !,
    (   secure_eq_text(PathTokenStr, Token)
    ->  classify_viewer_segments(Rest, Action)
    ;   Action = not_found
    ).
parse_viewer_tail(_, _, not_found).


classify_viewer_segments([], page) :- !.
classify_viewer_segments([""], page) :- !.
classify_viewer_segments(["data"], data) :- !.
classify_viewer_segments(["data", ""], data) :- !.
classify_viewer_segments(["csv"], csv) :- !.
classify_viewer_segments(["csv", ""], csv) :- !.
classify_viewer_segments(["tag", "owner"], tag_owner) :- !.
classify_viewer_segments(["tag", "owner", ""], tag_owner) :- !.
classify_viewer_segments(["tag", "clear"], tag_clear) :- !.
classify_viewer_segments(["tag", "clear", ""], tag_clear) :- !.
classify_viewer_segments(_, not_found).


run_viewer_action(not_found, Request) :-
    !,
    http_404([], Request).
run_viewer_action(page, _Request) :-
    !,
    serve_viewer_page.
run_viewer_action(data, Request) :-
    !,
    serve_viewer_data(Request).
run_viewer_action(csv, Request) :-
    !,
    serve_viewer_csv(Request).
run_viewer_action(tag_owner, Request) :-
    !,
    serve_tag_set(Request).
run_viewer_action(tag_clear, Request) :-
    !,
    serve_tag_clear(Request).


                 /*******************************
                 *          HTML PAGE           *
                 *******************************/

serve_viewer_page :-
    viewer_html(Html),
    format('Status: 200 OK~n'),
    format('Content-Type: text/html; charset=UTF-8~n'),
    format('Cache-Control: no-store, no-cache, must-revalidate, max-age=0~n'),
    format('Referrer-Policy: no-referrer~n'),
    format('X-Robots-Tag: noindex, nofollow, noarchive~n'),
    format('X-Frame-Options: DENY~n'),
    format('~n'),
    format('~s', [Html]).


viewer_html(Html) :-
    Html = "<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"robots\" content=\"noindex, nofollow, noarchive\">
<meta name=\"referrer\" content=\"no-referrer\">
<title>Interaction log</title>
<style>
  body { font: 13px/1.4 -apple-system, system-ui, sans-serif; margin: 0; padding: 1rem; background: #111; color: #ddd; }
  h1 { font-size: 1rem; margin: 0 0 .75rem; color: #fff; }
  .controls { display: flex; gap: 1rem; align-items: center; flex-wrap: wrap; margin-bottom: .5rem; }
  .controls label { white-space: nowrap; }
  #summary { display: flex; gap: .5rem; flex-wrap: wrap; margin: 0 0 .75rem; color: #aaa; }
  #breakdowns { display: grid; gap: .6rem; grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr)); margin: 0 0 .75rem; }
  .breakdown { border: 1px solid #282828; background: #151515; padding: .45rem .55rem; }
  .breakdown h2 { font-size: 12px; margin: 0 0 .35rem; color: #aaa; font-weight: 600; }
  .breakdown ol { margin: 0; padding-left: 1.4rem; }
  .breakdown li { margin: .12rem 0; display: flex; justify-content: space-between; gap: .75rem; }
  .breakdown .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .breakdown .n { color: #aaa; font-variant-numeric: tabular-nums; }
  .breakdown.wide { grid-column: 1 / -1; }
  .daily { width: 100%; table-layout: fixed; }
  .daily th { position: static; }
  .daily th, .daily td { text-align: right; }
  .daily th:first-child, .daily td:first-child { text-align: left; }
  .notice { margin: 0 0 .75rem; padding: .45rem .6rem; border: 1px solid #665; background: #211f16; color: #ddc; display: none; }
  input[type=text] { background: #222; color: #ddd; border: 1px solid #444; padding: .25rem .4rem; min-width: 14rem; }
  button { background: #333; color: #ddd; border: 1px solid #555; padding: .25rem .6rem; cursor: pointer; }
  button:hover { background: #444; }
  #status { color: #888; font-size: 12px; margin-left: auto; }
  table { border-collapse: collapse; width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
  th, td { text-align: left; padding: 3px 6px; border-bottom: 1px solid #222; vertical-align: top; }
  th { background: #1a1a1a; position: sticky; top: 0; color: #aaa; font-weight: 600; }
  tr.owner { color: #777; }
  tr.owner td.tag::before { content: '\\1F511 '; color: #c93; }
  tr.agent { color: #9b8; }
  tr.agent td.tag::before { content: '\\1F916 '; color: #6c9; }
  td.event { color: #6cf; }
  td.client { color: #aaa; }
  td.extra { color: #bbb; white-space: pre-wrap; word-break: break-word; max-width: 32rem; }
  .pill { display: inline-block; padding: 0 .35rem; border-radius: 3px; background: #2a2a2a; color: #ddd; font-size: 11px; }
  a, a:visited { color: #6af; }
</style>
</head>
<body>
<h1>Interaction log <span class=\"pill\" id=\"count\">0 shown / 0 loaded</span></h1>
<div class=\"controls\">
  <label><input type=\"checkbox\" id=\"hideOwner\" checked> Hide owner</label>
  <label><input type=\"checkbox\" id=\"hideAgent\" checked> Hide agent</label>
  <label><input type=\"checkbox\" id=\"publicOnly\"> Public only</label>
  <label>Device
    <select id=\"deviceFilter\">
      <option value=\"\">(any)</option>
      <option value=\"ipad\">ipad</option>
      <option value=\"iphone\">iphone</option>
      <option value=\"android-phone\">android-phone</option>
      <option value=\"android-tablet\">android-tablet</option>
      <option value=\"mac\">mac</option>
      <option value=\"windows\">windows</option>
      <option value=\"linux\">linux</option>
      <option value=\"chromeos\">chromeos</option>
      <option value=\"other\">other</option>
      <option value=\"__none__\">(no device)</option>
    </select>
  </label>
  <label><input type=\"checkbox\" id=\"tail\" checked> Tail</label>
  <label>Since <input type=\"date\" id=\"sinceDate\"></label>
  <button id=\"allDates\">All dates</button>
  <label>Filter <input type=\"text\" id=\"filter\" placeholder=\"substring (event/client/route/...)\"></label>
  <button id=\"clear\">Clear view</button>
  <button id=\"downloadVisible\">Download visible CSV</button>
  <button id=\"downloadRecent\">Download recent CSV</button>
  <button id=\"tagOwner\">Mark this browser as owner</button>
  <button id=\"tagClear\">Clear owner tag</button>
  <span id=\"status\">idle</span>
</div>
<div id=\"summary\"></div>
<div id=\"breakdowns\"></div>
<div id=\"localeNotice\" class=\"notice\"></div>
<div id=\"networkNotice\" class=\"notice\"></div>
<table>
  <thead><tr>
    <th>At</th><th>Event</th><th>Who</th><th>Route</th><th>Device</th><th>TZ</th><th>Lang</th><th>Source</th><th>Tag</th><th>Extra</th>
  </tr></thead>
  <tbody id=\"rows\"></tbody>
</table>
<script>
  const $ = (id) => document.getElementById(id);
  const rowsEl = $('rows');
  const summaryEl = $('summary');
  const breakdownsEl = $('breakdowns');
  const localeNoticeEl = $('localeNotice');
  const networkNoticeEl = $('networkNotice');
  const statusEl = $('status');
  const countEl = $('count');
  const hideOwnerEl = $('hideOwner');
  const hideAgentEl = $('hideAgent');
  const publicOnlyEl = $('publicOnly');
  const deviceFilterEl = $('deviceFilter');
  const tailEl = $('tail');
  const sinceDateEl = $('sinceDate');
  const filterEl = $('filter');
  let lastTs = 0;
  let events = [];
  let sinceDatePreferenceLoaded = false;
  const MAX_KEEP = 5000;

  const HIDE_KEYS = new Set(['at','ts','event','client_id','route','source','peer','proxy_peer','principal','user_agent','owner','agent','device','timezone','language']);
  const CSV_COLUMNS = ['at','event','client_id','peer','proxy_peer','principal','owner','agent','route','source','device','timezone','language','example','example_label','example_url','source_kind','transport','origin'];

  function fmtExtra(e) {
    const extra = {};
    for (const k of Object.keys(e)) if (!HIDE_KEYS.has(k)) extra[k] = e[k];
    if (Object.keys(extra).length === 0) return '';
    return JSON.stringify(extra);
  }

  function passesFilter(e) {
    if (publicOnlyEl.checked) {
      if (e.owner === true || e.agent) return false;
    } else {
      if (hideOwnerEl.checked && e.owner === true) return false;
      if (hideAgentEl.checked && e.agent) return false;
    }
    const dev = deviceFilterEl.value;
    if (dev === '__none__') {
      if (e.device) return false;
    } else if (dev) {
      if (e.device !== dev) return false;
    }
    const since = sinceDateEl.value;
    if (since && eventDay(e) < since) return false;
    const f = filterEl.value.trim().toLowerCase();
    if (!f) return true;
    return JSON.stringify(e).toLowerCase().includes(f);
  }

  function render() {
    const f = document.createDocumentFragment();
    let shown = 0;
    const shownEvents = [];
    for (let i = events.length - 1; i >= 0; i--) {
      const e = events[i];
      if (!passesFilter(e)) continue;
      shownEvents.push(e);
      const tr = document.createElement('tr');
      if (e.owner === true) tr.classList.add('owner');
      else if (e.agent) tr.classList.add('agent');
      const tagText = e.owner === true ? 'owner' : (e.agent ? String(e.agent) : '');
      const peer = e.peer || '';
      const cid  = e.client_id || '';
      const who  = (cid && cid !== 'peer:' + peer) ? cid : peer;
      tr.innerHTML =
        '<td>' + esc(e.at || '') + '</td>' +
        '<td class=\"event\">' + esc(e.event || '') + '</td>' +
        '<td class=\"client\">' + esc(who) + '</td>' +
        '<td>' + esc(e.route || '') + '</td>' +
        '<td>' + esc(e.device || '') + '</td>' +
        '<td>' + esc(e.timezone || '') + '</td>' +
        '<td>' + esc(e.language || '') + '</td>' +
        '<td>' + esc(e.source || '') + '</td>' +
        '<td class=\"tag\">' + esc(tagText) + '</td>' +
        '<td class=\"extra\">' + esc(fmtExtra(e)) + '</td>';
      f.appendChild(tr);
      shown++;
    }
    rowsEl.replaceChildren(f);
    countEl.textContent = shown + ' shown / ' + events.length + ' loaded';
    updateSummary(shownEvents);
  }

  function updateSummary(list) {
    const peers = new Set();
    const timezones = new Set();
    const languages = new Set();
    const loadedTimezones = distinctValues(events, e => e.timezone);
    const loadedLanguages = distinctValues(events, e => e.language);
    const counts = new Map();
    for (const e of list) {
      if (e.peer) peers.add(String(e.peer));
      if (e.timezone) timezones.add(String(e.timezone));
      if (e.language) languages.add(String(e.language));
      const name = String(e.event || '');
      counts.set(name, (counts.get(name) || 0) + 1);
    }
    const eventBits = Array.from(counts.entries())
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, 8)
      .map(([name, n]) => '<span class=\"pill\">' + esc(name) + ': ' + n + '</span>');
    summaryEl.innerHTML =
      '<span class=\"pill\">visible: ' + list.length + '</span>' +
      '<span class=\"pill\">loaded: ' + events.length + '</span>' +
      '<span class=\"pill\">visible peers: ' + peers.size + '</span>' +
      '<span class=\"pill\">visible timezones: ' + timezones.size + '</span>' +
      '<span class=\"pill\">loaded timezones: ' + loadedTimezones.size + '</span>' +
      '<span class=\"pill\">visible languages: ' + languages.size + '</span>' +
      '<span class=\"pill\">loaded languages: ' + loadedLanguages.size + '</span>' +
      eventBits.join('');
    breakdownsEl.innerHTML =
      renderDailyActivity(list, 14) +
      renderBreakdown('Examples', countBy(list, exampleName), 10) +
      renderBreakdown('Browser events', countBy(list.filter(e => e.source === 'browser'), e => e.event), 8) +
      renderBreakdown('Server events', countBy(list.filter(e => e.source === 'server'), e => e.event), 8) +
      renderBreakdown('Timezones', countBy(list, e => e.timezone), 8) +
      renderBreakdown('Languages', countBy(list, e => e.language), 8);

    if ((timezones.size === 0 && loadedTimezones.size > 0) ||
        (languages.size === 0 && loadedLanguages.size > 0)) {
      localeNoticeEl.style.display = 'block';
      localeNoticeEl.textContent =
        'Timezone/language values exist in the loaded data, but the current filters hide those rows. Try unchecking Hide owner/Hide agent or clearing filters.';
    } else if (loadedTimezones.size === 0 && loadedLanguages.size === 0) {
      localeNoticeEl.style.display = 'block';
      localeNoticeEl.textContent =
        'Timezone/language columns are only populated by browser events from portal pages loaded after the telemetry update; older rows cannot be backfilled.';
    } else {
      localeNoticeEl.style.display = 'none';
      localeNoticeEl.textContent = '';
    }

    const peerList = Array.from(peers);
    const privatePeers = peerList.filter(isPrivatePeer);
    if (peerList.length > 0 && privatePeers.length === peerList.length) {
      networkNoticeEl.style.display = 'block';
      networkNoticeEl.textContent =
        'All visible peer addresses are private/local addresses. If this page is showing public traffic, the real client IP is being hidden by the current proxy/Docker networking path, so country information cannot be inferred from these records.';
    } else {
      networkNoticeEl.style.display = 'none';
      networkNoticeEl.textContent = '';
    }
  }

  function isPrivatePeer(peer) {
    const s = String(peer || '').split(':')[0];
    return s === '127.0.0.1' ||
      s === '::1' ||
      /^10\\./.test(s) ||
      /^192\\.168\\./.test(s) ||
      /^172\\.(1[6-9]|2\\d|3[0-1])\\./.test(s);
  }

  function exampleName(e) {
    return e.example_label || e.example || e.example_url || '';
  }

  function countBy(list, fn) {
    const counts = new Map();
    for (const e of list) {
      const raw = fn(e);
      if (raw === undefined || raw === null || raw === '') continue;
      const key = String(raw);
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    return counts;
  }

  function distinctValues(list, fn) {
    const values = new Set();
    for (const e of list) {
      const raw = fn(e);
      if (raw !== undefined && raw !== null && raw !== '') values.add(String(raw));
    }
    return values;
  }

  function renderBreakdown(title, counts, limit) {
    const rows = Array.from(counts.entries())
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, limit);
    if (rows.length === 0) return '';
    return '<section class=\"breakdown\"><h2>' + esc(title) + '</h2><ol>' +
      rows.map(([name, n]) =>
        '<li><span class=\"name\" title=\"' + esc(name) + '\">' + esc(name) +
        '</span><span class=\"n\">' + n + '</span></li>').join('') +
      '</ol></section>';
  }

  function renderDailyActivity(list, limit) {
    const days = new Map();
    for (const e of list) {
      const day = eventDay(e);
      if (!day) continue;
      if (!days.has(day)) {
        days.set(day, { total: 0, portal_load: 0, portal_view: 0, tutorial_call: 0, example_spawn: 0 });
      }
      const row = days.get(day);
      row.total++;
      if (Object.prototype.hasOwnProperty.call(row, e.event)) row[e.event]++;
    }
    const rows = Array.from(days.entries())
      .sort((a, b) => b[0].localeCompare(a[0]))
      .slice(0, limit);
    if (rows.length === 0) return '';
    return '<section class=\"breakdown wide\"><h2>Activity by day</h2>' +
      '<table class=\"daily\"><thead><tr>' +
      '<th>Day</th><th>Total</th><th>Portal served</th><th>Portal viewed</th><th>Tutorial calls</th><th>Example spawns</th>' +
      '</tr></thead><tbody>' +
      rows.map(([day, row]) =>
        '<tr><td>' + esc(day) + '</td>' +
        '<td>' + row.total + '</td>' +
        '<td>' + row.portal_load + '</td>' +
        '<td>' + row.portal_view + '</td>' +
        '<td>' + row.tutorial_call + '</td>' +
        '<td>' + row.example_spawn + '</td></tr>').join('') +
      '</tbody></table></section>';
  }

  function eventDay(e) {
    const at = String(e.at || '');
    if (/^\\d{4}-\\d{2}-\\d{2}/.test(at)) return at.slice(0, 10);
    if (typeof e.ts === 'number') return new Date(e.ts * 1000).toISOString().slice(0, 10);
    return '';
  }

  function esc(s) {
    return String(s).replace(/[&<>\"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));
  }

  function csvCell(value) {
    if (value === undefined || value === null) return '';
    const s = String(value);
    if (/[\",\\r\\n]/.test(s)) return '\"' + s.replace(/\"/g, '\"\"') + '\"';
    return s;
  }

  function eventsToCsv(list) {
    const lines = [CSV_COLUMNS.join(',')];
    for (const e of list) {
      lines.push(CSV_COLUMNS.map(k => csvCell(e[k])).join(','));
    }
    return lines.join('\\n') + '\\n';
  }

  function downloadCsv(name, list) {
    const blob = new Blob([eventsToCsv(list)], { type: 'text/csv;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  const basePath = location.pathname.replace(/\\/$/, '');
  function subPath(suffix) { return basePath + '/' + suffix; }

  async function fetchData() {
    try {
      const url = new URL(subPath('data'), location.origin);
      if (lastTs) url.searchParams.set('since', String(lastTs));
      url.searchParams.set('limit', '2000');
      const r = await fetch(url.toString(), { credentials: 'include' });
      if (!r.ok) { statusEl.textContent = 'http ' + r.status; return; }
      const j = await r.json();
      const newEvents = j.events || [];
      if (newEvents.length > 0) {
        if (lastTs === 0) {
          events = newEvents;
        } else {
          events = events.concat(newEvents);
        }
        if (events.length > MAX_KEEP) events = events.slice(-MAX_KEEP);
        lastTs = events[events.length - 1].ts || lastTs;
        render();
      } else if (lastTs === 0) {
        render();
      }
      statusEl.textContent = 'updated ' + new Date().toLocaleTimeString();
    } catch (err) {
      statusEl.textContent = 'error: ' + err.message;
    }
  }

  const PREFS_KEY = 'wp_viewer_prefs';

  function savePrefs() {
    try {
      localStorage.setItem(PREFS_KEY, JSON.stringify({
        hideOwner:  hideOwnerEl.checked,
        hideAgent:  hideAgentEl.checked,
        publicOnly: publicOnlyEl.checked,
        tail:       tailEl.checked,
        device:     deviceFilterEl.value,
        sinceDate:  sinceDateEl.value
      }));
    } catch (_) {}
  }

  function loadPrefs() {
    try {
      const saved = JSON.parse(localStorage.getItem(PREFS_KEY) || 'null');
      if (!saved) return;
      if (saved.hideOwner  !== undefined) hideOwnerEl.checked  = saved.hideOwner;
      if (saved.hideAgent  !== undefined) hideAgentEl.checked  = saved.hideAgent;
      if (saved.publicOnly !== undefined) publicOnlyEl.checked = saved.publicOnly;
      if (saved.tail       !== undefined) tailEl.checked       = saved.tail;
      if (saved.device     !== undefined) deviceFilterEl.value = saved.device;
      if (Object.prototype.hasOwnProperty.call(saved, 'sinceDate')) {
        sinceDateEl.value = saved.sinceDate;
        sinceDatePreferenceLoaded = true;
      }
    } catch (_) {}
  }

  function setDefaultSinceDate() {
    if (!sinceDatePreferenceLoaded && !sinceDateEl.value) {
      sinceDateEl.value = new Date().toISOString().slice(0, 10);
    }
  }

  loadPrefs();
  setDefaultSinceDate();

  hideOwnerEl.addEventListener('change', () => { savePrefs(); render(); });
  hideAgentEl.addEventListener('change', () => { savePrefs(); render(); });
  publicOnlyEl.addEventListener('change', () => { savePrefs(); render(); });
  deviceFilterEl.addEventListener('change', () => { savePrefs(); render(); });
  tailEl.addEventListener('change', savePrefs);
  sinceDateEl.addEventListener('change', () => { savePrefs(); render(); });
  filterEl.addEventListener('input', render);
  $('clear').addEventListener('click', () => { events = []; lastTs = 0; render(); });
  $('allDates').addEventListener('click', () => { sinceDateEl.value = ''; savePrefs(); render(); });
  $('downloadVisible').addEventListener('click', () => {
    downloadCsv('webprolog-visible-interactions.csv', events.filter(passesFilter).reverse());
  });
  $('downloadRecent').addEventListener('click', () => {
    location.href = subPath('csv') + '?limit=20000';
  });
  $('tagOwner').addEventListener('click', () => { location.href = subPath('tag/owner'); });
  $('tagClear').addEventListener('click', () => { location.href = subPath('tag/clear'); });

  fetchData();
  setInterval(() => { if (tailEl.checked) fetchData(); }, 3000);
</script>
</body>
</html>
".


                 /*******************************
                 *          DATA REPLY          *
                 *******************************/

serve_viewer_data(Request) :-
    http_parameters(Request,
                    [ since(SinceAtom, [default('0')]),
                      limit(LimitAtom, [default('2000')])
                    ]),
    parse_number(SinceAtom, 0.0, Since),
    parse_number(LimitAtom, 2000, Limit0),
    Limit is max(1, min(Limit0, 20000)),
    (   catch(read_log_events(Since, Limit, Events), _, fail)
    ->  true
    ;   Events = []
    ),
    reply_json_dict(json{ events: Events }).


serve_viewer_csv(Request) :-
    http_parameters(Request,
                    [ since(SinceAtom, [default('0')]),
                      limit(LimitAtom, [default('20000')])
                    ]),
    parse_number(SinceAtom, 0.0, Since),
    parse_number(LimitAtom, 20000, Limit0),
    Limit is max(1, min(Limit0, 50000)),
    (   catch(read_log_events(Since, Limit, Events), _, fail)
    ->  true
    ;   Events = []
    ),
    format('Status: 200 OK~n'),
    format('Content-Type: text/csv; charset=UTF-8~n'),
    format('Content-Disposition: attachment; filename=\"webprolog-interactions.csv\"~n'),
    format('Cache-Control: no-store, no-cache, must-revalidate, max-age=0~n'),
    format('X-Robots-Tag: noindex, nofollow, noarchive~n'),
    format('~n'),
    csv_columns(Columns),
    write_csv_row(Columns),
    forall(member(Event, Events),
           write_event_csv_row(Columns, Event)).


csv_columns([ at, event, client_id, peer, proxy_peer, principal, owner,
              agent, route, source, device, timezone, language, example,
              example_label, example_url, source_kind, transport, origin
            ]).


write_event_csv_row(Columns, Event) :-
    findall(Value,
            ( member(Key, Columns),
              csv_event_value(Event, Key, Value)
            ),
            Values),
    write_csv_row(Values).


csv_event_value(Event, Key, Value) :-
    (   get_dict(Key, Event, Value0)
    ->  csv_text(Value0, Value)
    ;   Value = ""
    ).


write_csv_row(Values) :-
    maplist(csv_cell, Values, Cells),
    atomic_list_concat(Cells, ',', Line),
    format('~w~n', [Line]).


csv_cell(Value0, Cell) :-
    csv_text(Value0, Text),
    (   needs_csv_quotes(Text)
    ->  split_string(Text, "\"", "", Parts),
        atomics_to_string(Parts, "\"\"", Escaped),
        format(string(Cell), '"~s"', [Escaped])
    ;   Cell = Text
    ).


csv_text(Value, Text) :-
    string(Value),
    !,
    Text = Value.
csv_text(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
csv_text(Value, Text) :-
    number(Value),
    !,
    number_string(Value, Text).
csv_text(Value, "true") :-
    Value == @(true),
    !.
csv_text(Value, "false") :-
    Value == @(false),
    !.
csv_text(Value, Text) :-
    term_string(Value, Text).


needs_csv_quotes(Text) :-
    sub_string(Text, _, _, _, ","),
    !.
needs_csv_quotes(Text) :-
    sub_string(Text, _, _, _, "\""),
    !.
needs_csv_quotes(Text) :-
    sub_string(Text, _, _, _, "\n"),
    !.
needs_csv_quotes(Text) :-
    sub_string(Text, _, _, _, "\r").


parse_number(Atom, Default, Number) :-
    (   catch(atom_number(Atom, N), _, fail)
    ->  Number = N
    ;   Number = Default
    ).


read_log_events(Since, Limit, Events) :-
    current_interaction_log_file(File),
    (   exists_file(File)
    ->  read_file_to_string(File, Text, [encoding(utf8)])
    ;   Text = ""
    ),
    split_string(Text, "\n", "", RawLines),
    parse_log_lines(RawLines, Since, AllEvents),
    take_last(AllEvents, Limit, Events).


parse_log_lines([], _, []).
parse_log_lines([Line|Rest], Since, Events) :-
    (   Line == ""
    ->  parse_log_lines(Rest, Since, Events)
    ;   catch(parse_log_line(Line, Since, Event), _, fail)
    ->  Events = [Event|Tail],
        parse_log_lines(Rest, Since, Tail)
    ;   parse_log_lines(Rest, Since, Events)
    ).


parse_log_line(Line, Since, Event) :-
    atom_to_term_safe(Line, Event0),
    (   get_dict(ts, Event0, Ts), number(Ts)
    ->  Ts > Since
    ;   true
    ),
    Event = Event0.


atom_to_term_safe(LineString, Event) :-
    setup_call_cleanup(
        open_string(LineString, Stream),
        json_read_dict(Stream, Event, []),
        close(Stream)
    ).


take_last(List, N, Tail) :-
    length(List, Len),
    (   Len =< N
    ->  Tail = List
    ;   Skip is Len - N,
        length(Prefix, Skip),
        append(Prefix, Tail, List)
    ).


                 /*******************************
                 *        COOKIE TAGGING        *
                 *******************************/

serve_tag_set(Request) :-
    viewer_token(Token),
    redirect_target(Request, Target),
    cookie_secure_flag(Request, SecureFlag),
    OneYear = 31536000,
    format('Status: 303 See Other~n'),
    format('Location: ~w~n', [Target]),
    format('Set-Cookie: wp_owner=~w; Path=/; Max-Age=~d; HttpOnly; SameSite=Lax~w~n',
           [Token, OneYear, SecureFlag]),
    format('Cache-Control: no-store~n'),
    format('Referrer-Policy: no-referrer~n'),
    format('Content-Type: text/plain; charset=UTF-8~n~n'),
    format('Owner tag set.~n').


serve_tag_clear(Request) :-
    redirect_target(Request, Target),
    cookie_secure_flag(Request, SecureFlag),
    format('Status: 303 See Other~n'),
    format('Location: ~w~n', [Target]),
    format('Set-Cookie: wp_owner=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax~w~n', [SecureFlag]),
    format('Cache-Control: no-store~n'),
    format('Referrer-Policy: no-referrer~n'),
    format('Content-Type: text/plain; charset=UTF-8~n~n'),
    format('Owner tag cleared.~n').


redirect_target(Request, Target) :-
    (   memberchk(path(Path), Request),
        atom_concat(Base, '/tag/owner', Path)
    ->  Target = Base
    ;   memberchk(path(Path), Request),
        atom_concat(Base, '/tag/clear', Path)
    ->  Target = Base
    ;   Target = '/'
    ).


cookie_secure_flag(Request, '; Secure') :-
    request_is_https(Request),
    !.
cookie_secure_flag(_Request, '').


request_is_https(Request) :-
    (   memberchk(x_forwarded_proto(Proto), Request)
    ->  proto_text(Proto, "https")
    ;   memberchk('x-forwarded-proto'(Proto), Request)
    ->  proto_text(Proto, "https")
    ;   memberchk(protocol(https), Request)
    ).

proto_text(Value, Expected) :-
    text_to_string(Value, ValueS),
    string_lower(ValueS, Lower),
    Lower == Expected.
