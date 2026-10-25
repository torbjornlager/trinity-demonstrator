/* Mock-only portable/native application boundary regressions. */
:- ['../load.pl'].
:- use_module('../examples/example_text').
:- use_module('../examples/services/model_service',[]).
:- use_module('../examples/services/jev_service',[]).
:- use_module('../examples/jev/jev',[]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(plunit)).
:- use_module(library(readutil)).
:- use_module(library(time)).
:- use_module(library(socket)).
:- use_module(library(http/websocket)).
% Read the actual actor program in a host test module for pure history checks.
:- load_files(text_chat_example:'../examples/actors/21 model-actor.pl', []).
:- dynamic text_seen/2, text_endpoint/2, text_model_mode/1, text_jev_padding/0.
:- http_handler(root(text_model),text_model,[]).
:- http_handler(root(text_jev),text_jev,[]).

text_model(Request) :-
    http_read_json_dict(Request,Payload),assertz(text_seen(model,Payload)),
    (text_model_mode(oversize_bytes) -> repeat_char(5000,'😀',Chars),string_chars(Padding,Chars),
      reply_json_dict(_{done:true,message:_{content:"ok"},padding:Padding})
    ; text_model_mode(oversize_content) -> repeat_char(4001,a,Chars),string_chars(Text,Chars),
      reply_json_dict(_{done:true,message:_{content:Text}})
    ; reply_json_dict(_{done:true,message:_{content:"räksmörgås 😀"}})).
text_jev(Request) :-
    http_read_json_dict(Request,Payload),assertz(text_seen(jev,Payload)),
    memberchk(authorization(Auth),Request),assertz(text_seen(auth,Auth)),
    (text_jev_padding -> repeat_char(500,'😀',Chars),string_chars(Padding,Chars) ; Padding=""),
    reply_json_dict(_{model:"mock",padding:Padding,answers:_{
      intent:_{type:"choice",choice:"affirm",probabilities:_{affirm:1.0},confidence:1.0},
      urgency:_{type:"score",score:1,legend:_{'0':"Low",'1':"Hög"},
                probabilities:_{'0':0.25,'1':0.75},confidence:0.75},
      is_question:_{type:"noul",noul:0.2}},
      extension:_{empty_text:"",empty_array:[],unicode:"😀",flags:[true,false,null]}}).
text_setup :-
    retractall(text_seen(_,_)),http_server(http_dispatch,[port(Port),workers(2)]),
    format(atom(Model),'http://127.0.0.1:~w/text_model',[Port]),
    format(atom(Jev),'http://127.0.0.1:~w/text_jev',[Port]),
    assertz(text_endpoint(model,Model)),assertz(text_endpoint(jev,Jev)),
    assertz(text_endpoint(port,Port)),
    node:set_node_shared_db('model_chat(M,R) :- model_service:model_chat(M,R).').
text_cleanup :- text_endpoint(port,Port),http_stop_server(Port,[]),retractall(text_endpoint(_,_)),node:set_node_shared_db('').
reset_model :- retractall(text_model_mode(_)),text_endpoint(model,URL),model_service:configure_model_service(URL),retractall(text_seen(model,_)).
with_jev(Goal) :-
    text_endpoint(jev,URL),
    (getenv('TYPESAFE_ENDPOINT',OldURL)->HadURL=true;HadURL=false),
    (getenv('TYPESAFE_API_KEY',OldKey)->HadKey=true;HadKey=false),
    setup_call_cleanup((setenv('TYPESAFE_ENDPOINT',URL),setenv('TYPESAFE_API_KEY','fixture-key'),
                        jev_service:configure_jev_service,retractall(text_seen(jev,_))),
      call(Goal),
      ((HadURL==true->setenv('TYPESAFE_ENDPOINT',OldURL);unsetenv('TYPESAFE_ENDPOINT')),
       (HadKey==true->setenv('TYPESAFE_API_KEY',OldKey);unsetenv('TYPESAFE_API_KEY')))).
input_text(native,"hé😀").
input_text(chars,[h,'é','😀']).
selected(Native,Expected) :-
    (current_predicate(text_config:text_double_quotes/1),text_config:text_double_quotes(chars)
    -> string_chars(Native,Expected) ; Expected=Native).
