-module(eta_yield_worker).
-behaviour(gen_server).

%% A `gen_server' that does its work in chunks through a time-out of 0, as a
%% file transfer worker does: `init/1' returns `{ok, State, 0}', and each
%% `timeout' does one chunk and returns a time-out of 0 again. A `poke' is
%% handled between two chunks if it arrives first, as `gen_server' handles any
%% message before `timeout'.
%%
%% Every chunk and every poke is recorded in order in an ETS table.

-include_lib("eta/include/eta.hrl").

-export([start/2, poke/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(Tab, Chunks) ->
    gen_server:start({local, ?MODULE}, ?MODULE, {Tab, Chunks}, []).

poke(N) ->
    gen_server:cast(?MODULE, {poke, N}).

init({Tab, Chunks}) ->
    {ok, #{tab => Tab, left => Chunks, seq => 0}, 0}.

handle_call(_Req, _From, St) ->
    {reply, ok, St}.

handle_cast({poke, N}, St) ->
    {noreply, record({poke, N}, St), 0}.

handle_info(timeout, St = #{left := 0}) ->
    {noreply, St};
handle_info(timeout, St = #{left := Left}) ->
    {noreply, record({chunk, Left}, St#{left := Left - 1}), 0}.

record(Event, St = #{tab := Tab, seq := Seq}) ->
    true = ets:insert(Tab, {Seq, Event}),
    St#{seq := Seq + 1}.
