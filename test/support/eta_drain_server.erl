-module(eta_drain_server).
-behaviour(gen_server).

%% A `gen_server' that takes further requests out of its own mailbox while
%% it handles one. This is how a server commits requests in groups: one
%% write for every request that is already waiting.
%%
%% The drain is a `receive ... after 0' on the message formats of
%% `gen_server'. `eta_transform' leaves `after 0' alone, because it is a
%% poll of the mailbox and not a wait.

-include_lib("eta/include/eta.hrl").

-export([start_link/1, item/2, groups/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Tab) ->
    gen_server:start_link(?MODULE, Tab, []).

item(Pid, N) ->
    gen_server:cast(Pid, {item, N}).

%% Every group that the server handled, oldest first.
groups(Tab) ->
    [Group || {_Seq, Group} <- lists:sort(ets:tab2list(Tab))].

init(Tab) ->
    {ok, #{tab => Tab, seq => 0}}.

handle_call(_Req, _From, St) ->
    {reply, ok, St}.

handle_cast({item, N}, St = #{tab := Tab, seq := Seq}) ->
    Group = [N | drain()],
    _ = ?ETA_LOG({group, Group}),
    true = ets:insert(Tab, {Seq, Group}),
    {noreply, St#{seq := Seq + 1}}.

drain() ->
    receive
        {'$gen_cast', {item, N}} -> [N | drain()]
    after 0 -> []
    end.
