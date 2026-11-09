:- module(stateless_rpc).
:- lib(prolog_extras).
:- export rpc/2, rpc/3.
:- export goal_template_texts/4.

rpc(Node, Goal) :-
    rpc(Node, Goal, []).

rpc(Node, Goal, Options) :-
    endpoint(Node, Host, Port, Authority),
    rpc_options(Options, Limit, Once),
    term_variables(Goal, Variables),
    Template =.. [v|Variables],
    goal_template_texts(Goal, Template, GoalText, TemplateText),
    url_encode(GoalText, EncodedGoal),
    url_encode(TemplateText, EncodedTemplate),
    concat_string(["/call?format=prolog&goal=", EncodedGoal,
                   "&template=", EncodedTemplate, "&limit=", Limit,
                   "&once=", Once, "&offset="], Prefix),
    rpc_page(Host, Port, Authority, Prefix, 0, Once, Template).

rpc_options(Options, Limit, Once) :-
    ( is_list(Options), rpc_options(Options, 100, false, Limit, Once) -> true
    ; throw(error(domain_error(rpc_options, Options), rpc/3))
    ).

rpc_options([], Limit, Once, Limit, Once).
rpc_options([limit(N)|Options], _, Once0, Limit, Once) :-
    integer(N), N > 0,
    rpc_options(Options, N, Once0, Limit, Once).
rpc_options([once(Value)|Options], Limit0, _, Limit, Once) :-
    ( Value == true ; Value == false ),
    rpc_options(Options, Limit0, Value, Limit, Once).

goal_template_texts(Goal, Template, GoalText, TemplateText) :-
    term_variables(Goal-Template, Variables),
    variable_names(Variables, 1, Names),
    query_text(Goal, Names, GoalText),
    query_text(Template, Names, TemplateText).

variable_names([], _, []).
variable_names([Variable|Variables], Index, [Name=Variable|Names]) :-
    concat_atom(['RPC', Index], Name),
    Next is Index + 1,
    variable_names(Variables, Next, Names).

query_text(Term, Names, Text) :-
    setup_call_cleanup(
        open(string(""), write, Stream),
        ( write_term(Stream, Term, [quoted(true), max_depth(0), variable_names(Names)]),
          get_stream_info(Stream, name, Text)
        ),
        close(Stream)
    ).

url_encode(Text, Encoded) :-
    string_list(Text, Bytes),
    phrase(encode_bytes(Bytes), Codes),
    string_list(Encoded, Codes).

encode_bytes([]) --> [].
encode_bytes([Byte|Bytes]) -->
    ( { uri_unreserved(Byte) } -> [Byte]
    ; { High is Byte // 16, Low is Byte mod 16,
        hex_digit(High, A), hex_digit(Low, B) },
      [0'%, A, B]
    ),
    encode_bytes(Bytes).

uri_unreserved(Byte) :-
    ( Byte >= 0'a, Byte =< 0'z
    ; Byte >= 0'A, Byte =< 0'Z
    ; Byte >= 0'0, Byte =< 0'9
    ; memberchk(Byte, [0'-,0'.,0'_,0'~])
    ).

hex_digit(N, Code) :-
    ( N < 10 -> Code is 0'0 + N ; Code is 0'A + N - 10 ).

endpoint(Node, Host, Port, Authority) :-
    ( ( atom(Node) -> atom_string(Node, URL) ; string(Node), URL = Node ),
      append_strings("http://", Tail, URL),
      ( append_strings(Authority, "/", Tail) -> true ; Authority = Tail ),
      split_string(Authority, ":", "", Parts),
      endpoint_parts(Parts, HostText, Port),
      string_list(HostText, HostCodes),
      HostCodes = [_|_],
      checklist(host_code, HostCodes) ->
        atom_string(Host, HostText)
    ;
        throw(error(domain_error(http_node_origin, Node), rpc/3))
    ).

endpoint_parts([Host], Host, 80).
endpoint_parts([Host, PortText], Host, Port) :-
    number_string(Port, PortText),
    integer(Port), Port > 0, Port =< 65535.

host_code(Code) :-
    Code \== 0'~, Code \== 0'_,
    uri_unreserved(Code).

rpc_page(Host, Port, Authority, Prefix, Offset, Once, Template) :-
    concat_string([Prefix, Offset], Target),
    http_answer(Host, Port, Authority, Target, Answer),
    ( Answer = success(Rows, More), is_list(Rows),
      ( More == false ; More == true, Rows = [_|_] ) ->
        ( member(Template, Rows)
        ; More == true, Once == false,
          length(Rows, Count),
          NextOffset is Offset + Count,
          rpc_page(Host, Port, Authority, Prefix, NextOffset, Once, Template)
        )
    ; Answer == failure ->
        fail
    ; Answer = error(Error) ->
        throw(Error)
    ;
        throw(error(invalid_rpc_answer(Answer), rpc/3))
    ).

% HTTP/1.0 with Connection: close keeps the loopback probe independent of
% the legacy HTTP library's fixed response-header grammar.
http_answer(Host, Port, Authority, Target, Answer) :-
    setup_call_cleanup(
        socket(internet, stream, Socket),
        ( connect(Socket, Host / Port),
          printf(Socket, "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
                 [Target, Authority]),
          flush(Socket),
          read_http_body(Socket, Body)
        ),
        close(Socket)
    ),
    ( setup_call_cleanup(
          open(string(Body), read, Stream),
          ( read(Stream, Answer), read(Stream, end_of_file), at_eof(Stream) ),
          close(Stream)
      ), nonvar(Answer) -> true
    ;
        throw(error(invalid_rpc_response, rpc/3))
    ).

read_http_body(Socket, Body) :-
    ( read_string(Socket, end_of_line, _, Line),
      split_string(Line, " ", "\r", [Version, Status|_]),
      append_strings("HTTP/", _, Version) ->
        ( Status == "200" -> true ; throw(error(rpc_http_status(Status), rpc/3)) )
    ;
        throw(error(invalid_rpc_http_status, rpc/3))
    ),
    skip_headers(Socket),
    ( read_string(Socket, end_of_file, _, Body) -> true ; Body = "" ).

skip_headers(Socket) :-
    ( read_string(Socket, end_of_line, _, Line) ->
        ( (Line == "" ; Line == "\r") -> true ; skip_headers(Socket) )
    ;
        throw(error(incomplete_rpc_http_headers, rpc/3))
    ).
