-module(eta_preempt_ops).

%% The operation bodies of `eta_preempt_sut'. They run as scheduled processes,
%% so they are in a transformed module. The module has no `-eta_preempt'
%% attribute: the write to the log of the harness is not a preemption point.

-include_lib("eta/include/eta.hrl").

-export([transfer/2, read/2]).

transfer(Store, Amount) ->
    eta_preempt_store:transfer(Store, Amount).

%% Reads the sum of the balances and records it.
read(Handle, Log) ->
    Total = eta_preempt_store:total(Handle),
    true = ets:insert(Log, {erlang:unique_integer([monotonic]), Total}),
    ok.
