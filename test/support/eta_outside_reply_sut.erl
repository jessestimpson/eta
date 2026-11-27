-module(eta_outside_reply_sut).

%% A system for a step that ends as a block while the process can still be
%% woken by a process outside the schedule.
%%
%% The process asks `file_server_2', which the scheduler does not own, and
%% blocks in `gen:do_call/4'. The answer can arrive while the scheduler confirms
%% the block. The process then runs on, into a dirty NIF, after its step ended.
%% The scheduler must not take that step for a block. See `note_running/2' in
%% `eta_sched'.
%%
%% The module is built without `eta_transform'.

-export([stranded/1, counted/1, quiet/1, timed_out/0]).

%% Runs `Trials' trials. In each, a process asks `file_server_2' for a file's
%% information (`file:read_file_info/1'), reads it again with a dirty NIF
%% (`prim_file:read_file_info/1'), writes a marker and blocks. Returns the
%% number of trials in which the marker is not written and the process is not
%% runnable: nothing would step it again.
-spec stranded(pos_integer()) -> non_neg_integer().
stranded(Trials) ->
    {Stranded, _RanOn} = counted(Trials),
    Stranded.

%% Runs `Trials' trials as `stranded/1' does. Returns the number of stranded
%% trials, and the sum of the statistic `ran_on' over the trials.
-spec counted(pos_integer()) -> {non_neg_integer(), non_neg_integer()}.
counted(Trials) ->
    File = code:which(?MODULE),
    Results = [trial(File) || _ <- lists:seq(1, Trials)],
    {length([stranded || {false, _} <- Results]), lists:sum([N || {_, N} <- Results])}.

trial(File) ->
    Tab = ets:new(?MODULE, [public]),
    A = spawn(fun() ->
        receive
            go -> ok
        end,
        {ok, _} = file:read_file_info(File),
        {ok, _} = prim_file:read_file_info(File),
        true = ets:insert(Tab, {done}),
        idle()
    end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A]),
    Id = id(Sched, A),
    A ! go,
    {_, _} = eta_sched:step(Sched, Id),
    %% `file_server_2' answers in the order it was asked, so once it has
    %% answered this call it has answered the process's.
    {ok, _} = file:get_cwd(),
    Ok = ets:member(Tab, done) orelse lists:member(Id, eta_sched:runnable(Sched)),
    #{ran_on := RanOn} = eta_sched:stats(Sched),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    true = ets:delete(Tab),
    {Ok, RanOn}.

%% A process that nothing outside the schedule wakes. In each of `Rounds'
%% rounds the process takes one message and blocks again, in one of 3 ways: in a
%% plain `receive', in `erlang:hibernate/3', and in `eta_sched:yield/0'. After
%% each step, this function reads the messages and the current function of the
%% blocked process, which makes the VM schedule the process in and out to
%% handle the signal. Returns the statistics `ran_on' and `timeouts', which
%% must both be 0.
-spec quiet(pos_integer()) -> {non_neg_integer(), non_neg_integer()}.
quiet(Rounds) ->
    A = spawn(fun() -> quiet_loop() end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A]),
    Id = id(Sched, A),
    lists:foreach(
        fun(N) ->
            A ! lists:nth(1 + N rem 3, [plain, hibernate, yield]),
            quiet_steps(Sched, Id, A)
        end,
        lists:seq(1, Rounds)
    ),
    #{ran_on := RanOn, timeouts := Timeouts} = eta_sched:stats(Sched),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    {RanOn, Timeouts}.

quiet_steps(Sched, Id, A) ->
    case lists:member(Id, eta_sched:runnable(Sched)) of
        true ->
            {_, _} = eta_sched:step(Sched, Id),
            _ = erlang:process_info(A, messages),
            _ = erlang:process_info(A, current_function),
            quiet_steps(Sched, Id, A);
        false ->
            ok
    end.

-spec quiet_loop() -> no_return().
quiet_loop() ->
    receive
        plain -> quiet_loop();
        hibernate -> erlang:hibernate(fun quiet_loop/0);
        yield -> eta_sched:yield(), quiet_loop()
    end.

%% A step that ends in a time-out: the process is in a dirty NIF for 2 s, with
%% an empty queue. Returns the number of time-outs and whether the process is
%% runnable after the step.
-spec timed_out() -> {non_neg_integer(), boolean()}.
timed_out() ->
    A = spawn(fun() ->
        receive
            go -> ok
        end,
        ok = erts_debug:dirty_io(wait, 2000),
        idle()
    end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [A]),
    Id = id(Sched, A),
    A ! go,
    {_, _} = eta_sched:step(Sched, Id),
    #{timeouts := Timeouts} = eta_sched:stats(Sched),
    Runnable = lists:member(Id, eta_sched:runnable(Sched)),
    ok = eta_sched:release(Sched),
    exit(A, kill),
    {Timeouts, Runnable}.

id(Sched, Pid) ->
    [Id] = [I || {I, P} <- maps:to_list(eta_sched:procs(Sched)), P =:= Pid],
    Id.

idle() ->
    receive
        never -> ok
    end.
