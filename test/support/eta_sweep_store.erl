-module(eta_sweep_store).
-behaviour(gen_server).

%% A store of `eta_sweep_sut'. The server writes `{Key, Size}' to an ETS
%% table. The module has no defect. The harness decides which size is a
%% violation.

-include_lib("eta/include/eta.hrl").

-export([start_link/1, put/3]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Tab) ->
    gen_server:start_link(?MODULE, Tab, []).

put(Pid, Key, Size) ->
    gen_server:call(Pid, {put, Key, Size}).

init(Tab) ->
    {ok, Tab}.

handle_call({put, Key, Size}, _From, Tab) ->
    true = ets:insert(Tab, {Key, Size}),
    {reply, ok, Tab}.

handle_cast(_Msg, Tab) ->
    {noreply, Tab}.