repeat_char(N,Char,Chars) :- length(Chars,N),maplist(=(Char),Chars).

:- begin_tests(service_text,[setup(text_setup),cleanup(text_cleanup)]).

test(strict_input_types,[forall(member(Bad,[_,atom_text,[97,98],[ab],["a"],[a|_],[[a]]]))]) :-
    assertion(\+example_text:native_text(Bad,_)),
    assertion(model_service:model_answer(Bad,error(invalid_prompt))),
    assertion(jev_service:jev_deployment_observation(Bad,unavailable(invalid_text))).

test(invalid_inputs_do_not_bind) :-
    assertion(\+example_text:bounded_native_text([X],500,_,_)),assertion(var(X)),
    assertion(\+example_text:bounded_native_text([a|Tail],500,_,_)),assertion(var(Tail)),
    Cycle=[a|Cycle],assertion(\+example_text:bounded_native_text(Cycle,500,_,_)).

test(empty_and_prompt_limits) :-
    forall(member(Empty,["",[]]),
      (assertion(model_service:model_answer(Empty,error(invalid_prompt))),
       assertion(jev_service:jev_deployment_observation(Empty,unavailable(invalid_text))))),
    repeat_char(500,'😀',Full),repeat_char(501,'😀',Long),
    assertion(model_service:message_text(Full,500,500)),assertion(jev_service:valid_text(Full)),
    assertion(\+model_service:message_text(Long,500,_)),assertion(\+jev_service:valid_text(Long)),
    assertion(\+text_seen(_,_)).

test(conversation_limits_and_json_types) :-
    repeat_char(499,a,User),repeat_char(1500,b,Assistant),
    model_service:valid_messages([user(User),assistant(Assistant),user([x])],JSON),
    JSON=[J1,J2,J3],assertion(string(J1.content)),assertion(string(J2.content)),assertion(J3.content=="x"),
    repeat_char(500,a,TooMuch),
    assertion(\+model_service:valid_messages([user(TooMuch),assistant(Assistant),user([x])],_)),
    assertion(\+model_service:valid_messages([user([a]),assistant([b]),user([c]),assistant([d]),user([e]),assistant([f]),user([g])],_)).

test(model_request_and_reply,[forall(member(Representation,[native,chars]))]) :-
    reset_model,input_text(Representation,Input),
    model_service:model_answer(Input,answer(Reply)),selected("räksmörgås 😀",Expected),
    assertion(Reply==Expected),text_seen(model,Payload),
    Payload.messages=[Message],assertion(Message.content=="hé😀"),assertion(string(Message.content)),
    assertion(Payload.stream==false),assertion(Payload.options.num_ctx==1024),
    assertion(Payload.options.num_predict==80),
    assertion(model_service:model_answer([a],error(rate_limited))).

test(model_mixed_history_json) :-
    reset_model,model_service:model_chat([user([h,i]),assistant("hello"),user([j,a])],answer(Reply)),
    selected("räksmörgås 😀",Expected),assertion(Reply==Expected),
    text_seen(model,P),P.messages=[A,B,C],assertion(A.content=="hi"),
    assertion(B.content=="hello"),assertion(C.content=="ja").

test(jev_request_reply_and_raw_json,[forall(member(Representation,[native,chars]))]) :-
    with_jev(jev_text_check(Representation)).

test(question_text_fields_convert_without_rewriting_state_json) :-
    with_jev(question_text_check).

test(model_response_byte_and_character_caps,[forall(member(Mode,[oversize_bytes,oversize_content]))]) :-
    reset_model,assertz(user:text_model_mode(Mode)),
    model_service:model_answer([h,i],error(model_unavailable)),
    assertion(model_service:model_answer([h,i],error(unavailable))),
    retractall(user:text_model_mode(_)).

test(jev_unicode_response_byte_cap) :-
    text_endpoint(jev,URL),setup_call_cleanup(assertz(user:text_jev_padding),
      (catch(jev_http:jev_http_request(_{state:"fixture"},_,
         [endpoint(URL),api_key("fixture-key"),max_response_bytes(1000)]),Error,true),
       assertion(nonvar(Error)),assertion(Error=error(resource_error(jev_response_too_large),_))),
      retractall(user:text_jev_padding)).

