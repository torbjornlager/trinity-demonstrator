'use strict';
const $ = id => document.getElementById(id);
const programs = [
  {name:'family.pl', hint:'Follow a family tree through a recursive relation. Ask for one answer at a time.', queries:['ancestor(ada, Who)','ancestor(Who, doris)'], source:`% A small family, a recursive relation.\n% Load the program, then ask who Ada's descendants are.\n\nparent(ada, bert).\nparent(ada, clara).\nparent(bert, doris).\nparent(clara, elias).\n\nancestor(X, Y) :-\n    parent(X, Y).\nancestor(X, Y) :-\n    parent(X, Z),\n    ancestor(Z, Y).\n`},
  {name:'lists.pl', hint:'Explore alternatives, collect answers, or watch output arrive before the result.', queries:['colour(Colour)','pair(X, Y)','greet'], source:`% Answers, alternatives, and a little output.\n\ncolour(sage).\ncolour(amber).\ncolour(indigo).\n\npair(X, Y) :-\n    member(X, [a,b]),\n    member(Y, [1,2]).\n\ngreet :-\n    writeln('Hello from your browser.'),\n    writeln('This is real Prolog output.').\n`},
  {name:'actors.pl', hint:'Spawn a local actor and exchange a message. Both engines run in browser Workers.', queries:['ping_pong(Reply)'], source:`% A message exchanged between two local actors.\n\nping_pong(Reply) :-\n    self(Me),\n    spawn(\n        receive({\n            ping(From) -> From ! pong\n        }),\n        Peer\n    ),\n    Peer ! ping(Me),\n    receive({pong -> Reply = pong}).\n`}
];
CodeMirror.defineMode('studio-prolog', () => ({token(stream) {
  if(stream.eatSpace()) return null;
  if(stream.match(/%.*/)) return 'comment';
  if(stream.match(/'(?:[^'\\]|\\.|'')*'/) || stream.match(/"(?:[^"\\]|\\.)*"/)) return 'string';
  if(stream.match(/[a-z][A-Za-z0-9_]*/)) return null;
  if(stream.match(/[A-Z_][\w]*/)) return 'variable-2';
  if(stream.match(/\b\d+(?:\.\d+)?\b/)) return 'number';
  stream.next();return null;
}}));
const editor = CodeMirror.fromTextArea($('source'), {lineNumbers:true,mode:'studio-prolog',indentUnit:4,tabSize:4,lineWrapping:true,extraKeys:{'Ctrl-Enter':()=>loadProgram(),'Cmd-Enter':()=>loadProgram()}});
editor.getInputField().setAttribute('aria-label','Prolog source');
let current = 0, node = null, generation = 0, busy = false, loading = false, more = false;
let loadedSource = null, answerCount = 0, inputResolve = null;
function status(text) {$('status').textContent='● '+text;}
function log(text) {const p=document.createElement('p');p.textContent=new Date().toLocaleTimeString()+'  '+text;$('session').append(p);}
function controls() {
  const dirty = loadedSource !== editor.getValue();
  $('run').disabled=!node || busy || loading || dirty || more;
  $('next').disabled=!node || busy || loading || !more || dirty;
  $('stop').disabled=!node || loading || (!busy && !more);
  $('abort').disabled=!node || loading || !busy;
  $('load').disabled=busy || loading;
  $('reset').disabled=loading;
  $('session-label').textContent=loading?'STARTING':node?'WORKER SESSION':'NO SESSION';
  $('source-state').textContent=loading?'Starting a fresh engine…':loadedSource===null?'Ready to load':dirty?'Source changed · load to apply':'Loaded into browser session';
  $('dirty').textContent=editor.getValue()!==programs[current].source?'●':'';
}
function cancelInput() {
  if(inputResolve){const resolve=inputResolve;inputResolve=null;resolve(null);}
  if($('input-dialog').open)$('input-dialog').close();
}
function dispose() {
  generation++;cancelInput();if(node)node.dispose();node=null;loadedSource=null;more=false;busy=false;
}
async function askInput(text, token) {
  if(token!==generation)return null;
  $('input-prompt').textContent=text;$('input-value').value='';$('input-dialog').returnValue='';
  return new Promise(resolve=>{inputResolve=resolve;$('input-dialog').showModal();$('input-value').focus();});
}
$('input-dialog').addEventListener('close',()=>{
  if(!inputResolve)return;
  const resolve=inputResolve;inputResolve=null;
  if($('input-dialog').returnValue==='send')resolve($('input-value').value);
  else {resolve(null);interrupt('abort');}
});
async function loadProgram() {
  if(busy || loading)return;
  dispose();loading=true;controls();status('Loading program…');
  const token=generation, source=editor.getValue();
  const fresh=SwiWasmNode.create({
    workerUrl:new URL('runtime/swi_wasm_actor_worker.js',location.href).href,
    engineUrl:new URL('runtime/swipl-bundle.js',location.href).href,
    prologBaseUrl:new URL('runtime/wasm/',location.href).href,
    sharedDatabaseUrl:null,
    onEvent(event){
      if(token!==generation)return false;
      if(event.type==='output' || event.type==='statechart_trace'){$('output').append(document.createTextNode(event.data));return true;}
      if(event.type==='shell_error' || event.type==='error')log('Runtime: '+event.error);
    },
    onInput:text=>askInput(text,token)
  });
  node=fresh;
  try {
    await fresh.open({source});
    if(token!==generation)return;
    loadedSource=source;status('Program loaded · ready for a query');log('Loaded '+programs[current].name+' into a new Worker session.');
  }catch(error){if(token===generation){fresh.dispose();node=null;status('Could not load program');log(String(error));}}
  finally{if(token===generation){loading=false;controls();}}
}
function showAnswer(answer, goal) {
  if($('answers').querySelector('.empty'))$('answers').replaceChildren();
  const card=document.createElement('article');card.className='answer-card'+(answer.type==='error'?' error':'');
  const top=document.createElement('div');top.className='answer-top';
  const label=document.createElement('span');label.textContent='?- '+goal;
  const badge=document.createElement('span');badge.className='badge';badge.textContent=answer.type.toUpperCase();top.append(label,badge);
  const pre=document.createElement('pre');
  if(answer.type==='success' && Array.isArray(answer.data)) {
    pre.textContent=answer.data.map(row=>typeof row==='object'&&row!==null ? Object.entries(row).map(([key,value])=>key+' = '+value).join('\n') || 'true' : String(row)).join('\n\n') || 'true';
    answerCount+=answer.data.length;
  } else pre.textContent=answer.type==='failure'?'false':typeof answer.data==='string'?answer.data:JSON.stringify(answer.data ?? answer.type,null,2);
  const bottom=document.createElement('div');bottom.className='answer-bottom';bottom.textContent=answer.more?'More answers available · press Next or Stop.':answer.type==='success'?'Query complete.':'Session event: '+answer.type;
  card.append(top,pre,bottom);$('answers').append(card);$('answer-count').textContent=answerCount;
  card.scrollIntoView({block:'nearest'});
}
let activeGoal='';
async function runQuery(next=false) {
  if(busy || loading || !node || loadedSource!==editor.getValue() || (next?!more:more))return;
  if(!next){activeGoal=$('goal').value.trim();if(!activeGoal)return;remember(activeGoal);}
  const token=generation, target=node;busy=true;controls();status(next?'Finding the next answer…':'Running query…');
  try {
    const answer=await(next?target.next():target.query(activeGoal,{limit:1}));
    if(token!==generation)return;
    more=answer.more===true;showAnswer(answer,activeGoal);switchView('answers');
    status(more?'Answer ready · more alternatives available':answer.type==='error'?'Prolog exception · session ready':answer.type==='abort'?'Query aborted':answer.type==='stop'?'Query stopped':'Query complete · ready');
    log(answer.type+(answer.more?' · continuation available':''));
  }catch(error){if(token===generation){status('Query failed · see Session');log(String(error));}}
  finally{if(token===generation){busy=false;cancelInput();controls();}}
}
async function interrupt(command) {
  if(!node || loading || (!busy && !more))return;
  const token=generation;
  try {await node[command]();if(token===generation){more=false;cancelInput();status(command==='stop'?'Query stopped':'Abort requested');log(command+' requested.');controls();}}
  catch(error){if(token===generation){log(String(error));status('Interruption failed · Reset session to recover');}}
}
function switchView(name) {
  for(const view of ['answers','output','session']){$(view).hidden=view!==name;$('tab-'+view).setAttribute('aria-selected',String(view===name));$('tab-'+view).tabIndex=view===name?0:-1;}
}
const views=['answers','output','session'];
for(const view of views){$('tab-'+view).onclick=()=>switchView(view);$('tab-'+view).onkeydown=e=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const i=views.indexOf(view);const next=e.key==='Home'?0:e.key==='End'?2:(i+(e.key==='ArrowRight'?1:2))%3;switchView(views[next]);$('tab-'+views[next]).focus();};}
function remember(goal) {
  if(![...$('history').options].some(o=>o.value===goal)){$('history').add(new Option(goal,goal));}
  $('history').value=goal;
}
$('history').onchange=()=>{if($('history').value)$('goal').value=$('history').value;};
function renderFiles() {
  $('files').replaceChildren();programs.forEach((program,index)=>{const button=document.createElement('button');button.textContent=program.name;button.className=index===current?'active':'';button.setAttribute('aria-pressed',String(index===current));button.onclick=()=>selectFile(index);$('files').append(button);});
}
function selectFile(index) {
  if(loading)return;
  programs[current].draft=editor.getValue();dispose();current=index;
  editor.setValue(programs[index].draft ?? programs[index].source);$('filename').textContent=programs[index].name;$('hint').textContent=programs[index].hint;
  $('suggestions').replaceChildren();programs[index].queries.forEach(goal=>{const button=document.createElement('button');button.textContent='?- '+goal;button.onclick=()=>{$('goal').value=goal;$('goal').focus();};$('suggestions').append(button);});
  $('goal').value=programs[index].queries[0] || 'true';renderFiles();controls();status('Ready · load '+programs[index].name);log('Selected '+programs[index].name+'. Previous session disposed.');
}
editor.on('change',controls);
$('load').onclick=loadProgram;$('run').onclick=e=>{e.preventDefault();runQuery();};$('query-form').onsubmit=e=>{e.preventDefault();runQuery();};
$('goal').onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();runQuery();}};
$('next').onclick=()=>runQuery(true);$('stop').onclick=()=>interrupt('stop');$('abort').onclick=()=>interrupt('abort');
$('reset').onclick=()=>{dispose();loading=false;controls();status('Session reset · load the program to start again');log('Session disposed. Source kept in the editor.');};
$('clear').onclick=()=>{$('answers').replaceChildren();$('output').textContent='';answerCount=0;$('answer-count').textContent='0';};
$('open').onclick=()=>$('file-input').click();
$('file-input').onchange=async e=>{const file=e.target.files[0];if(!file)return;const text=await file.text();programs.push({name:file.name,source:text,queries:['true'],hint:'Your local source. Load it into a fresh session, then enter a query.'});selectFile(programs.length-1);e.target.value='';};
$('save').onclick=()=>{const blob=new Blob([editor.getValue()],{type:'text/plain;charset=utf-8'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download=programs[current].name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);programs[current].source=editor.getValue();controls();};
$('theme').onclick=()=>{const light=document.body.classList.toggle('light');$('theme').textContent=light?'Dark mode':'Light mode';editor.refresh();};
for(const [id,property,direction,min,max] of [['left-divider','--left',1,120,340],['right-divider','--right',-1,280,620]]){
  const divider=$(id);let start=0,width=0;
  const getWidth=()=>parseFloat(getComputedStyle(document.documentElement).getPropertyValue(property));
  const resize=delta=>{const other=getComputedStyle(document.documentElement).getPropertyValue(property==='--left'?'--right':'--left');const available=document.documentElement.clientWidth-parseFloat(other)-230;const value=Math.max(min,Math.min(max,available,width+direction*delta));document.documentElement.style.setProperty(property,value+'px');divider.setAttribute('aria-valuenow',value);editor.refresh();};
  divider.setAttribute('aria-valuemin',min);divider.setAttribute('aria-valuemax',max);divider.setAttribute('aria-valuenow',getWidth());
  divider.onpointerdown=e=>{start=e.clientX;width=getWidth();divider.setPointerCapture(e.pointerId);};
  divider.onpointermove=e=>{if(divider.hasPointerCapture(e.pointerId))resize(e.clientX-start);};
  divider.onpointerup=e=>{if(divider.hasPointerCapture(e.pointerId))divider.releasePointerCapture(e.pointerId);};
  divider.onkeydown=e=>{if(['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();width=getWidth();resize(e.key==='ArrowRight'?15:-15);}};
}
window.addEventListener('pagehide',dispose);
editor.setValue(programs[0].source);
selectFile(0);
