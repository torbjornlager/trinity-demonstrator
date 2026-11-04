:- op(800, xfx, !).
:- include('../examples/services/linda_space.pl').
:- include('../examples/services/linda_bounded_space.pl').
check :-
    linda_term_budget(pair(hello,world), 4096, _),
    length(Ts,512), maplist(=(occupied),Ts),
    linda_admission_error(out(new),Ts,[],tuple_space_full),
    length(Available,511), maplist(=(occupied),Available),
    \+ linda_admission_error(out(new),Available,[],_),
    \+ linda_admission_error(in(occupied),Ts,[],_),
    length(Ps,256),
    linda_admission_error(in(missing),Ts,Ps,pending_requests_full),
    length(PendingRoom,255),
    \+ linda_admission_error(in(missing),Ts,PendingRoom,_),
    \+ linda_admission_error(rd(occupied),Ts,Ps,_),
    \+ linda_admission_error(inp(missing),Ts,Ps,_),
    length(Cs,4097), maplist(=(a),Cs), atom_chars(Big,Cs),
    linda_admission_error(out(Big),[],[],tuple_too_large),
    \+ linda_admission_error(out(hello),[],[],_),
    writeln('Linda admission: tuple/pending/size bounds; existing reads/takes/probes preserved.').
:- initialization((check -> halt(0); halt(1))).
