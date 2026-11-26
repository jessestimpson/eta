-module(eta_vm_wait_sut).

%% A system for a step in which the process calls a function of the `erlang'
%% module that waits for an answer of another process.
%%
%% The caller waits in a `receive' inside the call, such as the one in
%% `erts_internal:await_result/1'. The step must not end there. See
%% `blocked_or_vm_wait/3' in `eta_sched'.
%%
%% The module is built without `eta_transform'.

-export([early/3, hibernate/0, wake/0]).

-type call() :: garbage_collect | check_process_code | process_info.
-type target() :: suspended_big | outside_busy.

%% Runs `Trials' trials. In each trial, a process makes the call `Call' with
%% the target `Target', writes a marker and blocks. Returns the number of
%% trials in which the step ended before the marker was written.
%%
%% | Target | Meaning |
%% |---|---|
%% | `suspended_big' | A scheduled process with a heap of 3,000,000 cells. |
%% | `outside_busy' | A process outside the schedule that builds a list of 2,000,000 cells in a loop. |
-spec early(pos_integer(), call(), target()) -> non_neg_integer().
early(Trials, Call, Target) ->
    length([early || _ <- lists:seq(1, Trials), not trial(Call, Target)]).

trial(Call, Target) ->
    Tab = ets:new(?MODULE, [public]),
    {T, Scheduled} = target(Target),
    A = spawn(fun() ->
        receive
            go -> ok
        end,
        _ = call(Call, T),
        true = ets:insert(Tab, {done}),
        idle()
    end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A | [T || Scheduled]]),
    A ! go,
    {progress, _} = eta_sched:step(Sched, id(Sched, A)),
    Done = ets:member(Tab, done),
    #{timeouts := 0} = eta_sched:stats(Sched),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    exit(T, kill),
    true = ets:delete(Tab),
    Done.

target(suspended_big) ->
    Me = self(),
    T = spawn(fun() ->
        Heap = lists:seq(1, 3000000),
        Me ! {ready, self()},
        receive
            never -> Heap
        end
    end),
    receive
        {ready, T} -> ok
    end,
    {T, true};
target(outside_busy) ->
    {spawn(fun Busy() ->
            _ = lists:seq(1, 2000000),
            Busy()
        end),
        false}.

call(garbage_collect, T) -> erlang:garbage_collect(T);
call(check_process_code, T) -> erlang:check_process_code(T, lists);
call(process_info, T) -> erlang:process_info(T, messages).

%% A process hibernates in its first step. The step must end as a block and
%% not as a time-out, and a message must make the process runnable. Returns
%% the number of time-outs, whether the process was runnable before the
%% message, and whether it was runnable after the message.
-spec hibernate() -> {non_neg_integer(), boolean(), boolean()}.
hibernate() ->
    A = spawn(fun() ->
        receive
            go -> erlang:hibernate(?MODULE, wake, [])
        end
    end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A]),
    Id = id(Sched, A),
    A ! go,
    {progress, _} = eta_sched:step(Sched, Id),
    Before = lists:member(Id, eta_sched:runnable(Sched)),
    A ! wake,
    After = lists:member(Id, eta_sched:runnable(Sched)),
    {progress, _} = eta_sched:step(Sched, Id),
    #{timeouts := Timeouts} = eta_sched:stats(Sched),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    {Timeouts, Before, After}.

-spec wake() -> no_return().
wake() ->
    receive
        wake -> idle()
    end.

id(Sched, Pid) ->
    [Id] = [I || {I, P} <- maps:to_list(eta_sched:procs(Sched)), P =:= Pid],
    Id.

idle() ->
    receive
        never -> ok
    end.
