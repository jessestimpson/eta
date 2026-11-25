-module(eta_pid_reuse_sut).

%% A system for the statistic `pid_reuse' of `eta_sched'. One process
%% spawns `Count' children, 50 for each message that it handles. A child
%% exits in its first step.
%%
%% The module is built without `eta_transform', so that a spawn is a plain
%% spawn. The scheduler learns of each child from the spawn trace event.
%%
%% `run/1' is called in a VM of its own. The count of reused pids depends on
%% the number of processes that the VM has created, which no test controls
%% in a VM that runs other tests.

-export([run/1]).

-define(BATCH, 50).

%% Runs the system under a scheduler. The result has the statistics of the
%% scheduler, and whether the list of the children in the order of their
%% creation is sorted in the term order of pids.
-spec run(pos_integer()) -> #{stats := map(), sorted := boolean(), children := non_neg_integer()}.
run(Count) ->
    Self = self(),
    Parent = spawn(fun() -> parent(Count, [], Self) end),
    Sched = eta_sched:register(eta_sched:new(#{seed => 1}), [Parent]),
    Parent ! go,
    Sched1 = eta_sched:run(Sched, Count * 3),
    Children =
        receive
            {children, Pids} -> Pids
        after 30000 -> error({timeout, eta_sched:stats(Sched1)})
        end,
    Stats = eta_sched:stats(Sched1),
    _ = eta_sched:release(Sched1),
    #{stats => Stats, sorted => Children =:= lists:sort(Children), children => length(Children)}.

%% Each message `go' starts the next 50 children. The scheduler chooses
%% between this process and the children that have not run, so the VM has
%% a few hundred processes at most at one time.
parent(0, Children, Report) ->
    Report ! {children, lists:reverse(Children)},
    ok;
parent(Left, Children, Report) ->
    receive
        go ->
            Batch = min(Left, ?BATCH),
            New = [spawn(fun() -> ok end) || _ <- lists:seq(1, Batch)],
            self() ! go,
            parent(Left - Batch, lists:reverse(New, Children), Report)
    end.
