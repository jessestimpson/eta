-module(eta_yield_sut).
-behaviour(eta_harness).

%% One `eta_yield_worker' and operations that poke it while it works.

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1]).

init(_Seed, #{tab := Tab, chunks := Chunks}) ->
    {ok, #{tab => Tab, chunks => Chunks, started => false, pokes => 0, procs => []}}.

processes(#{procs := Procs}) ->
    Procs.

generate(#{started := false}, Rand) ->
    {start, Rand};
generate(_Sut, Rand) ->
    {poke, Rand}.

execute(start, Sut = #{tab := Tab, chunks := Chunks, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() -> eta_yield_ops:start(Tab, Chunks) end),
    Sut#{started := true, procs := Procs ++ [Pid]};
execute(poke, Sut = #{pokes := N, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() -> eta_yield_ops:poke(N + 1) end),
    Sut#{pokes := N + 1, procs := Procs ++ [Pid]}.

%% The chunks are done in order, each once.
check(#{tab := Tab}) ->
    Chunks = [Left || {_, {chunk, Left}} <- lists:sort(ets:tab2list(Tab))],
    case Chunks =:= lists:reverse(lists:usort(Chunks)) of
        true -> ok;
        false -> {violation, #{property => chunk_order, chunks => Chunks}}
    end.

terminate(_Sut) ->
    case whereis(eta_yield_worker) of
        undefined -> ok;
        Pid -> exit(Pid, kill), ok
    end.
