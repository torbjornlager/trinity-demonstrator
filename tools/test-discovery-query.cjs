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
