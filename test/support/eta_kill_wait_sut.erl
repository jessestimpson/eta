-module(eta_kill_wait_sut).
-behaviour(eta_harness).

-compile({parse_transform, eta_transform}).

%% A system under test for a process that kills another scheduled process and
%% then waits for its `DOWN'.
%%
%% This is what `supervisor:shutdown/1' does to a child that does not trap
%% exits. The victim is suspended by the scheduler, but an exit signal still
%% kills it at once. The victim's `DOWN' then reaches the killer in real time,
%% after the killer has blocked in its receive.
%%
%% The killer waits with `receive ... after 30000'. The `after' is on the
%% virtual clock, so the time at which the killer records its result says
%% whether the scheduler noticed the `DOWN' or waited for the time-out.
%%
%% Config:
%%
%% <dl>
%%   <dt>`victims'</dt><dd>how many processes the killer kills, one after
%%     another, waiting for each `DOWN'. The default is 1.</dd>
%% </dl>

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1]).
-export([killer/1]).

-define(TAB, eta_kill_wait_sut).
-define(WAIT_MS, 30000).

init(_Seed, Config) ->
    catch ets:delete(?TAB),
    ets:new(?TAB, [public, ordered_set, named_table]),
    Victims = [spawn(fun idle/0) || _ <- lists:seq(1, maps:get(victims, Config, 1))],
    Killer = spawn(?MODULE, killer, [Victims]),
    {ok, #{killer => Killer, victims => Victims, sent => false}}.

processes(#{killer := K, victims := Vs}) ->
    [K | Vs].

generate(_Sut, Rand) ->
    {go, Rand}.

execute(go, Sut = #{sent := true}) ->
    Sut;
execute(go, Sut = #{killer := K}) ->
    K ! go,
    Sut#{sent := true}.

check(_Sut) ->
    ok.

terminate(#{killer := K, victims := Vs}) ->
    [exit(P, kill) || P <- [K | Vs]],
    ok.

killer(Victims) ->
    receive
        go -> kill_each(Victims, 1)
    end.

kill_each([], _N) ->
    receive
        never -> ok
    end;
kill_each([V | Rest], N) ->
    M = erlang:monitor(process, V),
    exit(V, shutdown),
    Result =
        receive
            {'DOWN', M, process, V, Reason} -> {down, Reason}
        after ?WAIT_MS ->
            timeout
        end,
    ets:insert(?TAB, {N, Result, erlang:monotonic_time(millisecond)}),
    kill_each(Rest, N + 1).

idle() ->
    receive
        never -> ok
    end.
