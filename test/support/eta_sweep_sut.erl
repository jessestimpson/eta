-module(eta_sweep_sut).
-behaviour(eta_harness).

%% A harness for `eta_run:sweep/3' and for the shrinking of the content of an
%% operation.
%%
%% An operation is `{put, Key, Size}', with a key from 1 to 5 and a size from 1
%% to 40. A client writes the size under the key in `eta_sweep_store'. The
%% invariant `small_values' is violated when a stored size is at or above the
%% `limit' of the configuration. With the limit `infinity' no run violates the
%% invariant.
%%
%% The least trace that violates the invariant has one operation,
%% `{put, 1, Limit}'. Only a shrink of the content of an operation reaches
%% that operation, because the generator rarely produces it.
%%
%% The configuration `pair => true' changes the invariant. A size at or above
%% the limit is a violation under the key 1. Under the other keys, 2 such sizes
%% are a violation and 1 is not. A trace with 2 operations on the keys 2 and 3
%% is then minimal for the removal of entries. The replacement of the first
%% operation by an operation on the key 1 makes the second operation
%% unnecessary, so the shrinker must remove entries again.
%%
%% The configuration `cycle => true' makes `shrink_op/1' return the operation
%% that it received. That is a defective callback. It shows that the
%% `max_tests' budget ends the search.

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1, shrink_op/1]).

init(_Seed, Config) ->
    Tab = ets:new(?MODULE, [public]),
    {ok, Pid} = eta_sweep_store:start_link(Tab),
    persistent_term:put({?MODULE, cycle}, maps:get(cycle, Config, false)),
    {ok, #{
        tab => Tab,
        store => Pid,
        limit => maps:get(limit, Config, infinity),
        pair => maps:get(pair, Config, false),
        procs => [Pid]
    }}.

processes(#{procs := Procs}) ->
    Procs.

generate(_Sut, Rand0) ->
    {Key, Rand1} = rand:uniform_s(5, Rand0),
    {Size, Rand2} = rand:uniform_s(40, Rand1),
    {{put, Key, Size}, Rand2}.

execute({put, Key, Size}, Sut = #{store := Store, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() -> eta_sweep_store:put(Store, Key, Size) end),
    Sut#{procs := Procs ++ [Pid]}.

check(#{tab := Tab, limit := Limit, pair := Pair}) ->
    case [Row || {_Key, Size} = Row <- lists:sort(ets:tab2list(Tab)), Size >= Limit] of
        [] -> ok;
        [{Key, _}] when Pair, Key > 1 -> ok;
        Large -> {violation, #{property => small_values, large => Large}}
    end.

terminate(#{tab := Tab, store := Pid}) ->
    catch gen_server:stop(Pid),
    catch ets:delete(Tab),
    _ = persistent_term:erase({?MODULE, cycle}),
    ok.

%% The key 1 first, then the sizes 1, the half and the size minus 1.
shrink_op({put, Key, Size} = Op) ->
    case persistent_term:get({?MODULE, cycle}, false) of
        true ->
            [Op];
        false ->
            [{put, 1, Size} || Key > 1] ++
                lists:usort([{put, Key, S} || S <- [1, Size div 2, Size - 1], S >= 1, S < Size])
    end.
