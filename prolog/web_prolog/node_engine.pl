:- module(node_engine, [
    compute_answer/5,
    compute_answer/6,
    compute_answer/7,
    compute_answer/8,
    cache/3
]).

/** <module> Stateless Node Query Engine

Core `/call` answer computation and continuation cache management.
*/

:- use_module(actor_api).
:- use_module(toplevel_actors).
:- use_module(rpc, [text_to_string/2]).
:- use_module(node_runtime_state, [current_node_port/1]).

:- use_module(library(settings)).
:- use_module(library(time), [alarm/4, remove_alarm/1]).

:- dynamic cache/3.
:- dynamic cache_alarm/4.

%!  cache(?Gid, ?Offset, ?Pid) is nondet.
%
%   Dynamic continuation cache for stateless `/call` paging. Every entry has
%   a matching `cache_alarm/4`; an unused entry is removed and its actor is
%   stopped after the node's `cache_ttl`.
%   `Gid` is a goal/template/load-text hash, `Offset` is the next slice offset,
%   and `Pid` is the toplevel actor that still owns remaining solutions.


%!  compute_answer(+Goal, +Template, +Offset, +Limit, -Answer) is det.
%!  compute_answer(+Goal, +Template, +Offset, +Limit, +LoadText, -Answer) is det.
%!  compute_answer(+Goal, +Template, +Offset, +Limit, +LoadText,
%!                 +RequestedTimeout, -Answer) is det.
%!  compute_answer(+Goal, +Template, +Offset, +Limit, +LoadText,
%!                 +RequestedTimeout, +Once, -Answer) is det.
%
%   Core stateless query engine used by `/call`.
compute_answer(Goal, Template, Offset, Limit, Answer) :-
    compute_answer(Goal, Template, Offset, Limit, '', none, false, Answer).

compute_answer(Goal, Template, Offset, Limit, LoadText, Answer) :-
    compute_answer(Goal, Template, Offset, Limit, LoadText, none, false, Answer).

compute_answer(Goal, Template, Offset, Limit, LoadText, RequestedTimeout, Answer) :-
    compute_answer(Goal, Template, Offset, Limit, LoadText, RequestedTimeout, false, Answer).

compute_answer(Goal, Template, Offset, Limit, LoadText, RequestedTimeout,
               Once, Answer) :-
    goal_id(Goal-Template-LoadText-Once, GoalId),
    cache_key(GoalId, Gid),
    node:effective_timeout(RequestedTimeout, Timeout),
    setup_call_cleanup(
        message_queue_create(Queue),
        compute_answer_with_queue(Queue, Gid, Goal, Template, Offset, Limit,
                                  LoadText, Timeout, Once, Answer),
        catch(message_queue_destroy(Queue), _, true)
    ).

compute_answer_with_queue(Queue, Gid, Goal, Template, Offset, Limit,
                          LoadText, Timeout, Once, Answer) :-
    (   cache_retract(Gid, Offset, Pid)
    ->  toplevel_next(Pid, [
            limit(Limit),
            target(Queue)
        ])
    ;   toplevel_spawn_options(LoadText, SpawnOptions0),
        SpawnOptions = [target(Queue)|SpawnOptions0],
        toplevel_spawn(Pid, SpawnOptions),
        toplevel_call(Pid, Goal, [
            template(Template),
            offset(Offset),
            limit(Limit),
            once(Once),
            target(Queue)
        ])
    ),
    wait_for_compute_answer(Queue, Timeout, Pid, Offset, Limit, Gid, Once, Answer).

wait_for_compute_answer(Queue, Timeout, Pid, Offset, Limit, Gid, Once, Answer) :-
    (   thread_get_message(Queue, Message, [timeout(Timeout)])
    ->  compute_answer_message(Message, Queue, Timeout, Pid, Offset, Limit,
                               Gid, Once, Answer)
    ;   Answer = error(timeout),
        exit(Pid, kill)
    ).

compute_answer_message(success(Pid, Slice, true), _Queue, _Timeout, Pid,
                       Offset, Limit, Gid, Once, Answer) :-
    !,
    (   Once == true
    ->  toplevel_stop(Pid),
        Answer = success(Slice, false)
    ;   Index is Offset + Limit,
        cache_update(Gid, Index, Pid),
        Answer = success(Slice, true)
    ).
compute_answer_message(success(Pid, Slice, false), _Queue, _Timeout, Pid,
                       _Offset, _Limit, _Gid, _Once, success(Slice, false)) :-
    !.
compute_answer_message(failure(Pid), _Queue, _Timeout, Pid,
                       _Offset, _Limit, _Gid, _Once, failure) :-
    !.
