-module(eta_rand_worker).
-behaviour(gen_server).

%% A process that draws from `rand` the way most Erlang does — `rand:uniform/1`
%% with no seeding — and records what it got. Built with the transform, so the
%% draw lands in `eta_rand`; that is the whole point of it.
%%
%% Draws are recorded in an ETS table the harness reads afterwards, since a
%% suspended process cannot be asked.

-include_lib("eta/include/eta.hrl").

-export([start_link/2, draw/1, reseed/2, values/2]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link(Tab, Name) ->
    gen_server:start_link(?MODULE, {Tab, Name}, []).

draw(Pid) ->
    gen_server:cast(Pid, draw).

reseed(Pid, Seed) ->
    gen_server:cast(Pid, {reseed, Seed}).

%% Every value this worker drew, oldest first.
values(Tab, Name) ->
    [V || {{draw, N, _Seq}, V} <- lists:sort(ets:tab2list(Tab)), N =:= Name].

init({Tab, Name}) ->
    ok = ?ETA_LABEL(Name),
    {ok, #{tab => Tab, name => Name, seq => 0}}.

handle_call(_Req, _From, St) ->
    {reply, ok, St}.

handle_cast(draw, St = #{tab := Tab, name := Name, seq := Seq}) ->
    V = rand:uniform(1000000),
    _ = ?ETA_LOG({drew, V}),
    true = ets:insert(Tab, {{draw, Name, Seq}, V}),
    {noreply, St#{seq := Seq + 1}};
handle_cast({reseed, Seed}, St) ->
    _ = rand:seed(exsss, Seed),
    {noreply, St}.
