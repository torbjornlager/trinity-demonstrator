"""Build source-injected tests without providers or live-node writes.

Pass the same Queries-menu extractor used by the engine harness. Sensor and
chart text injection are test-only; production paths remain unchanged.
"""
from pathlib import Path
import json
S=Path(__file__).resolve().parents[1]
def cases(queries):
 out=[]
 for name in ['23 jev-agent.pl','24 jev-sxml-agent.pl']:
  source=(S/'examples/actors'/name).read_text();source=source.replace('src_predicates([','src_predicates([jev_deployment_observation/2,')
  if name.startswith('24'):
   xml=(S/'examples/statecharts/20 jev-deployment-assistant.xml').read_text()
   source=source.replace("src_uri('/examples/statecharts/20%20jev-deployment-assistant.xml')",'src_text('+json.dumps(xml)+')')
  source+='\n'+(S/'tests/fixtures/portable_jev_sensor.pl').read_text()
  qs=queries(source)+['jev_observation("malformed",unavailable(malformed_observation))','jev_observation("unavailable",unavailable(configuration))']
  if name.startswith('23'):
   qs[1]+=", Report=report(_,_,action(prepare_preview),_)"
   qs[2]+=", Report=report(_,_,action(show_status),_)"
  else:
   qs[2]+=", Report=report(_,_,state(idle),_,action(ask_confirmation),_)"
   qs[3]+=", Report=report(_,_,state(awaiting_confirmation),_,action(simulate_deploy(_)),_)"
  spawner='jev_agent_spawn' if name.startswith('23') else 'jev_sxml_agent_spawn'
  qs += [spawner+'(Pid)', 'self(Me), $Pid ! say(Me, crash, "crash"), receive({down($Pid,$Pid,Reason) -> throw(agent_down(Reason))},[timeout(2),on_timeout(throw(missed_down))])']
  out.append((name,source,qs))
 return out
