:- module(node_engine, [
    compute_answer/5,
    compute_answer/6,
    compute_answer/7,
    compute_answer/8,
    cache/3,
    clear_cache/0,
    clear_node_cache/1
]).

/** <module> Stateless Node Query Engine

Core `/call` answer computation and continuation cache management.
*/

:- use_module(actor_api).
:- use_module(toplevel_actors).
:- use_module(rpc, [text_to_string/2]).
:- use_module(node_runtime_state, [current_node_port/1]).

:- use_module(library(settings)).
:- use_module(library(time), [alarm/4, install_alarm/1, remove_alarm/1]).

:- dynamic cache/3.
:- dynamic cache_alarm/4.
:- dynamic managed_cache_alarm/2.

%!  cache(?Gid, ?Offset, ?Pid) is nondet.
%
%   Dynamic continuation cache for stateless `/call` paging. Every entry has
%   a matching `cache_alarm/4`; an unused entry is removed and its actor is
%   stopped after the node's `cache_ttl`. `cache_alarm/4` stores an ordinary
%   integer timer reference. The SWI alarm blob itself remains owned by the
%   long-lived cache timer thread, so an HTTP worker can terminate without
%   invalidating cache metadata retained by the node.
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
%   client-provided src_text needs to be passed as a spawn option.
toplevel_spawn_options(LoadText0, SpawnOptions) :-
    text_to_string(LoadText0, LoadText),
    (   LoadText == ""
    ->  SpawnOptions = []
    ;   SpawnOptions = [src_text(LoadText)]
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
               cache_take(Gid, N, Pid, TimerRef)),
    cancel_cache_alarm(TimerRef).


cache_take(Gid, N, Pid, TimerRef) :-
    once(retract(cache(Gid, N, Pid))),
    (   retract(cache_alarm(Gid, N, Pid, TimerRef0))
    ->  TimerRef = TimerRef0
    ;   TimerRef = none
    ).


%!  clear_cache is det.
%!  clear_node_cache(+Port:integer) is det.
%
%   Remove cached continuations and stop their actors. The node-scoped form
%   leaves entries belonging to other nodes in the same SWI process intact.
clear_cache :-
    clear_cache_matching(all).

clear_node_cache(Port) :-
    clear_cache_matching(node(node_port(Port))).

clear_cache_matching(Scope) :-
    with_mutex(node_engine_cache,
               cache_take_all(Scope, Entries)),
    maplist(dispose_cache_entry, Entries).

cache_take_all(Scope, Entries) :-
    (   cache_take_matching(Scope, Pid, TimerRef)
    ->  Entries = [cache_entry(Pid, TimerRef)|Rest],
        cache_take_all(Scope, Rest)
    ;   Entries = []
    ).

cache_take_matching(all, Pid, TimerRef) :-
    cache_take(_, _, Pid, TimerRef).
cache_take_matching(node(NodeKey), Pid, TimerRef) :-
    cache_take(node_cache(NodeKey, _), _, Pid, TimerRef).


%!  cache_update(+Gid, +N, +Pid) is det.
%
%   Insert a cache entry with a bounded idle lifetime and evict the oldest
%   entry when `cache_size` is exceeded. Expiry and eviction both stop the
%   associated toplevel actor.
cache_update(Gid, N, Pid) :-
    node:effective_cache_ttl(CacheTTL),
    node:effective_cache_size(Size),
    next_cache_timer_ref(TimerRef),
    with_mutex(node_engine_cache,
               cache_insert(Gid, N, Pid, TimerRef, Size, Evicted)),
    catch(schedule_cache_alarm(TimerRef, CacheTTL, Gid, N, Pid),
          Error,
          ( rollback_cache_insert(Gid, N, Pid, TimerRef),
            dispose_cache_entry(Evicted),
            throw(Error)
          )),
    dispose_cache_entry(Evicted).


