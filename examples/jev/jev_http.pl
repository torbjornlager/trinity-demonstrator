:- module(jev_http, [
    jev_http_request/2,
    jev_http_request/3
]).

/** <module> Minimal HTTP transport for TypeSafe Jev

This module knows only the Jev HTTP wire protocol.  The higher-level
question vocabulary lives in jev.pl.

By default the API key is read from `TYPESAFE_API_KEY`.  The endpoint may be
overridden with `TYPESAFE_ENDPOINT`; this is useful for gateways and tests.
Neither value is stored in source.
*/

:- use_module(library(http/http_open)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(option)).
:- use_module(library(error)).

default_endpoint('https://api.typesafe.ai/v1/systemone').

%!  jev_http_request(+Payload:dict, -Response:dict) is det.
%!  jev_http_request(+Payload:dict, -Response:dict, +Options:list) is det.
%
%   POST Payload to Jev and return the complete decoded response.  Options:
%
%     - endpoint(+URL)
%       Override `TYPESAFE_ENDPOINT` and the official endpoint.
%     - api_key(+Key)
%       Supply a key from an application configuration layer.  If omitted,
%       `TYPESAFE_API_KEY` is required.
%     - timeout(+Seconds)
%       HTTP timeout, default 15 seconds.
%     - max_response_bytes(+Bytes)
%       Maximum accepted response body, default 1 MiB.

jev_http_request(Payload, Response) :-
    jev_http_request(Payload, Response, []).

jev_http_request(Payload, Response, Options) :-
    must_be(dict, Payload),
    must_be(list, Options),
    configured_endpoint(Options, Endpoint),
    configured_key(Options, Key),
    option(timeout(Timeout), Options, 15),
    option(max_response_bytes(MaxBytes), Options, 1048576),
    must_be(number, Timeout),
    must_be(positive_integer, MaxBytes),
    format(string(Authorization), 'Bearer ~s', [Key]),
    catch(
        setup_call_cleanup(
            http_open(Endpoint, Stream,
                      [ method(post),
                        post(json(Payload)),
                        request_header('Authorization'=Authorization),
                        request_header('Accept'='application/json'),
                        status_code(Status),
                        timeout(Timeout),
                        redirect(false)
                      ]),
            read_response(Stream, Status, MaxBytes, Response),
            close(Stream)),
        Error,
        rethrow_transport_error(Error)).

configured_endpoint(Options, Endpoint) :-
    (   option(endpoint(Endpoint0), Options)
    ->  text_atom(Endpoint0, Endpoint)
    ;   getenv('TYPESAFE_ENDPOINT', Env), Env \== ''
    ->  atom_string(Endpoint, Env)
    ;   default_endpoint(Endpoint)
    ).

configured_key(Options, Key) :-
    (   option(api_key(Key0), Options)
    ->  text_string(Key0, Key)
    ;   getenv('TYPESAFE_API_KEY', Key), Key \== ''
    ->  true
    ;   throw(error(existence_error(configuration, 'TYPESAFE_API_KEY'),
                    context(jev_http:jev_http_request/3,
                            'Set TYPESAFE_API_KEY or supply api_key/1 from configuration')))
    ).

read_response(Stream, Status, MaxBytes, Response) :-
    Limit is MaxBytes + 1,
    read_string(Stream, Limit, Body),
    string_length(Body, Length),
    (   Length > MaxBytes
    ->  throw(error(resource_error(jev_response_too_large),
                    context(jev_http:jev_http_request/3, MaxBytes)))
    ;   true
    ),
    (   between(200, 299, Status)
    ->  parse_json_response(Body, Response)
    ;   throw(error(jev_http_error(Status, Body),
                    context(jev_http:jev_http_request/3, 'Jev returned an HTTP error')))
    ).

parse_json_response(Body, Response) :-
    catch(atom_json_dict(Body, Response, []), Error,
          throw(error(jev_invalid_json(Body),
                      context(jev_http:jev_http_request/3, Error)))),
    (   is_dict(Response)
    ->  true
    ;   throw(error(jev_invalid_response(Response),
                    context(jev_http:jev_http_request/3,
                            'Jev response must be a JSON object')))
    ).

rethrow_transport_error(error(jev_http_error(Status, Body), Context)) :-
    throw(error(jev_http_error(Status, Body), Context)).
rethrow_transport_error(error(jev_invalid_json(Body), Context)) :-
    throw(error(jev_invalid_json(Body), Context)).
rethrow_transport_error(error(jev_invalid_response(Response), Context)) :-
    throw(error(jev_invalid_response(Response), Context)).
rethrow_transport_error(error(resource_error(jev_response_too_large), Context)) :-
    throw(error(resource_error(jev_response_too_large), Context)).
rethrow_transport_error(error(existence_error(configuration, Name), Context)) :-
    throw(error(existence_error(configuration, Name), Context)).
rethrow_transport_error(Error) :-
    throw(error(jev_unavailable(Error),
                context(jev_http:jev_http_request/3,
                        'Jev request failed before a usable response arrived'))).

text_atom(Value, Atom) :-
    (   atom(Value) -> Atom = Value
    ;   string(Value) -> atom_string(Atom, Value)
    ;   type_error(text, Value)
    ).

text_string(Value, String) :-
    (   string(Value) -> String = Value
    ;   atom(Value) -> atom_string(Value, String)
    ;   type_error(text, Value)
    ).
