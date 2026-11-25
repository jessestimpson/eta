-module(eta_cold_harness).

%% A harness for `sched.cold_code' under `eta_run'. `init/2' spawns one
%% process that calls a module that is not loaded. The test suspends
%% `code_server' for the run, so the process waits on `code_server' when the
%% run ends.
%%
%% The harness generates no operation that does work. The run ends when its
%% settle phase ends.

-behaviour(eta_harness).

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1]).

init(_Seed, _Config) ->
    Victim = spawn(fun() -> eta_cold_probe:touch() end),
    {ok, #{victim => Victim}}.

processes(#{victim := Victim}) ->
    [Victim].

generate(_State, Rand) ->
    {noop, Rand}.

execute(noop, State) ->
    State.

check(_State) ->
    ok.

terminate(#{victim := Victim}) ->
    exit(Victim, kill),
    ok.
