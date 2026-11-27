-module(eta_continue_sut).
-behaviour(eta_harness).

%% One operation: a client that starts `eta_continue_server' with the script
%% of the configuration. See `eta_continue_ops:client/1'.

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1]).

init(_Seed, #{script := Script}) ->
    {ok, #{script => Script, procs => []}}.

processes(#{procs := Procs}) ->
    Procs.

generate(_Sut, Rand) ->
    {start, Rand}.

execute(start, Sut = #{script := Script, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() -> eta_continue_ops:client(Script) end),
    Sut#{procs := Procs ++ [Pid]}.

check(_Sut) ->
    ok.

terminate(_Sut) ->
    ok.