compute_answer_message(error(Pid, Error), _Queue, _Timeout, Pid,
                       _Offset, _Limit, _Gid, _Once, error(Error)) :-
    !.
compute_answer_message(_Unexpected, Queue, Timeout, Pid, Offset, Limit, Gid,
                       Once, Answer) :-
    wait_for_compute_answer(Queue, Timeout, Pid, Offset, Limit, Gid, Once, Answer).


%!  toplevel_spawn_options(+LoadText0, -SpawnOptions) is det.
%
%   Shared DB is accessed through the module import chain, so only
%   client-provided load_text needs to be passed as a spawn option.
toplevel_spawn_options(LoadText0, SpawnOptions) :-
    text_to_string(LoadText0, LoadText),
    (   LoadText == ""
    ->  SpawnOptions = []
    ;   SpawnOptions = [load_text(LoadText)]
    ).


%!  goal_id(+GoalTemplate, -Gid:integer) is det.
%
%   Stable hash key for cache lookup, independent of variable identities.
goal_id(GoalTemplate, Gid) :-
    copy_term(GoalTemplate, Gid0),
    numbervars(Gid0, 0, _),
    term_hash(Gid0, Gid).


cache_key(GoalId, node_cache(NodeKey, GoalId)) :-
    node_cache_key(NodeKey).


node_cache_key(NodeKey) :-
    (   current_node_port(Port)
    ->  NodeKey = node_port(Port)
    ;   NodeKey = global
    ).


%!  cache_retract(?Gid, ?N, ?Pid) is semidet.
%
%   Retract one cache entry (oldest first under current insertion order).
cache_retract(Gid, N, Pid) :-
    with_mutex(node_engine_cache,
               cache_take(Gid, N, Pid, AlarmId)),
    cancel_cache_alarm(AlarmId).


cache_take(Gid, N, Pid, AlarmId) :-
    once(retract(cache(Gid, N, Pid))),
    (   retract(cache_alarm(Gid, N, Pid, AlarmId0))
    ->  AlarmId = AlarmId0
    ;   AlarmId = none
    ).


%!  cache_update(+Gid, +N, +Pid) is det.
%
%   Insert a cache entry with a bounded idle lifetime and evict the oldest
%   entry when `cache_size` is exceeded. Expiry and eviction both stop the
%   associated toplevel actor.
cache_update(Gid, N, Pid) :-
    node:effective_cache_ttl(CacheTTL),
    node:effective_cache_size(Size),
    with_mutex(node_engine_cache,
               cache_insert(Gid, N, Pid, CacheTTL, Size, Evicted)),
    dispose_cache_entry(Evicted).


cache_insert(Gid, N, Pid, CacheTTL, Size, Evicted) :-
    alarm(CacheTTL, cache_expire(Gid, N, Pid), AlarmId, [remove(true)]),
    assertz(cache(Gid, N, Pid)),
    assertz(cache_alarm(Gid, N, Pid, AlarmId)),
    cache_node_key(Gid, NodeKey),
    aggregate_all(count, cache(node_cache(NodeKey, _), _, _), NC),
    (   NC > Size
    ->  cache_take(node_cache(NodeKey, _), _, EvictedPid, EvictedAlarm),
        Evicted = cache_entry(EvictedPid, EvictedAlarm)
    ;   Evicted = none
    ).


cache_node_key(node_cache(NodeKey, _), NodeKey).
cache_node_key(_, global).


%!  cache_expire(+Gid, +N, +Pid) is det.
%
%   Alarm callback for an idle continuation. Taking the alarm metadata under
%   the cache mutex makes expiry race safely with a client requesting the next
%   slice: exactly one side acquires and owns the actor.
cache_expire(Gid, N, Pid) :-
    with_mutex(node_engine_cache,
               (   retract(cache_alarm(Gid, N, Pid, _))
               ->  retractall(cache(Gid, N, Pid)),
                   Expired = true
               ;   Expired = false
               )),
    (   Expired == true
    ->  stop_cached_toplevel(Pid)
    ;   true
    ).


dispose_cache_entry(none) :-
    !.
dispose_cache_entry(cache_entry(Pid, AlarmId)) :-
    cancel_cache_alarm(AlarmId),
    stop_cached_toplevel(Pid).


cancel_cache_alarm(none) :-
    !.
cancel_cache_alarm(AlarmId) :-
    catch(remove_alarm(AlarmId), _, true).


stop_cached_toplevel(Pid) :-
    catch(toplevel_stop(Pid), _, true).
