:- module(node_log_viewer, []).

/** <module> Secret interaction-log viewer.

Exposes a token-gated viewer for the durable interaction log at:

  - GET /__viewer/<token>               — HTML viewer
  - GET /__viewer/<token>/data          — JSON tail of recent events
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
  td.ua { color: #999; font-size: 11px; max-width: 22rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  td.ua:hover { white-space: normal; word-break: break-all; }
  .pill { display: inline-block; padding: 0 .35rem; border-radius: 3px; background: #2a2a2a; color: #ddd; font-size: 11px; }
  a, a:visited { color: #6af; }
</style>
</head>
<body>
<h1>Interaction log <span class=\"pill\" id=\"count\">0</span></h1>
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
  <label>Filter <input type=\"text\" id=\"filter\" placeholder=\"substring (event/client/route/...)\"></label>
  <button id=\"clear\">Clear view</button>
  <button id=\"tagOwner\">Mark this browser as owner</button>
  <button id=\"tagClear\">Clear owner tag</button>
  <span id=\"status\">idle</span>
</div>
<table>
  <thead><tr>
    <th>At</th><th>Event</th><th>Who</th><th>Route</th><th>Device</th><th>Source</th><th>Tag</th><th>UA</th><th>Extra</th>
  </tr></thead>
  <tbody id=\"rows\"></tbody>
</table>
<script>
  const $ = (id) => document.getElementById(id);
  const rowsEl = $('rows');
  const statusEl = $('status');
  const countEl = $('count');
  const hideOwnerEl = $('hideOwner');
  const hideAgentEl = $('hideAgent');
  const publicOnlyEl = $('publicOnly');
  const deviceFilterEl = $('deviceFilter');
  const tailEl = $('tail');
  const filterEl = $('filter');
  let lastTs = 0;
  let events = [];
  const MAX_KEEP = 5000;

  const HIDE_KEYS = new Set(['at','ts','event','client_id','route','source','peer','principal','user_agent','owner','agent','device']);

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
    const f = filterEl.value.trim().toLowerCase();
    if (!f) return true;
    return JSON.stringify(e).toLowerCase().includes(f);
  }

  function render() {
    const f = document.createDocumentFragment();
    let shown = 0;
    for (let i = events.length - 1; i >= 0; i--) {
      const e = events[i];
      if (!passesFilter(e)) continue;
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
        '<td>' + esc(e.source || '') + '</td>' +
        '<td class=\"tag\">' + esc(tagText) + '</td>' +
        '<td class=\"ua\" title=\"' + esc(e.user_agent || '') + '\">' + esc(e.user_agent || '') + '</td>' +
        '<td class=\"extra\">' + esc(fmtExtra(e)) + '</td>';
      f.appendChild(tr);
      shown++;
    }
    rowsEl.replaceChildren(f);
    countEl.textContent = shown + ' / ' + events.length;
  }

  function esc(s) {
    return String(s).replace(/[&<>\"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));
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
        device:     deviceFilterEl.value
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
    } catch (_) {}
  }

  loadPrefs();

  hideOwnerEl.addEventListener('change', () => { savePrefs(); render(); });
  hideAgentEl.addEventListener('change', () => { savePrefs(); render(); });
  publicOnlyEl.addEventListener('change', () => { savePrefs(); render(); });
  deviceFilterEl.addEventListener('change', () => { savePrefs(); render(); });
  tailEl.addEventListener('change', savePrefs);
  filterEl.addEventListener('input', render);
  $('clear').addEventListener('click', () => { events = []; lastTs = 0; render(); });
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
