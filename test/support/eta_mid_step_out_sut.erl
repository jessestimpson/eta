-module(eta_mid_step_out_sut).

%% A system for the end of a step in `eta_sched'. A client takes a reply
%% that came through an alias with the option `reply_demonitor', calls
%% `erlang:demonitor(Ref, [flush])', sends one message to itself and blocks
%% in a `receive' that does not match the message.
%%
%% The VM schedules the client out and in again inside the `demonitor' call.
%% The step must end at the last `out' event, so the client must not be
%% runnable after the step.
%%
%% `gen_server:check_response/3' makes the same `demonitor' call.
%%
%% The module is built without `eta_transform'.

-export([run/2]).

%% Runs `Trials' trials while `Busy' processes that never block run in the
%% VM. The busy processes delay the scheduler between an `out' event and the
%% read of the status. Returns the number of trials in which the client was
%% runnable after the step.
-spec run(pos_integer(), non_neg_integer()) -> non_neg_integer().
run(Trials, Busy) ->
    Spinners = [spawn(fun Spin() -> _ = lists:seq(1, 50), Spin() end) || _ <- lists:seq(1, Busy)],
    Wrong = length([wrong || _ <- lists:seq(1, Trials), trial()]),
    _ = [exit(Spinner, kill) || Spinner <- Spinners],
    Wrong.

-spec trial() -> boolean().
trial() ->
    Server = spawn(fun Loop() ->
        receive
            {request, Alias} ->
                Alias ! {Alias, reply},
                Loop()
        end
    end),
    Client = spawn(fun() -> client(Server) end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [Client, Server]),
    Procs = eta_sched:procs(Sched),
    [ClientId] = [Id || {Id, Pid} <- maps:to_list(Procs), Pid =:= Client],
    [ServerId] = [Id || {Id, Pid} <- maps:to_list(Procs), Pid =:= Server],
    Client ! go,
    %% The client sends the request.
    {_, _} = eta_sched:step(Sched, ClientId),
    %% The server sends the reply.
    {_, _} = eta_sched:step(Sched, ServerId),
    %% The client takes the reply, calls `demonitor', sends one message to
    %% itself and blocks.
    {_, _} = eta_sched:step(Sched, ClientId),
    Runnable = lists:member(ClientId, eta_sched:runnable(Sched)),
    ok = eta_sched:release(Sched),
    exit(Client, kill),
    exit(Server, kill),
    Runnable.

client(Server) ->
    receive
        go -> ok
    end,
    Ref = erlang:monitor(process, Server, [{alias, reply_demonitor}]),
    Server ! {request, Ref},
    receive
        {Ref, reply} -> ok
    end,
    true = erlang:demonitor(Ref, [flush]),
    self() ! reposted,
    receive
        never -> ok
    end.
