:- module(chunked_solutions).
:- use_module(solution_buffer).
:- lib(prolog_extras).

:- export findnsols/4.
:- export new_chunk_count/2, set_chunk_count/2.
:- tool(findnsols/4, findnsols_/5).

findnsols_(Count, Template, Goal, Chunk, Module) :-
    chunk_size(Count, Size),
    ( Size =:= 0 ->
        Chunk = []
    ;
        setup_call_cleanup(
            engine_create(Engine, []),
            next_chunk(Engine, collect(Size, Template, Goal, Module), Count, Chunk),
            close_search(Engine)
        )
    ).

% A literal count(N) is fixed. A count backed by a shelf can be updated
% between solutions, and the update survives backtracking.
new_chunk_count(Size, count(Shelf)) :-
    check_count(Size),
    shelf_create(chunk_size(Size), Shelf).

set_chunk_count(count(Shelf), Size) :-
    check_count(Size),
    shelf_set(Shelf, 1, Size).

chunk_size(Count, Size) :-
    ( nonvar(Count), Count = count(Value) ->
        ( is_handle(Value) -> shelf_get(Value, 1, Size) ; Size = Value )
    ;
        Size = Count
    ),
    check_count(Size).

check_count(Count) :-
    Context = findnsols/4,
    ( var(Count) -> throw(error(instantiation_error, Context))
    ; \+ integer(Count) -> throw(error(type_error(integer, Count), Context))
    ; Count < 0 -> throw(error(domain_error(not_less_than_zero, Count), Context))
    ; true
    ).

next_chunk(Engine, Input, Count, Chunk) :-
    engine_resume(Engine, Input, Status),
    ( Status = yielded(more(Answers)) ->
        ( Chunk = Answers
        ; chunk_size(Count, Size),
          next_chunk(Engine, next(Size), Count, Chunk)
        )
    ; Status = yielded(last(Answers)) ->
        Chunk = Answers
    ; Status = exception(Error) ->
        throw(Error)
    ;
        throw(error(unexpected_search_status(Status), findnsols/4))
    ).

close_search(Engine) :-
    ( get_engine_property(Engine, status, yielded(_)) ->
        % Unwind the suspended goal on its own stack so its cleanup runs.
        engine_resume(Engine, stop, _)
    ;
        true
    ).

collect(Count, Template, Goal, Module) :-
    new_solution_buffer(Buffer),
    shelf_create(chunk_limit(Count), State),
    ( sepia_kernel:get_cut(Before),
      call(Goal)@Module,
      sepia_kernel:get_cut(After),
      shelf_get(State, 1, Limit),
      buffer_solution(Buffer, Template, Limit, Full),
      ( Before == After ->
          !,
          last_chunk(Buffer)
      ; Full == true ->
          buffered_solutions(Buffer, Chunk),
          clear_solution_buffer(Buffer),
          yield(more(Chunk), Command),
          ( Command == stop -> !
          ; Command = next(NextSize),
            shelf_set(State, 1, NextSize),
            fail
          )
      ;
          fail
      )
    ;
        last_chunk(Buffer)
    ).

last_chunk(Buffer) :-
    buffered_solutions(Buffer, Chunk),
    yield(last(Chunk), _).
