% Owner-only credential input shared by the generic and named node launchers.
:- module(deployment_peer_transport,[peer_transport_options/1,peer_transport_options/2]).

peer_transport_options(Options) :-
    (getenv('WP_PEER_TRANSPORT_TOKENS_FILE',File) -> true ; File=''),
    peer_transport_options(File,Options).

% Exact URLs bind credentials to their destination. Never echo their values.
peer_transport_options(File,Options) :-
    ( File == '' -> Options=[]
    ; ( catch((setup_call_cleanup(open(File,read,In),
                    (read_term(In,Tokens,[]),read_term(In,End,[])),close(In)),
                End == end_of_file, is_list(Tokens), ground(Tokens),
                maplist(node:valid_peer_token,Tokens)), _, fail)
      -> Options=[peer_transport_tokens(Tokens)]
      ; throw(error(invalid_peer_transport_tokens_file,peer_transport_options/2)) )
    ).