test(character_history_retains_complete_pairs_and_limit) :-
    text_chat_example:chat_trim([user([a]),assistant([b]),user([c]),assistant([d]),user([e]),assistant([f])],Kept),
    assertion(Kept==[user([c]),assistant([d]),user([e]),assistant([f])]),
    repeat_char(1501,a,Long),text_chat_example:chat_trim([user([x]),assistant(Long)],Empty),
    assertion(Empty==[]).

test(actor_example_copies_text_helpers) :-
    reset_model,read_file_to_string('examples/actors/21 model-actor.pl',Source,[]),
    self(Me),spawn((start_chat(C),Me ! chat(C),receive({stop->true})),Starter,[src_text(Source),monitor(true),
       src_list([(model_chat(M,R):-model_service:model_chat(M,R))])]),
    receive({chat(Chat)->true},[timeout(3),on_timeout(throw(no_chat))]),
    setup_call_cleanup(monitor(Chat,Ref),
      (Chat ! ask(Me,text,[h,i]),receive({answer(text,Reply)->true},[timeout(5),on_timeout(throw(no_model_reply))]),
       selected("räksmörgås 😀",Expected),assertion(Reply==Expected),
       text_seen(model,P),P.messages=[M],assertion(M.content=="hi")),
      (Chat ! stop,receive({down(Chat,Ref,_)->true},[timeout(3),on_timeout(exit(Chat,kill))]),demonitor(Ref,[flush]),Starter ! stop,
       receive({down(Starter,Starter,true)->true},[timeout(3),on_timeout(exit(Starter,kill))]))).

test(statechart_example_character_prompt_and_reply) :-
    reset_model,read_file_to_string('examples/statecharts/19 model-statechart.xml',XML,[]),
    statechart_spawn(P,[src_text(XML),trace(false),
      src_list([(model_chat(M,R):-model_service:model_chat(M,R))])]),
    setup_call_cleanup(monitor(P,Ref),
      (self(Me),P ! ask(Me,text,[h,i]),receive({answer(text,Reply)->true},[timeout(5),on_timeout(throw(no_chart_reply))]),
       selected("räksmörgås 😀",Expected),assertion(Reply==Expected),
       text_seen(model,Payload),Payload.messages=[M],assertion(M.content=="hi")),
      (statechart_halt(P,true,1),receive({down(P,Ref,_)->true},[timeout(3),on_timeout(fail)]),demonitor(Ref,[flush]))).

test(public_actor_example_uses_selected_text_mode) :-
    reset_model,read_file_to_string('examples/actors/21 model-actor.pl',Source,[]),
    selected("räksmörgås 😀",Expected),term_string(Expected,ExpectedText,[quoted(true)]),
    format(string(Goal),'self(Me),start_chat(C),C ! ask(Me,text,"hé😀"),receive({answer(text,Reply)->true},[timeout(5)]),Reply==~s,C ! stop,receive({down(C,C,true)->true},[timeout(3)]),Outcome=ok',[ExpectedText]),
    public_text_query(Source,Goal).

test(public_model_chart_uses_selected_text_mode) :-
    reset_model,read_file_to_string('examples/statecharts/19 model-statechart.xml',XML,[]),
    atom_string(XMLAtom,XML),term_string(XMLAtom,XMLText,[quoted(true)]),
    selected("räksmörgås 😀",Expected),term_string(Expected,ExpectedText,[quoted(true)]),
    format(string(Goal),'statechart_spawn(P,[src_text(~s),trace(false),monitor(true)]),self(Me),P ! ask(Me,text,"hé😀"),receive({answer(text,Reply)->true},[timeout(5)]),Reply==~s,statechart_halt(P,true,1),receive({down(P,P,_)->true},[timeout(3)]),Outcome=ok',[XMLText,ExpectedText]),
    public_text_query("",Goal).

:- end_tests(service_text).

