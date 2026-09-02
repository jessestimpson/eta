-module(eta_rand_sut).
-behaviour(eta_harness).

%% A harness for `eta_rand`: a few workers that draw from `rand` when told to.
%%
%% The table the draws land in is supplied by the test through `config`, and is
%% left alone by `terminate/1`, so the test can read the draws after the run.
%%
%% Two switches, both off by default:
%%
%% - `reseed => Seed` makes the first operation an explicit `rand:seed/2` on
%%   worker 1, so a test can check that an explicit seed is honoured.
%% - `driver_draw => true` makes `execute/2` draw from `eta_rand` on the driver,
%%   which is a draw by a process the scheduler is not stepping — the thing
%%   `unmanaged` counts.

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1, labels/1]).

-define(WORKERS, 3).

init(_Seed, Config) ->
    Tab = maps:get(tab, Config),
    N = maps:get(workers, Config, ?WORKERS),
    Workers = [
        begin
            {ok, Pid} = eta_rand_worker:start_link(Tab, {worker, I}),
            {I, Pid}
        end
     || I <- lists:seq(1, N)
    ],
    Pending =
        case maps:find(reseed, Config) of
            {ok, Seed} -> [{reseed, 1, Seed}];
            error -> []
        end,
    {ok, #{
        workers => Workers,
        count => N,
        pending => Pending,
        driver_draw => maps:get(driver_draw, Config, false)
    }}.

processes(#{workers := Workers}) ->
    [P || {_I, P} <- Workers].

labels(#{workers := Workers}) ->
    maps:from_list([{P, {worker, I}} || {I, P} <- Workers]).

generate(#{pending := [Op | _]}, Rand) ->
    {Op, Rand};
generate(#{count := N}, Rand0) ->
    {I, Rand1} = rand:uniform_s(N, Rand0),
    {{draw, I}, Rand1}.

execute({reseed, I, Seed}, Sut = #{pending := Pending}) ->
    ok = eta_rand_worker:reseed(worker(I, Sut), Seed),
    Sut#{pending := Pending -- [{reseed, I, Seed}]};
execute({draw, I}, Sut = #{driver_draw := DriverDraw}) ->
    ok = eta_rand_worker:draw(worker(I, Sut)),
    case DriverDraw of
        true -> _ = eta_rand:uniform(10);
        false -> ok
    end,
    Sut.

check(_Sut) ->
    ok.

terminate(Sut) ->
    lists:foreach(fun(P) -> catch gen_server:stop(P) end, processes(Sut)),
    ok.

worker(I, #{workers := Workers}) ->
    proplists:get_value(I, Workers).
