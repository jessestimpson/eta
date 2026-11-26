-module(eta_exit_signal_sut).

%% A system for the deaths that happen outside a step of the dead process.
%%
%% A process that does not trap exits dies when the VM handles an exit signal
%% for the process, also while `eta_sched' holds the process suspended. The
%% dead process then sends the signals of its own links and monitors at a time
%% that the VM chooses. `eta_sched' must settle these deaths before the next
%% choice. See `settle/1' in `eta_sched'.
%%
%% The module is built without `eta_transform', so every call to `exit/2' is a
%% call to the BIF.

-export([chain/2, trapper/2, shutdown/2]).

%% `P' exits in its step. `Links' processes form a chain of links that starts
%% at `P', and none of them traps exits. `W' monitors the last process of the
%% chain and waits for the `DOWN' message. Returns the number of trials, of
%% `Trials', in which `W' was not runnable after the step of `P'.
-spec chain(pos_integer(), pos_integer()) -> non_neg_integer().
chain(Trials, Links) ->
    length([missed || _ <- lists:seq(1, Trials), not chain_trial(Links)]).

chain_trial(Links) ->
    Me = self(),
    P = spawn(fun() ->
        receive
            go -> exit(crash)
        end
    end),
    Chain = links(P, Links, []),
    Last = hd(Chain),
    W = spawn(fun() ->
        Ref = erlang:monitor(process, Last),
        Me ! {ready, self()},
        receive
            {'DOWN', Ref, process, Last, _} -> idle()
        end
    end),
    receive
        {ready, W} -> ok
    end,
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [P, W | Chain]),
    P ! go,
    {exited, _} = eta_sched:step(Sched, id(Sched, P)),
    Runnable = lists:member(id(Sched, W), eta_sched:runnable(Sched)),
    ok = eta_sched:release(Sched),
    _ = [exit(X, kill) || X <- [W | Chain]],
    Runnable.

%% Returns the chain with the last process first.
links(_Prev, 0, Acc) ->
    Acc;
links(Prev, N, Acc) ->
    Me = self(),
    Y = spawn(fun() ->
        link(Prev),
        Me ! {ready, self()},
        idle()
    end),
    receive
        {ready, Y} -> ok
    end,
    links(Y, N - 1, [Y | Acc]).

%% `A' traps exits and is linked to `B'. In its step, `A' calls
%% `exit(B, shutdown)' and blocks in a `receive' that does not match the
%% `EXIT' message of `B'. The message must be in the queue of `A' before the
%% end of the step, so `A' must not be runnable after the step. `Busy'
%% processes that never block run in the VM. Returns the number of trials in
%% which `A' was runnable.
-spec trapper(pos_integer(), non_neg_integer()) -> non_neg_integer().
trapper(Trials, Busy) ->
    busy(Busy, fun() -> length([runnable || _ <- lists:seq(1, Trials), trapper_trial()]) end).

trapper_trial() ->
    Me = self(),
    B = spawn(fun idle/0),
    A = spawn(fun() ->
        process_flag(trap_exit, true),
        link(B),
        Me ! {ready, self()},
        receive
            go -> ok
        end,
        exit(B, shutdown),
        idle()
    end),
    receive
        {ready, A} -> ok
    end,
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A, B]),
    A ! go,
    {_, _} = eta_sched:step(Sched, id(Sched, A)),
    Runnable = lists:member(id(Sched, A), eta_sched:runnable(Sched)),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    Runnable.

%% `A' monitors `B', calls `exit(B, shutdown)' and waits for the `DOWN'
%% message, as `supervisor:shutdown/2' does. `A' must take the message in the
%% same step. Returns the number of trials in which `A' did not.
-spec shutdown(pos_integer(), non_neg_integer()) -> non_neg_integer().
shutdown(Trials, Busy) ->
    busy(Busy, fun() -> length([missed || _ <- lists:seq(1, Trials), not shutdown_trial()]) end).

shutdown_trial() ->
    Me = self(),
    Tab = ets:new(?MODULE, [public]),
    B = spawn(fun idle/0),
    A = spawn(fun() ->
        Ref = erlang:monitor(process, B),
        Me ! {ready, self()},
        receive
            go -> ok
        end,
        exit(B, shutdown),
        receive
            {'DOWN', Ref, process, B, shutdown} -> ok
        end,
        true = ets:insert(Tab, {taken}),
        idle()
    end),
    receive
        {ready, A} -> ok
    end,
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A, B]),
    A ! go,
    {_, _} = eta_sched:step(Sched, id(Sched, A)),
    Taken = ets:member(Tab, taken),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    true = ets:delete(Tab),
    Taken.

busy(Busy, Fun) ->
    Spinners = [
        spawn(fun Spin() ->
            _ = lists:seq(1, 50),
            Spin()
        end)
     || _ <- lists:seq(1, Busy)
    ],
    Result = Fun(),
    _ = [exit(Spinner, kill) || Spinner <- Spinners],
    Result.

id(Sched, Pid) ->
    [Id] = [I || {I, P} <- maps:to_list(eta_sched:procs(Sched)), P =:= Pid],
    Id.

idle() ->
    receive
        never -> ok
    end.