jev_text_check(Representation) :-
    input_text(Representation,Input),jev_service:jev_deployment_observation(Input,Result),
    Result=observation(choice(affirm,_,1.0),score(1,Legend,_,0.75),noul(0.2),provenance(Raw)),
    selected("Low",Low),selected("Hög",High),assertion(Legend.'0'==Low),assertion(Legend.'1'==High),
    assertion(Raw.extension.empty_text==""),assertion(Raw.extension.empty_array==[]),
    assertion(Raw.extension.unicode=="😀"),assertion(Raw.extension.flags==[true,false,null]),
    text_seen(jev,Payload),assertion(Payload.state.message=="hé😀"),
    assertion(string(Payload.state.message)),assertion(string(Payload.questions.intent.instructions)),
    assertion(string(Payload.questions.intent.criteria.affirm)),
    assertion(jev_service:jev_deployment_observation([a],unavailable(rate_limited))).
question_text_check :-
    jev:jev_decide(_{native_json:"untouched",array:[1,2]},[
      choice([i,n,t,e,n,t],[w,h,a,t],[affirm-[y,e,s]],_),
      score(urgency,[h,o,w],[[l,o,w],[h,i,g,h]],_),
      noul(is_question,[q],_)],Raw,[model([j,e,v])]),
    text_seen(jev,P),assertion(P.model=="jev"),assertion(P.state.native_json=="untouched"),assertion(P.state.array==[1,2]),
    assertion(P.questions.intent.instructions=="what"),assertion(P.questions.intent.criteria.affirm=="yes"),
    assertion(P.questions.urgency.criteria==["low","high"]),
    assertion(Raw.extension.empty_text==""),assertion(Raw.extension.empty_array==[]).

:- begin_tests(service_text_owner_options,[setup(text_setup),cleanup(text_cleanup)]).
test(character_endpoint_and_key) :-
    text_endpoint(jev,URL),atom_chars(URL,Endpoint),string_chars("fixture-key",Key),
    jev_http:jev_http_request(_{state:"fixture"},Raw,[endpoint(Endpoint),api_key(Key)]),
    assertion(Raw.model=="mock"),text_seen(auth,'Bearer fixture-key').
:- end_tests(service_text_owner_options).

public_text_query(Source,Goal) :-
    tcp_socket(Socket),tcp_bind(Socket,ip(127,0,0,1):Port),tcp_listen(Socket,128),
    setup_call_cleanup(node(Port,[tcp_socket(Socket),auth(open),profile(actor),sandbox(blacklist),
      load_shared_db_text('model_chat(M,R) :- model_service:model_chat(M,R).')]),
      public_text_ws(Port,Source,Goal),http_stop_server(Port,[])).
public_text_ws(Port,Source,Goal) :-
    format(atom(URL),'http://localhost:~w/ws',[Port]),
    term_string([session(true),src_text(Source)],Options),
    setup_call_cleanup(http_open_websocket(URL,WS,[]),
      (text_ws_send(WS,_{command:toplevel_spawn,options:Options}),text_ws_read(WS,Spawn),
       text_ws_send(WS,_{command:toplevel_call,pid:Spawn.pid,goal:Goal,options:"[template(Outcome),format(prolog),limit(1)]"}),
       call_with_time_limit(10,text_ws_result(WS,Result)),
       assertion(Result.type=="success"),assertion(Result.data==["ok"]),
       text_ws_send(WS,_{command:toplevel_halt,pid:Spawn.pid}),
       call_with_time_limit(5,text_ws_halted(WS,Spawn.pid))),
      catch(ws_close(WS,1000,done),_,true)).
text_ws_send(WS,Dict) :- atom_json_dict(Text,Dict,[]),ws_send(WS,text(Text)).
text_ws_read(WS,Dict) :- ws_receive(WS,F),atom_json_dict(F.data,Dict,[]).
text_ws_result(WS,Result) :-
    text_ws_read(WS,Event),
    (memberchk(Event.type,["success","error","failure"]) -> Result=Event
    ; text_ws_result(WS,Result)).

text_ws_halted(WS,Pid) :-
    text_ws_read(WS,Event),
    (Event.type=="halted",Event.pid==Pid -> true ; text_ws_halted(WS,Pid)).
