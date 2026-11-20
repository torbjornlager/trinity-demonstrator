/* Exercise the page's actual query builder and round-trip names through SWI. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');

const html = fs.readFileSync(path.join(__dirname, '../web/discovery-hub.html'), 'utf8');
const start = html.indexOf('    function prologAtom(');
const end = html.indexOf('    function applyFilters(', start);
assert.ok(start >= 0 && end > start);
const context = vm.createContext({});
vm.runInContext(html.slice(start, end), context);

assert.equal(context.buildGoal({}), 'node_id(Id)');
assert.equal(context.buildGoal({profileMin:'actor', auth:'open'}),
  "node_profile_at_least(Id, 'actor'),\n   node_auth(Id, 'open')");

for (const capability of ['counter', 'Counter', 'my-service', "owner's-service",
                          'path\\service', 'human/1', "owner's/2", 'line\nbreak', 'räksmörgås😀']) {
  const goal = context.buildGoal({capability});
  assert.ok(goal.startsWith(capability.includes('/') ? 'node_provides(' : 'node_service('));
  const result = spawnSync(process.env.SWIPL || 'swipl', ['-f','none','-q',
    '-g', "use_module(library(http/json)),read_term(user_input,Term,[variable_names(Vars)])," +
          "Vars=['Id'=_],arg(2,Term,Atom),atom(Atom),atom_string(Atom,Text)," +
          "json_write_dict(current_output,_{value:Text}),halt"],
    {input:goal + '.\n', encoding:'utf8', timeout:5000});
  assert.equal(result.status, 0, result.stderr || String(result.error));
  assert.equal(JSON.parse(result.stdout).value, capability);
}
console.log('Discovery query names round-trip as Prolog atoms');


// Exercise the real page's fetch/merge/render flow, including its public
// three-query concurrency bound and the formerly silent metadata failure.
async function checkImplementationCards(unavailable = false) {
  const labels = {n0:'SWI-Prolog', n1:'SWI-Prolog', n2:'SWI-Prolog',
    n3:'SWI-Prolog', n4:'SWI-Prolog', n5:'Trealla Prolog',
    n6:'GNU Prolog', n7:'ECLiPSe CLP'};
  const elements = new Map();
  let inflight = 0, maximum = 0, labelQueries = 0;
  const page = vm.createContext({URLSearchParams,
    document: {getElementById(id) {
      if (!elements.has(id)) elements.set(id, {innerHTML:'', textContent:''});
      return elements.get(id);
    }},
    fetch: async url => {
      maximum = Math.max(maximum, ++inflight);
      await new Promise(resolve => setImmediate(resolve));
      inflight--;
      const goal = new URLSearchParams(url.split('?')[1]).get('goal');
      let data = [];
      if (goal.includes('node_directory_row')) data = Object.keys(labels).map(Id =>
        ({Id, Status:Id === 'n6' ? 'down' : 'up', Profile:'actor', Auth:'open',
          Url:'https://' + Id + '.example', LastSeen:0}));
      if (goal.includes('node_implementation')) {
        labelQueries++;
        if (unavailable) return {ok:true, json:async () =>
          ({type:'error', data:'Unknown procedure: node_implementation/2'})};
        data = Object.entries(labels).map(([Id, Implementation]) =>
          ({Id, Implementation:"'" + Implementation + "'"}));
      }
      return {ok:true, json:async () => ({type:'success', data})};
    }});
  const scriptStart = html.indexOf('    var POLL_MS');
  const scriptEnd = html.indexOf('    buildProfileControl();', scriptStart);
  assert.ok(scriptStart >= 0 && scriptEnd > scriptStart);
  vm.runInContext(html.slice(scriptStart, scriptEnd), page);
  page.tick();
  for (let i = 0; i < 20 && !page.lastFetch; i++)
    await new Promise(resolve => setImmediate(resolve));
  assert.ok(page.lastFetch, 'directory polling did not finish');
  assert.equal(labelQueries, 1, 'implementation metadata must be fetched');
  assert.ok(maximum <= 3, 'public query concurrency exceeded: ' + maximum);
  const alert = elements.get('dh-alert').innerHTML;
  if (unavailable) assert.match(alert, /incomplete/i);
  else {
    assert.equal(alert, '');
    for (const [id, label] of Object.entries(labels)) {
      const row = page.ALL.find(r => r.id === id);
      assert.equal(row?.implementation, label, id);
      assert.ok(page.nodeCard(row).includes('>' + label + '</div>'), id);
    }
    assert.ok(page.nodeCard({...page.ALL[0], implementation:'<script>'})
      .includes('&lt;script&gt;'));
  }
}
(async () => {
  await checkImplementationCards();
  await checkImplementationCards(true);
  console.log('Discovery implementation cards, offline labels and query bounds pass');
})().catch(error => { console.error(error); process.exitCode = 1; });
