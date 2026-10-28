'use strict';
const $ = id => document.getElementById(id);
const svgNS = 'http://www.w3.org/2000/svg';
let node = null, ready = false, busy = true, more = false, disposed = false;
let source = '', facts = [], answerCount = 0, activeGoal = '', resolveInput = null;
const namePattern = /^[a-z][a-z0-9_]{0,31}$/;
function status(text) { $('status').textContent = text; }
function updateControls() {
  $('ask').disabled = !ready || busy || more;
  $('next').disabled = !ready || busy || !more;
  $('stop').disabled = !ready || busy || !more;
  $('abort').disabled = !ready || !busy;
  $('add').disabled = !ready || busy || more;
  $('download').disabled = !ready || busy || more;
  for (const button of $('relationships').querySelectorAll('button')) button.disabled = !ready || busy || more;
}
function updateMessage(text, error = false) {
  $('update-message').textContent = text;
  $('update-message').classList.toggle('error', error);
}
function finishInput() {
  if (resolveInput) { const resolve = resolveInput; resolveInput = null; resolve(null); }
  if ($('input-dialog').open) $('input-dialog').close();
}
$('input-dialog').addEventListener('close', () => {
  if (!resolveInput) return;
  const resolve = resolveInput; resolveInput = null;
  if ($('input-dialog').returnValue === 'send') resolve($('input-value').value);
  else { resolve(null); abortQuery(); }
});
function requestInput(text) {
  if (disposed) return null;
  $('input-prompt').textContent = text;
  $('input-value').value = '';
  $('input-dialog').returnValue = '';
  $('input-dialog').showModal();
  $('input-value').focus();
  return new Promise(resolve => { resolveInput = resolve; });
}
function errorText(value) { return typeof value === 'string' ? value : JSON.stringify(value); }
async function snapshot() {
  const rows = [];
  let answer = await node.query('relationship(Role, Parent, Child)', {limit: 201});
  while (true) {
    if (answer.type === 'success') rows.push(...answer.data);
    else if (answer.type !== 'failure') throw new Error(errorText(answer.data || answer.type));
    if (!answer.more) break;
    if (rows.length > 2000) { await node.stop(); throw new Error('Too many facts to draw. Reduce the family to 2000 relationships.'); }
    answer = await node.next();
  }
  if (disposed) return;
  facts = rows.map(row => ({role:row.Role, parent:row.Parent, child:row.Child}));
  renderFamily();
}
function svgElement(tag, attributes, text) {
  const element = document.createElementNS(svgNS, tag);
  for (const [key, value] of Object.entries(attributes || {})) element.setAttribute(key, value);
  if (text !== undefined) element.textContent = text;
  return element;
}
function displayName(name) { return name.charAt(0).toUpperCase() + name.slice(1).replaceAll('_', ' '); }
function renderFamily() {
  const people = [...new Set(facts.flatMap(fact => [fact.parent, fact.child]))].sort();
  $('people-count').textContent = people.length + ' people · ' + facts.length + ' facts';
  const graph = $('family-graph'); graph.replaceChildren();
  $('graph-empty').hidden = people.length > 0;
  graph.toggleAttribute('hidden', people.length === 0);
  // Topological levels are a drawing aid, not a second implementation of kinship.
  const degree = new Map(people.map(name => [name, 0]));
  const depths = new Map(people.map(name => [name, 0]));
  const edges = [...new Map(facts.map(fact => [JSON.stringify([fact.parent, fact.child]), fact])).values()];
  for (const edge of edges) degree.set(edge.child, degree.get(edge.child) + 1);
  const queue = people.filter(name => degree.get(name) === 0);
  for (let i = 0; i < queue.length; i++) {
    const parent = queue[i];
    for (const edge of edges.filter(edge => edge.parent === parent)) {
      depths.set(edge.child, Math.max(depths.get(edge.child), depths.get(parent) + 1));
      degree.set(edge.child, degree.get(edge.child) - 1);
      if (degree.get(edge.child) === 0) queue.push(edge.child);
    }
  }
  const cyclic = queue.length !== people.length;
  $('graph-note').textContent = cyclic ? 'Cycle detected in raw facts. Remove the cycle before running recursive queries.' : 'Facts and the diagram come from the running Prolog engine.';
  const levels = Array.from({length: Math.max(0, ...depths.values()) + 1}, () => []);
  for (const person of people) levels[depths.get(person)].push(person);
  const width = Math.max(640, ...levels.map(level => level.length * 160));
  const height = Math.max(360, levels.length * 116);
  graph.setAttribute('viewBox', `0 0 ${width} ${height}`);
  const positions = new Map();
  levels.forEach((level, depth) => level.forEach((person, index) => {
    positions.set(person, {x: width * (index + 1) / (level.length + 1), y: 48 + depth * (height - 96) / Math.max(1, levels.length - 1)});
  }));
  for (const fact of facts) {
    const from = positions.get(fact.parent), to = positions.get(fact.child);
    graph.append(svgElement('path', {d:`M ${from.x} ${from.y + 26} C ${from.x} ${(from.y + to.y)/2}, ${to.x} ${(from.y + to.y)/2}, ${to.x} ${to.y - 26}`, class:'family-edge ' + fact.role}));
  }
  for (const person of people) {
    const {x, y} = positions.get(person);
    const group = svgElement('g', {class:'person', role:'button', tabindex:'0', 'aria-label':'Ask about ' + displayName(person) + '’s descendants', transform:`translate(${x-65} ${y-27})`});
    group.append(svgElement('rect', {width:130,height:54,rx:10}));
    group.append(svgElement('circle', {cx:25,cy:27,r:15}));
    group.append(svgElement('text', {x:25,y:32,'text-anchor':'middle',class:'initial'}, displayName(person).charAt(0)));
    const short = displayName(person);
    group.append(svgElement('text', {x:48,y:25,class:'name'}, short.length > 10 ? short.slice(0,9)+'…' : short));
    group.append(svgElement('text', {x:48,y:39,class:'role'}, 'GENERATION ' + (depths.get(person)+1)));
    const select = () => { $('goal').value = `ancestor_descendant(${person}, Who)`; $('goal').focus(); };
    group.addEventListener('click', select);
    group.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') {event.preventDefault(); select();} });
    graph.append(group);
  }
  $('relationships').replaceChildren();
  for (const fact of facts) {
    const item = document.createElement('li'), text = document.createElement('span'), relation = document.createElement('em');
    text.append(document.createTextNode(displayName(fact.parent)));
    relation.textContent = 'is ' + fact.role + ' of'; text.append(relation, document.createTextNode(displayName(fact.child)));
    const remove = document.createElement('button'); remove.textContent = '×';
    remove.setAttribute('aria-label', `Remove ${fact.role} relationship from ${fact.parent} to ${fact.child}`);
    remove.onclick = () => mutate('remove', fact.role, fact.parent, fact.child, true);
    item.append(text, remove); $('relationships').append(item);
  }
  updateControls();
}
function showAnswer(answer, goal) {
  const empty = $('answers').querySelector('.answer-empty'); if (empty) empty.remove();
  const card = document.createElement('article'); card.className = 'answer' + (answer.type === 'error' ? ' error' : '');
  const query = document.createElement('small'); query.className = 'query-label'; query.textContent = '?- ' + goal;
  const label = document.createElement('small'); label.textContent = answer.type.toUpperCase() + (answer.more ? ' · MORE AVAILABLE' : '');
  const pre = document.createElement('pre');
  if (answer.type === 'success') {
    pre.textContent = answer.data.map(row => typeof row === 'object' && row !== null ? Object.entries(row).map(([name,value]) => `${name} = ${value}`).join('\n') || 'true' : String(row)).join('\n\n') || 'true';
    answerCount += answer.data.length;
  } else pre.textContent = answer.type === 'failure' ? 'false' : errorText(answer.data ?? answer.type);
  card.append(query, label, pre); $('answers').append(card);
  $('answer-count').textContent = answerCount;
  $('answers').scrollTop = $('answers').scrollHeight;
}
async function ask(next = false) {
  if (!ready || busy || (next ? !more : more)) return;
  if (!next) { activeGoal = $('goal').value.trim(); if (!activeGoal) return; }
  busy = true; updateControls(); status(next ? 'Looking for another answer…' : 'Asking Prolog…');
  try {
    const answer = await (next ? node.next() : node.query(activeGoal, {limit:1}));
    if (disposed) return;
    more = answer.more === true;
    showAnswer(answer, activeGoal);
    const message = more ? 'More answers available · choose Next or Stop before editing.' : answer.type === 'error' ? 'Prolog reported an error · you can ask another question.' : answer.type === 'abort' ? 'Query aborted · ready.' : 'Query complete · ready for another question.';
    if (!more) await snapshot();
    if (!disposed) status(message);
  } catch (error) { if (!disposed) status('Query or diagram refresh failed: ' + error.message); }
  finally { if (!disposed) { busy = false; finishInput(); updateControls(); } }
}
async function stopQuery() {
  if (!ready || busy || !more) return;
  busy = true; updateControls();
  try { await node.stop(); more = false; await snapshot(); status('Query stopped · ready to edit or ask again.'); }
  catch (error) { status('Could not stop query: ' + error.message); }
  finally { busy = false; updateControls(); }
}
async function abortQuery() {
  if (!ready || !busy) return;
  try { await node.abort(); finishInput(); status('Abort requested…'); }
  catch (error) { status('Could not abort: ' + error.message); }
}
function quoteAtom(text) { return "'" + text.replaceAll('\\','\\\\').replaceAll("'","''") + "'"; }
async function mutate(action, role, parent, child, termsFromEngine = false) {
  if (!ready || busy || more) return;
  if (!['mother','father'].includes(role)) return;
  if (!termsFromEngine && (!namePattern.test(parent) || !namePattern.test(child))) { updateMessage('Use lower-case names such as ada or mary_jane, up to 32 characters.', true); return; }
  // Snapshot bindings are already complete Prolog terms. Form values are quoted
  // atoms, independently of the form validation, never executable goal fragments.
  const parentTerm = termsFromEngine ? parent : quoteAtom(parent), childTerm = termsFromEngine ? child : quoteAtom(child);
  busy = true; updateControls(); updateMessage('Updating the Prolog database…');
  try {
    const goal = `once(${action}_relationship(${role},${parentTerm},${childTerm}))`;
    const answer = await node.query(goal);
    if (answer.type !== 'success') throw new Error(errorText(answer.data || answer.type));
    await snapshot();
    updateMessage(action === 'add' ? `Added ${parent} → ${child}. Ask about the new connection.` : `Removed ${parent} → ${child}.`);
    status('Family updated · the diagram reflects the running Prolog session.');
  } catch (error) {
    const message = /domain_error\(acyclic_family/.test(error.message) ? 'That connection would create a cycle. A person cannot be their own ancestor.' : error.message;
    updateMessage(message, true); status('Relationship update failed · see the message below the form.');
  }
  finally { busy = false; updateControls(); }
}
$('query-form').onsubmit = event => { event.preventDefault(); ask(); };
$('goal').onkeydown = event => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); ask(); } };
$('next').onclick = () => ask(true); $('stop').onclick = stopQuery; $('abort').onclick = abortQuery;
$('relationship-form').onsubmit = event => { event.preventDefault(); mutate('add', $('role').value, $('parent').value.trim(), $('child').value.trim()); };
for (const button of document.querySelectorAll('[data-goal]')) button.onclick = () => { $('goal').value = button.dataset.goal; $('goal').focus(); };
$('clear').onclick = () => { $('answers').replaceChildren(); $('output').textContent = ''; answerCount = 0; $('answer-count').textContent = '0'; };
$('download').onclick = () => {
  const rules = source.split('% Sample facts')[0];
  const text = rules + '% Saved facts from this browser session.\n' + facts.map(fact => `${fact.role}_child(${fact.parent}, ${fact.child}).`).join('\n') + '\n';
  const url = URL.createObjectURL(new Blob([text], {type:'text/plain;charset=utf-8'}));
  const link = document.createElement('a'); link.href = url; link.download = 'my-family.pl'; link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
};
window.addEventListener('pagehide', () => { disposed = true; finishInput(); if (node) node.dispose(); });
async function boot() {
  updateControls();
  try {
    const response = await fetch('genealogist.pl'); if (!response.ok) throw new Error('Cannot load genealogist.pl');
    source = await response.text(); if (disposed) return;
    $('program').textContent = source;
    node = SwiWasmNode.create({workerUrl:new URL('runtime/swi_wasm_actor_worker.js',location.href).href,engineUrl:new URL('runtime/swipl-bundle.js',location.href).href,prologBaseUrl:new URL('runtime/wasm/',location.href).href,sharedDatabaseUrl:null,
      onEvent(event) { if (disposed) return false; if (event.type === 'output' || event.type === 'statechart_trace') { $('output').append(document.createTextNode(event.data)); $('output').parentElement.open = true; return true; } },
      onInput:requestInput});
    await node.open({source});
    if (disposed) return;
    await snapshot(); ready = true; status('Browser engine ready · choose a question or add a connection.');
  } catch (error) { if (node) node.dispose(); status('Could not start: ' + error.message + '. Reload to try again.'); }
  finally { if (!disposed) { busy = false; updateControls(); } }
}
boot();