cache_insert(Gid, N, Pid, TimerRef, Size, Evicted) :-
    assertz(cache(Gid, N, Pid)),
    assertz(cache_alarm(Gid, N, Pid, TimerRef)),
    cache_node_key(Gid, NodeKey),
    aggregate_all(count, cache(node_cache(NodeKey, _), _, _), NC),
    (   NC > Size
    ->  cache_take(node_cache(NodeKey, _), _, EvictedPid, EvictedAlarm),
        Evicted = cache_entry(EvictedPid, EvictedAlarm)
    ;   Evicted = none
    ).


rollback_cache_insert(Gid, N, Pid, TimerRef) :-
    with_mutex(node_engine_cache,
               ( retractall(cache(Gid, N, Pid)),
                 retractall(cache_alarm(Gid, N, Pid, TimerRef))
               )),
    stop_cached_toplevel(Pid).


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
dispose_cache_entry(cache_entry(Pid, TimerRef)) :-
    cancel_cache_alarm(TimerRef),
    stop_cached_toplevel(Pid).


cancel_cache_alarm(none) :-
    !.
cancel_cache_alarm(TimerRef) :-
    cache_timer_request(cancel(TimerRef), _).


%  SWI alarms belong to the thread that creates them and are silently removed
%  when that thread terminates. HTTP request workers are therefore the wrong
%  owners for continuation timers: cache entries outlive individual requests,
%  and a later remove_alarm/1 on a worker's retired alarm blob can crash the
%  process. Keep every native alarm in one process-lifetime manager and expose
%  only integer references to request threads.
next_cache_timer_ref(TimerRef) :-
    flag(node_engine_cache_timer_ref, TimerRef, TimerRef + 1).

schedule_cache_alarm(TimerRef, CacheTTL, Gid, N, Pid) :-
    cache_timer_request(schedule(TimerRef, CacheTTL, Gid, N, Pid), Reply),
    (   Reply == scheduled
    ->  true
    ;   Reply = error(Error),
        throw(Error)
    ).

cache_timer_request(Request, Reply) :-
    ensure_cache_timer_manager,
    cache_timer_alias(Alias),
    setup_call_cleanup(
        message_queue_create(ReplyQueue),
        ( thread_send_message(Alias, cache_timer_request(ReplyQueue, Request)),
          thread_get_message(ReplyQueue, Reply)
        ),
        message_queue_destroy(ReplyQueue)
    ).

ensure_cache_timer_manager :-
    cache_timer_alias(Alias),
    (   thread_property(_, alias(Alias))
    ->  true
    ;   with_mutex(node_engine_cache_timer_start,
            (   thread_property(_, alias(Alias))
            ->  true
            ;   thread_create(cache_timer_loop, _,
                              [alias(Alias), detached(true)])
            ))
    ).

cache_timer_alias(node_engine_cache_timer).

cache_timer_loop :-
    thread_get_message(cache_timer_request(ReplyQueue, Request)),
    cache_timer_handle(Request, Reply),
    catch(thread_send_message(ReplyQueue, Reply), _, true),
    cache_timer_loop.

cache_timer_handle(schedule(TimerRef, CacheTTL, Gid, N, Pid), Reply) :-
    catch(
        ( alarm(CacheTTL,
                cache_timer_expired(TimerRef, Gid, N, Pid),
                AlarmId,
                [install(false), remove(true)]),
          assertz(managed_cache_alarm(TimerRef, AlarmId)),
          install_alarm(AlarmId),
          Reply = scheduled
        ),
        Error,
        ( ( nonvar(AlarmId) -> catch(remove_alarm(AlarmId), _, true) ; true ),
          retractall(managed_cache_alarm(TimerRef, _)),
          Reply = error(Error)
        )
    ).
cache_timer_handle(cancel(TimerRef), cancelled) :-
    (   retract(managed_cache_alarm(TimerRef, AlarmId))
    ->  catch(remove_alarm(AlarmId), _, true)
    ;   true
    ).

cache_timer_expired(TimerRef, Gid, N, Pid) :-
    retractall(managed_cache_alarm(TimerRef, _)),
    cache_expire(Gid, N, Pid).


stop_cached_toplevel(Pid) :-
    catch(toplevel_stop(Pid), _, true).
