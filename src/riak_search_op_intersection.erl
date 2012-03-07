%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_search_op_intersection).
-export([
         extract_scoring_props/1,
         preplan/2,
         chain_op/4,
         make_filter_iterator/1
        ]).
-include("riak_search.hrl").
-include_lib("lucene_parser/include/lucene_parser.hrl").
-define(INDEX_DOCID(Term), ({element(1, Term), element(2, Term)})).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

extract_scoring_props(Op) ->
    riak_search_op:extract_scoring_props(Op#intersection.ops).

preplan(Op, State) ->
    case riak_search_op:preplan(Op#intersection.ops, State) of
        [ChildOp] ->
            ChildOp;
        ChildOps ->
            NewOp = Op#intersection { ops=ChildOps },
            NodeOp = #node { ops=NewOp },
            riak_search_op:preplan(NodeOp, State)
    end.

chain_op(Op, OutputPid, OutputRef, State) ->
    %% 1. order the operations by ascending frequency
    Ops = order_ops(fun order_by_freq/2, Op#intersection.ops),

    %% 2. realize the candidate set
    [Op1|Ops2] = Ops,
    CandidateSet = get_candidate_set(Op1, State),

    %% 3. sequentially check candidate set against rest of term
    %% indexes
    FinalSet = lists:foldl(intersection(State), CandidateSet, Ops2),

    %% 4. output results
    send_results(FinalSet, {OutputPid, OutputRef, State#search_state.index}),

    {ok, 1}.


%% Given an iterator, return a new iterator that filters out any
%% negated results.
make_filter_iterator(Iterator) ->
    fun() -> filter_iterator(Iterator()) end.

%%%===================================================================
%%% Private
%%%===================================================================

%% @private
%%
%% @doc Return a `Fun' used to perform the intersection of `Op'
%% results against `CandidateSet'.
%%
%% NOTE: An assumption is made that intersection ops do no nest
%% (rewritten by preplan).
-spec intersection(term()) -> function().
intersection(State) ->
    fun(Op, CandidateSet) ->
            Itr = riak_search_op_utils:iterator_tree(none, [Op],
                                                     CandidateSet, State),
            ResultSet = id_set(Itr),
            case riak_search_op_negation:is_negation(Op) of
                true ->
                    subtract(CandidateSet, gb_trees:iterator(ResultSet));
                false ->
                    ResultSet
            end
    end.

subtract(CandidateSet, Itr) ->
    case gb_trees:next(Itr) of
        {DocId, _Props, Itr2} ->
            subtract(gb_trees:delete_any(DocId, CandidateSet), Itr2);
        none ->
            CandidateSet
    end.

filter_iterator({_, Op, Iterator})
  when (is_tuple(Op) andalso is_record(Op, negation)) orelse Op == true ->
    %% Term is negated, so skip it.
    filter_iterator(Iterator());
filter_iterator({Term, _, Iterator}) ->
    %% Term is not negated, so keep it.
    {Term, ignore, fun() -> filter_iterator(Iterator()) end};
filter_iterator({eof, _}) ->
    %% No more results.
    {eof, ignore}.

%% @private
%%
%% @doc Realize the results for `Op'.
%%
%% TODO: The usual iterator fuss can be bypassed since these results
%% are to be realized immediately.  Instead call chain_op and directly
%% collect.
%%
-spec get_candidate_set(term(), term()) -> gb_tree().
get_candidate_set(Op, State) ->
    Itr = riak_search_op_utils:iterator_tree(none, [Op], State),
    id_set(Itr).

id_set(Itr) ->
    id_set(Itr(), gb_trees:empty()).

id_set({{_Idx, DocId, Props}, _, Itr}, Set) ->
    id_set(Itr(), gb_trees:insert(DocId, Props, Set));
id_set({eof, _}, Set) ->
    Set.

%% @private
%%
%% @doc Order operations by frequency.
-spec order_by_freq({non_neg_integer(), term()}, {non_neg_integer(), term()}) ->
                           boolean().
order_by_freq({_FreqA, _}, {unknown, _}) ->
    true;
order_by_freq({unknown, _}, {_FreqB, _}) ->
    false;
order_by_freq({FreqA, _}, {FreqB, _}) ->
    FreqA =< FreqB.

%% @private
%%
%% @doc Order the operations in ascending order based on frequency of
%% matched objects.
-spec order_ops(function(), [{non_neg_integer(), term()}]) -> [term()].
order_ops(Fun, Ops) ->
    Asc = lists:sort(Fun, lists:map(fun riak_search_op:frequency/1, Ops)),
    swap_front([Op || {_, Op} <- Asc]).

%% @private
%%
%% @doc Make sure that `Ops' does not start with negation op.
-spec swap_front([term()]) -> [term()].
swap_front(Ops) ->
    {Negations, [H|T]} =
        lists:splitwith(fun riak_search_op_negation:is_negation/1, Ops),
    [H] ++ Negations ++ T.

%% Now, treat the operation as a comparison between two terms. Return
%% a term if it successfully meets our conditions, or else toss it and
%% iterate to the next term.

%% Normalize Op1 and Op2 into boolean NotFlags...
%% select_fun({Term1, Op1, Iterator1}, I2) when is_tuple(Op1) ->
%%     select_fun({Term1, is_record(Op1, negation), Iterator1}, I2);

%% select_fun({eof, Op1}, I2) when is_tuple(Op1) ->
%%     select_fun({eof, is_record(Op1, negation)}, I2);

%% select_fun(I1, {Term2, Op2, Iterator2}) when is_tuple(Op2) ->
%%     select_fun(I1, {Term2, is_record(Op2, negation), Iterator2});

%% select_fun(I1, {eof, Op2}) when is_tuple(Op2) ->
%%     select_fun(I1, {eof, is_record(Op2, negation)});



%% %% Handle 'AND' cases, notflags = [false, false]
%% select_fun({Term1, false, Iterator1}, {Term2, false, Iterator2}) when ?INDEX_DOCID(Term1) == ?INDEX_DOCID(Term2) ->
%%     NewTerm = riak_search_utils:combine_terms(Term1, Term2),
%%     {NewTerm, false, fun() -> select_fun(Iterator1(), Iterator2()) end};

%% select_fun({Term1, false, Iterator1}, {Term2, false, Iterator2}) when ?INDEX_DOCID(Term1) < ?INDEX_DOCID(Term2) ->
%%     select_fun(Iterator1(), {Term2, false, Iterator2});

%% select_fun({Term1, false, Iterator1}, {Term2, false, Iterator2}) when ?INDEX_DOCID(Term1) > ?INDEX_DOCID(Term2) ->
%%     select_fun({Term1, false, Iterator1}, Iterator2());

%% select_fun({eof, false}, {_Term2, false, Iterator2}) ->
%%     exhaust_it(Iterator2()),
%%     {eof, false};

%% select_fun({_Term1, false, Iterator1}, {eof, false}) ->
%%     exhaust_it(Iterator1()),
%%     {eof, false};

%% %% Handle 'AND' cases, notflags = [false, true]
%% select_fun({Term1, false, Iterator1}, {Term2, true, Iterator2}) when ?INDEX_DOCID(Term1) == ?INDEX_DOCID(Term2) ->
%%     select_fun(Iterator1(), {Term2, true, Iterator2});

%% select_fun({Term1, false, Iterator1}, {Term2, true, Iterator2}) when ?INDEX_DOCID(Term1) < ?INDEX_DOCID(Term2) ->
%%     {Term1, false, fun() -> select_fun(Iterator1(), {Term2, true, Iterator2}) end};

%% select_fun({Term1, false, Iterator1}, {Term2, true, Iterator2}) when ?INDEX_DOCID(Term1) > ?INDEX_DOCID(Term2) ->
%%     select_fun({Term1, false, Iterator1}, Iterator2());

%% select_fun({eof, false}, {_Term2, true, Iterator2}) ->
%%     exhaust_it(Iterator2()),
%%     {eof, false};

%% select_fun({Term1, false, Iterator1}, {eof, true}) ->
%%     {Term1, false, fun() -> select_fun(Iterator1(), {eof, true}) end};


%% %% Handle 'AND' cases, notflags = [true, false], use previous clauses...
%% select_fun({Term1, true, Iterator1}, {Term2, false, Iterator2}) ->
%%     select_fun({Term2, false, Iterator2}, {Term1, true, Iterator1});

%% select_fun({eof, true}, {Term2, false, Iterator2}) ->
%%     select_fun({Term2, false, Iterator2}, {eof, true});

%% select_fun({Term1, true, Iterator1}, {eof, false}) ->
%%     select_fun({eof, false}, {Term1, true, Iterator1});


%% %% Handle 'AND' cases, notflags = [true, true]
%% select_fun({Term1, true, Iterator1}, {Term2, true, Iterator2}) when ?INDEX_DOCID(Term1) == ?INDEX_DOCID(Term2) ->
%%     NewTerm = riak_search_utils:combine_terms(Term1, Term2),
%%     {NewTerm, true, fun() -> select_fun(Iterator1(), Iterator2()) end};

%% select_fun({Term1, true, Iterator1}, {Term2, true, Iterator2}) when ?INDEX_DOCID(Term1) < ?INDEX_DOCID(Term2) ->
%%     {Term1, true, fun() -> select_fun(Iterator1(), {Term2, true, Iterator2}) end};

%% select_fun({Term1, true, Iterator1}, {Term2, true, Iterator2}) when ?INDEX_DOCID(Term1) > ?INDEX_DOCID(Term2) ->
%%     {Term2, true, fun() -> select_fun({Term1, true, Iterator1}, Iterator2()) end};

%% select_fun({eof, true}, {Term2, true, Iterator2}) ->
%%     {Term2, true, fun() -> select_fun({eof, true}, Iterator2()) end};

%% select_fun({Term1, true, Iterator1}, {eof, true}) ->
%%     {Term1, true, fun() -> select_fun(Iterator1(), {eof, true}) end};

%% %% HANDLE 'AND' case, end of results.
%% select_fun({eof, true}, {eof, true}) ->
%%     {eof, true};

%% select_fun({eof, _}, {eof, _}) ->
%%     {eof, false};

%% %% Error on any unhandled cases...
%% select_fun(Iterator1, Iterator2) ->
%%     ?PRINT({select_fun, unhandled_case, 'intersection', Iterator1, Iterator2}),
%%     throw({select_fun, unhandled_case, 'intersection', Iterator1, Iterator2}).


%% %% @private
%% %%
%% %% @doc Exhaust the iterator of all results.
%% exhaust_it({eof, _}) ->
%%     ok;
%% exhaust_it({_,_,It}) ->
%%     exhaust_it(It()).

send_results(FinalSet, O) ->
    send_results(gb_trees:iterator(FinalSet), O, []).

%% TODO: MICROOPT: Explicitly keep track of count to avoid calling
%% `length' each time.
send_results(Itr, {OutputPid, OutputRef, _Idx}=O, Acc)
  when length(Acc) > ?RESULTVEC_SIZE ->
    OutputPid ! {results, lists:reverse(Acc), OutputRef},
    send_results(Itr, O, []);
send_results(Itr, {OutputPid, OutputRef, Idx}=O, Acc) ->
    case gb_trees:next(Itr) of
        {DocId, Props, Itr2} ->
            %% need to add the Idx back for upstream
            send_results(Itr2, O, [{Idx, DocId, Props}|Acc]);
        none ->
            OutputPid ! {results, lists:reverse(Acc), OutputRef},
            OutputPid ! {disconnect, OutputRef}
    end.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

order_by_freq_test() ->
    Unordered = [{10,op1}, {unknown,op2}, {2,op3}, {unknown,op4},
                 {unknown,op5}, {7,op6}],
    Expect = [op3, op6, op1, op2, op4, op5],
    Asc = [Op || {_, Op} <- lists:sort(fun order_by_freq/2, Unordered)],
    ?assertEqual(Expect, Asc).

-endif.
