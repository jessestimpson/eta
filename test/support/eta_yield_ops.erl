-module(eta_yield_ops).

%% The operation bodies of `eta_yield_sut'. They run as scheduled processes, so
%% they are in a transformed module.

-include_lib("eta/include/eta.hrl").

-export([start/2, poke/1]).

start(Tab, Chunks) ->
    {ok, _} = eta_yield_worker:start(Tab, Chunks),
    ok.

poke(N) ->
    eta_yield_worker:poke(N).
