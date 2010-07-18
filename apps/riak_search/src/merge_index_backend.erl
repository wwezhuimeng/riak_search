%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(merge_index_backend).
-behavior(riak_search_backend).

-export([
    start/2,
    stop/1,
    index_if_newer/7,
    multi_index/2,
    delete_entry/5,
    stream/6,
    multi_stream/4,
    info/5,
    info_range/7,
    catalog_query/3,
    fold/3,
    is_empty/1,
    drop/1
]).

-include_lib("riak_search/include/riak_search.hrl").

% @type state() = term().
-record(state, {partition, pid}).

%% @spec start(Partition :: integer(), Config :: proplist()) ->
%%          {ok, state()} | {{error, Reason :: term()}, state()}
%% @doc Start this backend.
start(Partition, Config) ->
    DefaultRootPath = filename:join([".", "data", "merge_index"]),
    RootPath = proplists:get_value(merge_index_backend_root, Config, DefaultRootPath),
    Rootfile = filename:join([RootPath, integer_to_list(Partition)]),
    {ok, Pid} = merge_index:start_link(Rootfile, Config),
    {ok, #state { partition=Partition, pid=Pid }}.

%% @spec stop(state()) -> ok | {error, Reason :: term()}
stop(State) ->
    Pid = State#state.pid,
    ok = merge_index:stop(Pid).

index_if_newer(Index, Field, Term, DocId, Props, KeyClock, State) ->
    %% Put with properties.
    Pid = State#state.pid,
    merge_index:index(Pid, Index, Field, Term, DocId, Props, KeyClock),
    noreply.

multi_index(IFTVPKList, State) ->
    F = fun(IFTVPK) ->
        {Index, Field, Term, DocId, Props, KeyClock} = IFTVPK,
        index_if_newer(Index, Field, Term, DocId, Props, KeyClock, State)
    end,
    [F(X) || X <- IFTVPKList],
    {reply, {indexed, node()}, State}.

delete_entry(Index, Field, Term, DocId, State) ->
    KeyClock = riak_search_utils:current_key_clock(),
    index_if_newer(Index, Field, Term, DocId, undefined, KeyClock, State),
    noreply.

info(Index, Field, Term, Sender, State) ->
    Pid = State#state.pid,
    {ok, Info} = merge_index:info(Pid, Index, Field, Term),
    Info1 = [{Term, node(), Count} || {_, Count} <- Info],
    riak_search_backend:info_response(Sender, Info1),
    noreply.

info_range(Index, Field, StartTerm, EndTerm, Size, Sender, State) ->
    Pid = State#state.pid,
    {ok, Info} = merge_index:info_range(Pid, Index, Field, StartTerm, EndTerm, Size),
    Info1 = [{Term, node(), Count} || {Term, Count} <- Info],
    riak_search_backend:info_response(Sender, Info1),
    noreply.

stream(Index, Field, Term, FilterFun, Sender, State) ->
    %% Hack... we index incoming terms as binaries, but search as lists.
    TermB = riak_search_utils:to_binary(Term),
    Pid = State#state.pid,
    OutputRef = make_ref(),
    OutputPid = spawn_link(fun() -> stream_loop(OutputRef, Sender) end),
    merge_index:stream(Pid, Index, Field, TermB, OutputPid, OutputRef, FilterFun),
    noreply.

stream_loop(Ref, Sender) ->
    receive
        {result, {Value, Props}, Ref} ->
            riak_search_backend:stream_response_results(Sender, [{Value, Props}]),
            stream_loop(Ref, Sender);
        {result, '$end_of_table', Ref} ->
            riak_search_backend:stream_response_done(Sender);
        Other ->
            ?PRINT({unexpected_result, Other}),
            stream_loop(Ref, Sender)
    end.

multi_stream(_IFTList, _FilterFun, _Sender, _State) ->
    throw({merge_index_backend, not_yet_implemented}).


%% Code taken from riak_search_ets_backend.
%% TODO: hack up this function or change the implementation of
%%       riak_search:do_catalog_query/3, such that catalog_queries
%%       are performed on all vnodes, not just one per node
catalog_query(_CatalogQuery, _Sender, _State) ->
    throw({merge_index_backend, not_yet_implemented}).


is_empty(State) ->
    Pid = State#state.pid,
    merge_index:is_empty(Pid).

fold(FoldFun, Acc, State) ->
    %% Copied almost verbatim from riak_search_ets_backend.
    Fun = fun
        (I,F,T,V,P,K, {OuterAcc, {{I,{F,T}},InnerAcc}}) ->
            %% same IFT, just accumulate doc/props/clock
            {OuterAcc, {{I,{F,T}},[{V,P,K}|InnerAcc]}};
        (I,F,T,V,P,K, {OuterAcc, {FoldKey, VPKList}}) ->
            %% finished a string of IFT, send it off
            %% (sorted order is assumed)
            NewOuterAcc = FoldFun(FoldKey, VPKList, OuterAcc),
            {NewOuterAcc, {{I,{F,T}},[{V,P,K}]}};
        (I,F,T,V,P,K, {OuterAcc, undefined}) ->
            %% first round through the fold - just start building
            {OuterAcc, {{I,{F,T}},[{V,P,K}]}}
        end,
    Pid = State#state.pid,
    {OuterAcc0, Final} = merge_index:fold(Pid, Fun, {Acc, undefined}),
    OuterAcc = case Final of
        {FoldKey, VPKList} ->
            %% one last IFT to send off
            FoldFun(FoldKey, VPKList, OuterAcc0);
        undefined ->
            %% this partition was empty
            OuterAcc0
    end,
    {reply, OuterAcc, State}.

drop(State) ->
    Pid = State#state.pid,
    merge_index:drop(Pid).
