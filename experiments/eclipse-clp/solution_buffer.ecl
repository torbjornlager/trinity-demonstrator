:- module(solution_buffer).

:- export new_solution_buffer/1, buffer_solution/4.
:- export solution_count/2, buffered_solutions/2, clear_solution_buffer/1.

% A private FIFO of copied answer templates. The record and count survive
% backtracking through the goal, and the driver decides when to clear them.
new_solution_buffer(Buffer) :-
    record_create(Answers),
    shelf_create(buffer(Answers, 0), Buffer).

buffer_solution(Buffer, Template, Limit, Full) :-
    shelf_get(Buffer, 1, Answers),
    recordz(Answers, Template),
    shelf_inc_and_get(Buffer, 2, Count),
    ( Count == Limit -> Full = true ; Full = false ).

solution_count(Buffer, Count) :-
    shelf_get(Buffer, 2, Count).

buffered_solutions(Buffer, Solutions) :-
    shelf_get(Buffer, 1, Answers),
    recorded_list(Answers, Solutions).

clear_solution_buffer(Buffer) :-
    shelf_get(Buffer, 1, Answers),
    erase_all(Answers),
    shelf_set(Buffer, 2, 0).
