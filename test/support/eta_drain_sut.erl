-module(eta_drain_sut).
-behaviour(eta_harness).

%% One `eta_drain_server' and a driver that sends it bursts of items.

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1]).

init(_Seed, #{tab := Tab}) ->
    {ok, Pid} = eta_drain_server:start_link(Tab),
    {ok, #{tab => Tab, server => Pid, sent => 0}}.

processes(#{server := Pid}) ->
    [Pid].

generate(_Sut, Rand0) ->
    {K, Rand1} = rand:uniform_s(4, Rand0),
    {{burst, K}, Rand1}.

%% The items of a burst are sent in one step of the driver, so the server
%% finds the later items in its mailbox when it handles the first.
execute({burst, K}, Sut = #{server := Pid, sent := Sent}) ->
    lists:foreach(fun(N) -> ok = eta_drain_server:item(Pid, N) end, lists:seq(Sent + 1, Sent + K)),
    Sut#{sent := Sent + K}.

%% The server handles every item once, in the order sent.
check(#{tab := Tab}) ->
    Handled = lists:append(eta_drain_server:groups(Tab)),
    case Handled =:= lists:seq(1, length(Handled)) of
        true -> ok;
        false -> {violation, {out_of_order, Handled}}
    end.

terminate(#{server := Pid}) ->
    catch gen_server:stop(Pid),
    ok.
