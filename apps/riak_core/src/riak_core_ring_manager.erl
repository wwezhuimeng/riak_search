%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at

%%   http://www.apache.org/licenses/LICENSE-2.0

%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.

%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.

%% @doc this owns the local view of the cluster's ring configuration

-module(riak_core_ring_manager).
-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server2).

-export([start_link/0,
         start_link/1,
         get_my_ring/0,
         set_my_ring/1,
         write_ringfile/0,
         prune_ringfiles/0,
         read_ringfile/1,
         find_latest_ringfile/0,
         do_write_ringfile/1,
         stop/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%% ===================================================================
%% Public API
%% ===================================================================

start_link() ->
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [live], []).


%% Testing entry point
start_link(test) ->
    gen_server2:start_link({local, ?MODULE}, ?MODULE, [test], []).


%% @spec get_my_ring() -> {ok, riak_core_ring:riak_core_ring()} | {error, Reason}
get_my_ring() ->
    case ets:match(nodelocal_ring, {ring, '$1'}) of
        [[Ring]] -> {ok, Ring};
        [] -> {error, no_ring}
    end.


%% @spec set_my_ring(riak_core_ring:riak_core_ring()) -> ok
set_my_ring(Ring) ->
    gen_server2:call(?MODULE, {set_my_ring, Ring}).


%% @spec write_ringfile() -> ok
write_ringfile() ->
    gen_server2:cast(?MODULE, write_ringfile).


do_write_ringfile(Ring) ->
    {{Year, Month, Day},{Hour, Minute, Second}} = calendar:universal_time(),
    TS = io_lib:format(".~B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B",
                       [Year, Month, Day, Hour, Minute, Second]),
    case app_helper:get_env(riak_core, ring_state_dir) of
        "<nostore>" -> nop;
        Dir ->
            Cluster = app_helper:get_env(riak_core, cluster_name),
            FN = Dir ++ "/riak_core_ring." ++ Cluster ++ TS,
            ok = filelib:ensure_dir(FN),
            file:write_file(FN, term_to_binary(Ring))
    end.

%% @spec find_latest_ringfile() -> string()
find_latest_ringfile() ->
    Dir = app_helper:get_env(riak_core, ring_state_dir),
    case file:list_dir(Dir) of
        {ok, Filenames} ->
            Cluster = app_helper:get_env(riak_core, cluster_name),
            Timestamps = [list_to_integer(TS) || {"riak_core_ring", C1, TS} <-
                                                     [list_to_tuple(string:tokens(FN, ".")) || FN <- Filenames],
                                                 C1 =:= Cluster],
            SortedTimestamps = lists:reverse(lists:sort(Timestamps)),
            case SortedTimestamps of
                [Latest | _] ->
                    {ok, Dir ++ "/riak_core_ring." ++ Cluster ++ "." ++ integer_to_list(Latest)};
                _ ->
                    {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% @spec read_ringfile(string()) -> riak_core_ring:riak_core_ring()
read_ringfile(RingFile) ->
    {ok, Binary} = file:read_file(RingFile),
    binary_to_term(Binary).

%% @spec prune_ringfiles() -> ok
prune_ringfiles() ->
    case app_helper:get_env(riak_core, ring_state_dir) of
        "<nostore>" -> ok;
        Dir ->
            Cluster = app_helper:get_env(riak_core, cluster_name),
            case file:list_dir(Dir) of
                {error,enoent} -> ok;
                {ok, []} -> ok;
                {ok, Filenames} ->
                    Timestamps = [TS || {"riak_core_ring", C1, TS} <- 
                     [list_to_tuple(string:tokens(FN, ".")) || FN <- Filenames],
                                        C1 =:= Cluster],
                    if Timestamps /= [] ->
                            %% there are existing ring files
                            TSPat = [io_lib:fread("~4d~2d~2d~2d~2d~2d",TS) ||
                                        TS <- Timestamps],
                            TSL = lists:reverse(lists:sort([TS ||
                                                               {ok,TS,[]} <- TSPat])),
                            Keep = prune_list(TSL),
                            KeepTSs = [lists:flatten(
                                         io_lib:format(
                                           "~B~2.10.0B~2.10.0B~2.10.0B~2.10.0B~2.10.0B",K))
                                       || K <- Keep],
                            DelFNs = [Dir ++ "/" ++ FN || FN <- Filenames, 
                                                          lists:all(fun(TS) -> 
                                                                            string:str(FN,TS)=:=0
                                                                    end, KeepTSs)],
                            [file:delete(DelFN) || DelFN <- DelFNs],
                            ok;
                       true ->
                            %% directory wasn't empty, but there are no ring
                            %% files in it
                            ok
                    end
            end
    end.


%% @private (only used for test instances)
stop() ->
    gen_server2:cast(?MODULE, stop).


%% ===================================================================
%% gen_server callbacks
%% ===================================================================

init([Mode]) ->
    case Mode of
        live ->
            Ring = riak_core_ring:fresh();
        test ->
            Ring = riak_core_ring:fresh(16,node())
    end,
    ets:new(nodelocal_ring, [protected, named_table]),
    ets:insert(nodelocal_ring, {ring, Ring}),

    % Initial notification to local observers that ring has changed
    riak_core_ring_events:ring_update(Ring),
    {ok, Mode}.


handle_call({set_my_ring, Ring}, _From, State) ->
    % Update ETS with the new ring
    ets:insert(nodelocal_ring, {ring, Ring}),

    % Notify any local observers that the ring has changed (async)
    riak_core_ring_events:ring_update(Ring),
    {reply,ok,State}.


handle_cast(stop, State) ->
    {stop,normal,State};

handle_cast(write_ringfile, test) ->
    {noreply,test};

handle_cast(write_ringfile, State) ->
    {ok, Ring} = get_my_ring(),
    do_write_ringfile(Ring),
    {noreply,State}.


handle_info(_Info, State) ->
    {noreply, State}.


%% @private
terminate(_Reason, _State) ->
    ok.


%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ===================================================================
%% Internal functions
%% ===================================================================

prune_list([X|Rest]) ->
    lists:usort(lists:append([[X],back(1,X,Rest),back(2,X,Rest),
                  back(3,X,Rest),back(4,X,Rest),back(5,X,Rest)])).
back(_N,_X,[]) -> [];
back(N,X,[H|T]) ->
    case lists:nth(N,X) =:= lists:nth(N,H) of
        true -> back(N,X,T);
        false -> [H]
    end.
