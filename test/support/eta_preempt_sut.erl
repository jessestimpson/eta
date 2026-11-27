-module(eta_preempt_sut).
-behaviour(eta_harness).

%% One `eta_preempt_store', clients that transfer between its 2 balances, and
%% readers that read the sum of the balances in their own process.
%%
%% The invariant `total' is violated when a reader saw a sum other than 100.
%% The configuration `atomic' selects the mode of the store.

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1, shrink_op/1]).

init(_Seed, Config) ->
    {ok, Store} = eta_preempt_store:start_link(maps:get(atomic, Config, false)),
    Handle = eta_preempt_store:handle(Store),
    Log = ets:new(?MODULE, [public, ordered_set]),
    {ok, #{store => Store, handle => Handle, log => Log, procs => [Store]}}.

processes(#{procs := Procs}) ->
    Procs.

%% Half of the operations transfer an amount from 1 to 9, and half read.
generate(_Sut, Rand0) ->
    {Kind, Rand1} = rand:uniform_s(2, Rand0),
    {Amount, Rand2} = rand:uniform_s(9, Rand1),
    case Kind of
        1 -> {{transfer, Amount}, Rand2};
        2 -> {read, Rand2}
    end.

execute({transfer, Amount}, Sut = #{store := Store, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() -> eta_preempt_ops:transfer(Store, Amount) end),
    Sut#{procs := Procs ++ [Pid]};
execute(read, Sut = #{handle := Handle, log := Log, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() -> eta_preempt_ops:read(Handle, Log) end),
    Sut#{procs := Procs ++ [Pid]}.

%% `check/1' reads the log of the readers and not the table of the store. A
%% step can end between the 2 writes of a transfer, so the table of the store
%% does not have the sum 100 at every check.
check(#{log := Log}) ->
    case [Total || {_, Total} <- ets:tab2list(Log), Total =/= 100] of
        [] -> ok;
        Wrong -> {violation, #{property => total, totals => Wrong}}
    end.

terminate(#{store := Store, log := Log, procs := Procs}) ->
    lists:foreach(fun(Pid) -> Pid =/= Store andalso exit(Pid, kill) end, Procs),
    catch gen_server:stop(Store),
    catch ets:delete(Log),
    ok.

shrink_op({transfer, Amount}) when Amount > 1 -> [{transfer, 1}];
shrink_op(_Op) -> [].
