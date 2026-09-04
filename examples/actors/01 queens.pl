%%  queens(+N, -Queens) is nondet.
%
%   Place N queens on an N x N board so that none attacks another, and
%   return their column positions. A reminder that Web Prolog is Prolog
%   first: this program uses no actors at all -- just ordinary clauses,
%   unification and backtracking search.
%
%   The board is built so that the diagonals each queen attacks are
%   threaded through shared variables (the VR/VC argument lists), letting
%   the constraints prune inconsistent placements early. Backtracking
%   then explores placements until a consistent one is found; asking for
%   further solutions enumerates the rest.
%
%	@param	N       - the number of queens, and the size of the board.
%	@param	Queens  - a list of N column numbers, one per row.
%	@author Richard A. O'Keefe (The Craft of Prolog)

queens(N, Queens) :-
    length(Queens, N),
	board(Queens, Board, 0, N, _, _),
	queens(Board, 0, Queens).

board([], [], N, N, _, _).
board([_|Queens], [Col-Vars|Board], Col0, N, [_|VR], VC) :-
	Col is Col0+1,
	functor(Vars, f, N),
	constraints(N, Vars, VR, VC),
	board(Queens, Board, Col, N, VR, [_|VC]).

constraints(0, _, _, _) :- !.
constraints(N, Row, [R|Rs], [C|Cs]) :-
	arg(N, Row, R-C),
	M is N-1,
	constraints(M, Row, Rs, Cs).

queens([], _, []).
queens([C|Cs], Row0, [Col|Solution]) :-
	Row is Row0+1,
	select(Col-Vars, [C|Cs], Board),
	arg(Row, Vars, Row-Row),
	queens(Board, Row, Solution).


/** <examples>

% One solution to the 8-queens puzzle. Ask for more (press ; or the
% More button) to enumerate the remaining placements by backtracking.

?- queens(8, Queens).

*/