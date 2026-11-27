-module(eta_preempt_store).
-behaviour(gen_server).

%% A `gen_server' that keeps 2 balances in a `protected' ETS table, and a
%% function that reads the balances in the calling process. The sum of the
%% balances is 100 after every transfer.
%%
%% The module declares its `ets' calls as preemption points.
%%
%% - With `atomic => false', a transfer is 2 calls of `ets:update_counter/3',
%%   and a read is 2 calls of `ets:lookup/2'. Between the 2 calls of a
%%   transfer the sum is not 100. On the BEAM a reader can run there. In a
%%   run, a reader runs there only with the `preempt' option.
%% - With `atomic => true', both balances are in one row. A transfer is one
%%   `ets:insert/2' and a read is one `ets:lookup/2', so a reader sees the
%%   sum 100 at every preemption point.

-include_lib("eta/include/eta.hrl").

-eta_preempt([ets]).

-export([start_link/1, handle/1, transfer/2, total/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Atomic) ->
    gen_server:start_link(?MODULE, Atomic, []).

%% What a reader needs for `total/1'.
handle(Pid) ->
    gen_server:call(Pid, handle).

transfer(Pid, Amount) ->
    gen_server:call(Pid, {transfer, Amount}).

%% The sum of the balances, read in the calling process.
total({Table, false}) ->
    [{a, A}] = ets:lookup(Table, a),
    [{b, B}] = ets:lookup(Table, b),
    A + B;
total({Table, true}) ->
    [{both, A, B}] = ets:lookup(Table, both),
    A + B.

init(Atomic) ->
    Table = ets:new(?MODULE, [protected, set]),
    true = ets:insert(Table, [{a, 100}, {b, 0}, {both, 100, 0}]),
    {ok, {Table, Atomic}}.

handle_call(handle, _From, State) ->
    {reply, State, State};
handle_call({transfer, Amount}, _From, State = {Table, false}) ->
    _ = ets:update_counter(Table, a, -Amount),
    _ = ets:update_counter(Table, b, Amount),
    {reply, ok, State};
handle_call({transfer, Amount}, _From, State = {Table, true}) ->
    [{both, A, B}] = ets:lookup(Table, both),
    true = ets:insert(Table, {both, A - Amount, B + Amount}),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
