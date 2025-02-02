%%% Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
%%%
%%% This source code is licensed under the Apache 2.0 license found in
%%% the LICENSE file in the root directory of this source tree.
%%%
%%% This module manages data catchup to followers.

-module(wa_raft_catchup).
-compile(warn_missing_spec).
-author(['huiliu@fb.com']).

-behavior(gen_event).

-include_lib("kernel/include/logger.hrl").
-include("wa_raft.hrl").
-include("wa_raft_rpc.hrl").

%% Supervisor callbacks
-export([
    child_spec/1,
    start_link/1
]).

%% gen_event callbacks
-export([
    init/1,
    handle_event/2,
    handle_call/2,
    handle_info/2,
    terminate/2
]).

%% API
-export([
    catchup/5,
    is_catching_up/2
]).

%% Catchup State
-record(raft_catchup, {
    name :: atom(),
    table :: wa_raft:table(),
    partition :: wa_raft:partition(),
    log :: wa_raft_log:log(),
    id :: node() | undefined
}).

-spec child_spec(RaftArgs :: [term()]) -> supervisor:child_spec().
child_spec(RaftArgs) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [RaftArgs]},
        restart => transient,
        shutdown => 30000,
        modules => [?MODULE]
    }.

-spec start_link(wa_raft:args()) -> {ok, Pid :: pid()}.
start_link(#{table := Table, partition := Partition} = Args) ->
    Name = ?RAFT_CATCHUP(Table, Partition),
    {ok, Pid} = gen_event:start_link({local, Name}),
    ok = gen_event:add_handler(Name, ?MODULE, [Args]),
    {ok, Pid}.

%% Start catchup for follower at index specified by FollowerLastIndex. Skip this request
%% if a catchup has been scheduled.
-spec catchup(atom(), node(), wa_raft_log:log_index(), wa_raft_log:log_term(), wa_raft_log:log_index()) -> ok.
catchup(Name, FollowerId, FollowerLastIndex, LeaderTerm, LeaderCommitIndex) ->
    case is_catching_up(Name, FollowerId) of
        true ->
            ok; % skip if a catchup for the follower has already started
        false ->
            set_state(Name, FollowerId, queued),
            gen_event:notify(Name, {catchup, FollowerId, FollowerLastIndex, LeaderTerm, LeaderCommitIndex})
    end.

%% State of catchup: queued, sending, done
-spec is_catching_up(atom(), node()) -> boolean().
is_catching_up(Name, FollowerId) ->
    case ets:lookup(Name, {FollowerId, state}) of
        [{_, Status}] when Status =:= queued orelse Status =:= sending ->
            true;
        _ ->
            false
    end.

%% gen_event callbacks
-spec init([wa_raft:args()]) -> {ok, #raft_catchup{}}.
init([#{table := Table, partition := Partition}]) ->
    process_flag(trap_exit, true),
    Name = ?RAFT_CATCHUP(Table, Partition),
    ?LOG_NOTICE("Start catchup process for ~p", [Name], #{domain => [whatsapp, wa_raft]}),
    ets:new(Name, [set, named_table, public]),
    {ok, #raft_catchup{
            name = Name,
            table = Table,
            partition = Partition,
            log = ?RAFT_LOG_NAME(Table, Partition),
            id = node()
        }
    }.

-spec handle_event(term(), #raft_catchup{}) -> {ok, #raft_catchup{}}.
handle_event({catchup, FollowerId, FollowerLastIndex, LeaderTerm, LeaderCommitIndex}, #raft_catchup{name = Name, log = Log} = State) ->
    ?LOG_NOTICE("Leader[~p] catchup follower[~p] with last log index ~p. current leader term ~p",
         [Name, FollowerId, FollowerLastIndex, LeaderTerm], #{domain => [whatsapp, wa_raft]}),
    try
        case has_log(Log, FollowerLastIndex) of
            true ->
                % catchup by incremental logs
                counter_wait_and_add(?RAFT_GLOBAL_COUNTER_LOG_CATCHUP, raft_max_log_catchup),
                try
                    send_logs(FollowerId, FollowerLastIndex, LeaderTerm, LeaderCommitIndex, State)
                after
                    sub(?RAFT_GLOBAL_COUNTER_LOG_CATCHUP)
                end;
            false ->
                % catchup by a full snapshot
                counter_wait_and_add(?RAFT_GLOBAL_COUNTER_SNAPSHOT_CATCHUP, raft_max_snapshot_catchup),
                try
                    {ok, #raft_log_pos{index = LastAppliedIndex}} = send_snapshot(FollowerId, State),
                    send_logs(FollowerId, LastAppliedIndex, LeaderTerm, LeaderCommitIndex, State)
                after
                    sub(?RAFT_GLOBAL_COUNTER_SNAPSHOT_CATCHUP)
                end
        end
    catch
        Type:Error:Stack ->
            % Flatten a potentially huge error into a string representation with an intentonally
            % very small recursion limit to avoid logging op data and reduce overall log event size.
            ErrorStr = lists:flatten(io_lib:format("~0P", [Error, 10])),
            ?RAFT_COUNT('raft.catchup.error'),
            ?LOG_ERROR("Leader[~p] logs catchup to ~p (starting at ~p) failed with ~p: ~s~n~0p",
                [Name, FollowerId, FollowerLastIndex, Type, ErrorStr, Stack], #{domain => [whatsapp, wa_raft]})
    end,
    set_state(Name, FollowerId, done),
    {ok, State}.

-spec handle_call(term(), #raft_catchup{}) -> {ok, term(), #raft_catchup{}}.
handle_call(Request, #raft_catchup{name = Name} = State) ->
    ?LOG_WARNING("Unexpected call ~0P on ~p", [Request, 30, Name], #{domain => [whatsapp, wa_raft]}),
    {ok, {error, unsupported}, State}.

-spec handle_info(term(), #raft_catchup{}) -> {ok, #raft_catchup{}}.
handle_info(Info, #raft_catchup{name = Name} = State) ->
    ?LOG_WARNING("Unexpected call ~0P on ~p", [Info, 30, Name], #{domain => [whatsapp, wa_raft]}),
    {ok, State}.

-spec terminate(term(), #raft_catchup{}) -> ok.
terminate(Reason, #raft_catchup{name = Name}) ->
    ?LOG_NOTICE("Terminate ~p. reason ~p", [Name, Reason], #{domain => [whatsapp, wa_raft]}),
    ok.

%% =======================================================================
%% Private functions - Send logs to follower
%%
-spec has_log(wa_raft_log:log(), wa_raft_log:log_index()) -> boolean().
has_log(Log, FollowerLastIndex) ->
    FollowerLastIndex > 0 andalso wa_raft_log:get(Log, FollowerLastIndex) =/= not_found.

-spec send_logs(node(), wa_raft_log:log_index(), wa_raft_log:log_term(), wa_raft_log:log_index(), #raft_catchup{}) -> no_return().
send_logs(FollowerId,
          FollowerEndIndex,
          LeaderTerm,
          LeaderCommitIndex,
          #raft_catchup{name = Name} = State) ->
    set_state(Name, FollowerId, sending),
    set_progress(Name, FollowerId, total, (LeaderCommitIndex - FollowerEndIndex)),
    set_progress(Name, FollowerId, completed, 0),
    ?LOG_NOTICE("[~p term ~p] start sending logs to follower ~p from ~p to ~p",
        [Name, LeaderTerm, FollowerId, FollowerEndIndex, LeaderCommitIndex], #{domain => [whatsapp, wa_raft]}),

    StartT = os:timestamp(),
    ok = send_logs_loop(FollowerId, FollowerEndIndex + 1, LeaderTerm, LeaderCommitIndex, State),
    ?LOG_NOTICE("[~p term ~p] finish sending logs to follower ~p", [Name, LeaderTerm, FollowerId], #{domain => [whatsapp, wa_raft]}),
    ?RAFT_GATHER('raft.leader.catchup.duration', timer:now_diff(os:timestamp(), StartT)).

send_logs_loop(_FollowerId, NextIndex, _LeaderTerm, LeaderCommitIndex, _State) when NextIndex >= LeaderCommitIndex ->
    ok;
send_logs_loop(FollowerId, PrevLogIndex, LeaderTerm, LeaderCommitIndex,
               #raft_catchup{name = Name, table = Table, partition = Partition, log = Log, id = Id} = State) ->
    % Load a chunk of log entries starting at PrevLogIndex + 1.
    LogBatchEntries = ?RAFT_CONFIG(raft_catchup_log_batch_entries, 800),
    LogBatchBytes = ?RAFT_CONFIG(raft_catchup_log_batch_bytes, 4 * 1024 * 1024),
    Limit = min(LogBatchEntries, LeaderCommitIndex - PrevLogIndex),
    {ok, PrevLogTerm} = wa_raft_log:term(Log, PrevLogIndex),
    {ok, Entries} = wa_raft_log:get(Log, PrevLogIndex + 1, Limit, LogBatchBytes),
    NumEntries = length(Entries),

    % Replicate the log entries to our peer.
    Dest = {?RAFT_SERVER_NAME(Table, Partition), FollowerId},
    Command = case ?RAFT_CONFIG(send_trim_index, false) of
        true  -> ?APPEND_ENTRIES_RPC(LeaderTerm, Id, PrevLogIndex, PrevLogTerm, Entries, LeaderCommitIndex, 0);
        false -> ?APPEND_ENTRIES_RPC_OLD(LeaderTerm, Id, PrevLogIndex, PrevLogTerm, Entries, LeaderCommitIndex)
    end,
    Timeout = ?RAFT_CONFIG(raft_catchup_rpc_timeout_ms, 5000),
    ?APPEND_ENTRIES_RESPONSE_RPC(LeaderTerm, FollowerId, PrevLogIndex, true, FollowerEndIndex) = gen_server:call(Dest, Command, Timeout),
    update_progress(Name, FollowerId, completed, NumEntries),

    % Continue onto the next iteration, starting from the new end index
    % reported by the follower.
    send_logs_loop(FollowerId, FollowerEndIndex, LeaderTerm, LeaderCommitIndex, State).

%% =======================================================================
%% Private functions - Send snapshot to follower
%%

-spec send_snapshot(node(), #raft_catchup{}) -> any().
send_snapshot(FollowerId, #raft_catchup{name = Name, table = Table, partition = Partition} = State) ->
    LastCompletionTs = update_progress(Name, FollowerId, completion_ts, 0),
    erlang:system_time(second) - LastCompletionTs < ?RAFT_CONFIG(raft_catchup_min_interval_s, 20) andalso throw(interval_too_short),

    set_state(Name, FollowerId, sending),
    StartT = os:timestamp(),
    try
        StoragePid = whereis(?RAFT_STORAGE_NAME(Table, Partition)),
        case wa_raft_storage:create_snapshot(StoragePid) of
            {ok, #raft_log_pos{index = Index, term = Term} = LogPos} ->
                SnapName = ?SNAPSHOT_NAME(Index, Term),
                try
                    send_snapshot_transport(FollowerId, State, LogPos)
                after
                    wa_raft_storage:delete_snapshot(StoragePid, SnapName)
                end;
            {error, Reason} = Error ->
                ?LOG_ERROR("Catchup[~p] create snapshot error ~p", [Name, Reason], #{domain => [whatsapp, wa_raft]}),
                throw(Error)
        end
    after
        ?RAFT_GATHER('raft.snapshot.catchup.duration', timer:now_diff(os:timestamp(), StartT)),
        set_progress(Name, FollowerId, completion_ts, erlang:system_time(second))
    end.

send_snapshot_transport(FollowerId,
                        #raft_catchup{name = Name, table = Table, partition = Partition},
                        #raft_log_pos{index = Index, term = Term} = LogPos) ->
    ?LOG_NOTICE("wa_raft_catchup[~p] starting transport to send snapshot for ~p:~p at ~p:~p",
        [Name, Table, Partition, Index, Term], #{domain => [whatsapp, wa_raft]}),
    Path = filename:join(?ROOT_DIR(Table, Partition), ?SNAPSHOT_NAME(Index, Term)),
    Timeout = ?RAFT_CONFIG(catchup_transport_timeout_secs, 20 * 60) * 1000,
    case wa_raft_transport:transport_snapshot(FollowerId, Table, Partition, LogPos, Path, Timeout) of
        {ok, ID} ->
            ?LOG_NOTICE("wa_raft_catchup[~p] transport ~p for ~p:~p completed",
                [Name, ID, Table, Partition], #{domain => [whatsapp, wa_raft]}),
            {ok, LogPos};
        {error, Reason} ->
            ?LOG_WARNING("wa_raft_catchup[~p] failed to start transport to send snapshot for ~p:~p at ~p:~p due to ~p",
                [Name, Table, Partition, Index, Term, Reason], #{domain => [whatsapp, wa_raft]}),
            error({transport_failed, Reason})
    end.

-spec set_state(atom(), node(), atom()) -> ok.
set_state(Tab, FollowerId, Value) ->
    ets:insert(Tab, {{FollowerId, state}, Value}),
    ok.

-spec set_progress(atom(), node(), atom(), integer()) -> ok.
set_progress(Tab, FollowerId, Name, Value) ->
    ets:insert(Tab, {{FollowerId, Name}, Value}),
    ok.

-spec update_progress(atom(), node(), atom(), integer()) -> integer().
update_progress(Tab, FollowerId, Name, Incr) ->
    ets:update_counter(Tab, {FollowerId, Name}, Incr, {{FollowerId, Name}, 0}).

-define(SLEEP_INTERVAL_MS, 150).
%% Add 1 to the counter. If the counter reaches max value, wait until it's below.
%% Best effort counting semaphore.
-spec counter_wait_and_add(pos_integer(), atom()) -> ok.
counter_wait_and_add(Counter, MaxConfig) ->
    Value = counters:get(persistent_term:get(?RAFT_COUNTERS), Counter),
    case Value < ?RAFT_CONFIG(MaxConfig, 5) of
        true ->
            counters:add(persistent_term:get(?RAFT_COUNTERS), Counter, 1);
        false ->
            timer:sleep(?RAFT_CONFIG(raft_catchup_sleep_interval_ms, ?SLEEP_INTERVAL_MS)),
            ?RAFT_COUNT('raft.catchup.sleep'),
            counter_wait_and_add(Counter, MaxConfig)
    end.

%% Sub 1 from the counter
-spec sub(pos_integer()) -> ok.
sub(Counter) ->
    counters:sub(persistent_term:get(?RAFT_COUNTERS), Counter, 1).
