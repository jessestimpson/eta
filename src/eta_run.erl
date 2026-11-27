-module(eta_run).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
The run driver (design: `docs/design.md`).

`eta_run` turns a seed into a run. A run does the following:

1. It starts the virtual clock.
2. It starts the system under test.
3. It performs one action at a time. An action injects a client operation, steps
   one process, or advances virtual time.
4. It checks the invariants after the actions.
5. It records every action in a trace that replays the run exactly.

The system under test implements the `eta_harness` behaviour, which has six
required callbacks.

## Example

```erlang
#{outcome := ok} = eta_run:run(my_sut, #{seed => 7, max_ops => 40}).
```

## Actions

In each iteration the driver performs one of three actions:

| Action | Effect |
|---|---|
| step | Runs one runnable process, chosen with the seeded random generator. |
| op | Injects the next generated operation. |
| clock | Advances the clock to the next timer deadline. |

The driver chooses the action as follows:

| Runnable processes | Operations left | Action |
|---|---|---|
| at least one | yes | op with probability `op_p`, otherwise step |
| at least one | no | step |
| none | yes | clock with probability `quiet_p`, otherwise op |
| none | no | clock |

When the driver chooses clock and no timer is pending, the driver injects an
operation if one is left. Otherwise the run ends as `quiescent`.

`quiet_p` exists for the case in which no process is runnable. A driver that
always injects an operation in that case never lets the system run on its own
timers alone. Some defects occur only in that state. For example, a follower in a
replicated registry that lost the tail of the replication stream detects the gap
on the next batch. When a client operation always follows, the next batch repairs
the gap before an invariant can observe it. `quiet_p` is the probability that the
driver advances time instead of injecting an operation.

## Determinism

Every random choice is drawn from one seeded `rand` state:

- the choice of the process to step;
- the choice between a step, an operation and a clock advance;
- the values that `generate/2` draws.

A run with the same seed and the same system is therefore reproducible.

## Trace

A trace is a list of entries in the order of the actions:

| Entry | Meaning |
|---|---|
| `{op, Op}` | The driver injected `Op`. |
| `{step, Id}` | The driver stepped process `Id`. |
| `{clock, Ms}` | The driver advanced the clock. `Ms` is the clock value after the advance. |
| `{final, Settled}` | How the run ended. This entry is the last entry of a run that ended normally. |

`replay/3` follows a recorded trace and draws no choice from the seed. A trace
that was edited or shrunk therefore replays in the same way as a trace from a
seed. `eta_shrink` depends on this property.

The following rules apply to a trace:

- **Divergence.** A strict replay reports a recorded step of a process that is
  not runnable as a divergence. It does not skip the step. A replay that performs
  a different schedule is not a reproduction of the run.
- **Created processes.** An entry that created processes records their ids as a
  third element, for example `{op, Op, [3, 4]}`. A replay gives these ids to the
  scheduler, and the scheduler does not count the processes again. The deletion
  of one entry therefore does not change the id of a process that another entry
  names. This property lets `eta_shrink` delete an operation and keep the meaning
  of the remaining entries. See `eta_sched:pin/2`.
- **Entry shape.** An entry that created no process has two elements. Match on
  the result of `action/1`, not on the entry.
- **Clock advances.** A clock advance is an entry, like a step and an operation.
  A replay performs only the entries of the trace. Without clock entries the
  clock would not move during a replay, no process would become runnable, and
  the replay would refuse every recorded step.
- **The end of the run.** A replay passes the recorded `Settled` value to
  `check_final/2`. A replay does not derive the value again.

## Startup order

The driver starts the clock before the system. For this reason the driver calls
`init/2`, and the caller does not start the system beforehand.

A timer that is armed while `eta_time` is not running is a timer on the real
clock. The timer stays on the real clock until it fires and is armed again. A
timer with a long period would therefore not be on the virtual clock during a
run.

The driver also starts the simulated network, the simulated disk and the seeded
`rand` streams before `init/2`.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([run/2, replay/3, spawn_op/1, preload/1]).

%% Many seeds, with the first failure shrunk. See `sweep/3`.
-export([sweep/3]).

%% Reading a trace entry. See `action/1`.
-export([action/1, created/1]).

%% Reading a result. See `summary/1` and `audit/1`.
-export([summary/1, audit/1]).

%% Trace fixtures — a failure pinned to disk. See `save_fixture/4`.
-export([save_fixture/4, load_fixture/1, replay_fixture/1, check_fixture/1]).

-export_type([entry/0, created/0, outcome/0, result/0, sweep/0, fixture/0]).

-type entry() ::
    {op, eta_harness:op()}
    | {op, eta_harness:op(), created()}
    | {step, eta_sched:id()}
    | {step, eta_sched:id(), created()}
    | {clock, integer()}
    | {clock, integer(), created()}
    %% How the run ended, recorded so a replay can put a `check_final/2` in the
    %% same position it was in. Always last, and only on a run that ended
    %% normally.
    | {final, eta_harness:settled()}.
%% The processes an entry created, in adoption order. Present only when the entry
%% created somebody, which most do not — a trace of `{step, 3, []}` lines is one
%% nobody wants to read. See `eta_sched:pin/2` for what it is for.
-type created() :: [eta_sched:id()].
-type outcome() ::
    ok
    | {violation, eta_harness:violation()}
    | {error, term()}.
-type result() :: #{
    outcome := outcome(),
    seed := integer(),
    trace := [entry()],
    steps := non_neg_integer(),
    ops := non_neg_integer(),
    clock_ms := integer(),
    %% Recorded steps a lenient replay had to skip; always 0 for a generated run
    %% or a strict replay. See `replay/3`.
    skipped := non_neg_integer(),
    %% Modules that were loaded *while the run was in progress*. Should be
    %% empty. See `run/2`.
    modules_loaded := [module()],
    %% Timers the clock refused to advance to because nothing schedulable owned
    %% them. Should be 0. See `eta_time:advance_to_next/1`.
    stray_timers := non_neg_integer(),
    %% What the simulated network did, or `#{}` when none was installed. See
    %% `eta_net:stats/0`; `dropped` is what a non-vacuity guard asserts on.
    net := #{atom() => non_neg_integer()},
    %% What the simulated disk did, or `#{}` when none was installed. See
    %% `eta_disk:stats/0`.
    disk := #{atom() => non_neg_integer()},
    %% What the seeded `rand` streams did. `unmanaged` is a draw by a process
    %% the scheduler was not stepping. See `eta_rand:stats/0`.
    rand := #{atom() => non_neg_integer()},
    sched := #{atom() => term()}
}.

-type sweep() :: #{
    %% `ok` when every seed passed. Otherwise the outcome of the first run that
    %% did not pass.
    outcome := outcome(),
    %% The number of seeds that were run, the failing seed included.
    runs := non_neg_integer(),
    %% The seed and the result of the first run that did not pass.
    seed => integer(),
    result => result(),
    %% The result of `eta_shrink:shrink/3` on the trace of that run. Present for
    %% a violation, unless the `shrink` option is `false`.
    shrunk => eta_shrink:result()
}.

-type fixture() :: #{
    version := pos_integer(),
    harness := module(),
    trace := [entry()],
    opts := map(),
    outcome := outcome(),
    saved := calendar:datetime()
}.

%% Bumped if the on-disk shape ever changes, so a stale fixture fails with
%% something a person can read rather than a badmatch.
-define(FIXTURE_VERSION, 1).

%% An invariant reads a frozen system, so it should return immediately. Anything
%% slower is a `check/1` that called into a suspended process — see `eta_harness`.
-define(CHECK_TIMEOUT, 5000).

%% Where the simulated wall clock starts: 2024-01-01T00:00:00Z, plus a second
%% per seed so that no two seeds share a timestamp either.
-define(SYSTEM_EPOCH_MS, 1704067200000).

-record(r, {
    mod :: module(),
    sut :: eta_harness:state(),
    sched :: eta_sched:sched(),
    rand :: rand:state(),
    seed :: integer(),
    budget :: non_neg_integer(),
    ops_left :: non_neg_integer(),
    settle_left :: non_neg_integer(),
    op_p :: float(),
    quiet_p :: float(),
    check_every :: pos_integer(),
    check_timeout = ?CHECK_TIMEOUT :: non_neg_integer(),
    lenient = false :: boolean(),
    skipped = 0 :: non_neg_integer(),
    %% Snapshot of the code path taken once the scheduler owns the system, so
    %% that anything loaded afterwards can be reported. See `finish/2`.
    loaded = [] :: [module()],
    since_check = 0 :: non_neg_integer(),
    trace = [] :: [entry()],
    steps = 0 :: non_neg_integer(),
    ops = 0 :: non_neg_integer(),
    %% `busy_steps`: how many steps may pass without the clock moving before it
    %% moves anyway, and how many have. See `busy/1`.
    busy_limit = infinity :: pos_integer() | infinity,
    busy = 0 :: non_neg_integer()
}).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Runs `Mod` under a seed and returns the result.

## Options

Every option has a default.

- `seed` (default 0): the seed of the run. The seed determines every choice of
  the run.
- `config` (default `#{}`): the map that the driver passes to `init/2`.
- `max_ops` (default 50): the number of operations that the driver injects
  before the settle phase.
- `max_steps` (default 10000): the bound on the number of actions of the run.
  Steps, operations and clock advances all count. A run that reaches the bound
  ends with `{error, step_budget_exhausted}`.
- `settle_steps` (default 2000): the number of actions that the run continues
  after the last operation is injected. A system with a periodic timer, such as a
  heartbeat, never becomes quiescent. Without this option such a run could end
  only at `max_steps`. A run that reaches the end of the settle phase ends with
  `ok`. A harness with `settle_done/1` can end the settle phase earlier. See
  `eta_harness`.
- `op_p` (default 0.3): the probability that the driver injects an operation
  instead of stepping a process, when both are possible.
- `quiet_p` (default 0.3): the probability that the driver advances time instead
  of injecting an operation, when no process is runnable. Defects that occur only
  in a period without operations are reachable because of this option. See the
  module documentation.
- `busy_steps` (default `infinity`): the number of actions without a clock
  advance after which the driver advances the clock to the next deadline. The
  clock otherwise moves only when no process is runnable. A system that spins
  keeps a process runnable, so the clock stops and the timer that would end the
  spin never fires. An example is a client that retries at once when a server
  rejects it. On a real machine a spin takes time, and timers fire during it.
- `check_every` (default 1): the driver checks the invariants every N actions.
- `check_timeout` (default 5000): the real time, in milliseconds, that `check/1`
  or `check_final/2` may take. A check that takes longer ends the run with
  `{error, check_blocked}`. The bound detects an invariant that calls a
  suspended process. Raise the value for a slow invariant. Lower the value in a
  test that expects `check_blocked`, so that the test does not wait 5 seconds.
- `log` (default `true`): whether `eta_log` collects a record of the run. With
  `false`, `eta_log` collects no events, but `eta_log:log/1` still returns
  sequence numbers. A harness that stamps its operations with these numbers
  works with either value. See `eta_log`.
- `net` (default `false`): whether the run has a simulated network. `true`
  starts a network without faults. `#{policy => ...}` starts a network that
  injects loss and delay. See `eta_net`. The driver starts the network before
  `init/2` and seeds it from the seed of the run, so the fault schedule is a
  function of that seed only. A harness with a cluster that must sync before it
  can tolerate faults leaves the policy without faults here and calls
  `eta_net:set_policy/1` at the end of `init/2`.
- `disk` (default `false`): whether the run has a simulated disk. `true` starts
  a disk with the default policy. `#{policy => ...}` sets the policy. See
  `eta_disk`. With a disk, `eta_net:kill_node/2` loses a write to a raw file
  handle unless the system synced the write. The driver starts the disk before
  `init/2` and seeds it from the seed of the run.
- `preload` (default `[]`): the applications whose modules the driver loads
  before the run starts. The driver always loads `kernel`, `stdlib` and `eta` in
  addition. `false` disables preloading. Name the application of the system under
  test in this option. See the section "Cold code" below.

## Result

The result is a map with these keys:

| Key | Value |
|---|---|
| `outcome` | `ok`, `{violation, Violation}` or `{error, Reason}`. |
| `seed` | The seed of the run. |
| `trace` | The trace of the run. |
| `steps` | The number of steps. |
| `ops` | The number of injected operations. |
| `clock_ms` | The virtual clock at the end of the run, in milliseconds. |
| `skipped` | The number of recorded entries that a lenient replay skipped. The value is 0 for a generated run and for a strict replay. |
| `modules_loaded` | The modules that were loaded during the run. The expected value is `[]`. |
| `stray_timers` | The number of timers that the clock did not advance to. The expected value is 0. |
| `net` | The counters of `eta_net:stats/0`, or `#{}` without a simulated network. |
| `disk` | The counters of `eta_disk:stats/0`, or `#{}` without a simulated disk. |
| `rand` | The counters of `eta_rand:stats/0`. |
| `sched` | The counters of `eta_sched:stats/1`. |

`run/2` returns these outcomes:

| `outcome` | Cause |
|---|---|
| `ok` | The run ended as `quiescent`, `settle_budget` or `settle_done` with no violation. |
| `{violation, Violation}` | `check/1` or `check_final/2` returned the violation. |
| `{error, step_budget_exhausted}` | The run reached `max_steps`. |
| `{error, check_blocked}` | A check took longer than `check_timeout`. |
| `{error, {check_returned, Other}}` | A check returned a value that is neither `ok` nor a violation. |
| `{error, {check_crashed, Reason}}` | The process that ran a check exited with `Reason`. |

## Result fields that report nondeterminism

A value other than the expected value in one of these fields means that the seed
does not reproduce the run. `audit/1` checks all of them:

```erlang
ok = eta_run:audit(eta_run:run(Mod, Opts)).
```

- `stray_timers` counts the timers of a process that the scheduler does not own
  or that has died. Such a deadline cannot make a process runnable. The driver
  does not advance the clock to it and reports the count. A count above 0 means
  that the system holds a timer outside the schedule. The usual causes are a
  process spawned in `init/2` and a process killed while it was blocked in a
  `receive ... after`.
- `sched.adopted_late` counts the processes that ran before the scheduler owned
  them.
- `sched.timeouts` counts the steps that ended before the process reached a
  `receive`.
- `sched.pid_reuse` counts the processes whose pid compares below the pid of a
  process that was created earlier in the run. A count above 0 means that the
  VM has created about as many processes as its process limit and reuses pid
  values. A system or a harness that depends on the order of pids then does
  not reproduce a run. `audit/1` does not check this field, because a system
  that never compares pids is not affected. See "Limitations" in `eta_sched`.
- `modules_loaded` lists the modules that were loaded during the run. See the
  section "Cold code" below.
- `sched.cold_code` lists the processes that waited on the code server when the
  run ended. See the section "Cold code" below.

## Cold code

Cold code is a module that is not loaded when a scheduled process first calls
it. The load is a synchronous call to `code_server`, and the scheduler does not
own `code_server`. The following happens:

1. The scheduled process blocks on a process outside the schedule.
2. The scheduler treats the block as the end of the step.
3. `code_server` makes the process runnable again at a time that the wall clock
   decides.
4. Every later choice of the run shifts.

The symptom is that the first run in a new VM produces a different trace from
every later run of the same seed. No message is logged, the scheduler gives no
warning, and `adopted_late` stays 0. For this reason the result reports
`modules_loaded`.

The `preload` option is the fix. The names in `modules_loaded` identify the
application to name in `preload`. The module at fault is usually a module that
only a scheduled process calls, because every module that `init/2` calls is
loaded before the run starts.

`preload` is the only reliable fix, because a run loads the modules of one code
path, not of the VM. A run of one seed does not load the branch that a later
seed takes, so a second run of the same seed fixes that seed only. `preload`
loads every module of the application before the run.

### A run that ends early with `ok`

To `eta_sched`, a process that waits on `code_server` is a process blocked in a
`receive`. The process is not runnable. When enough processes call cold code at
the same time, no process is runnable and no timer is pending. The run then ends
in a state that has the form of quiescence, after very few steps, with `ok`.

Measured on the two-phase commit harness with `preload => false` and one cold
module that every client calls: the run had 5 operations and 5 steps, no process
exited, and the result was `outcome => ok`. A correct run of the same workload
takes about 100 steps.

`modules_loaded` does not report this case, because the loads complete after the
run has ended. For this reason `preload` loads `kernel`, `stdlib` and `eta` by
default, and a harness names its own application in `preload` even when the runs
show no problem.

`sched.cold_code` reports this case. When a run ends, for any reason, the
scheduler checks once for a process that is blocked in the `call` function of
the code server. A process that waits on the code server is
always in that function, because the function is a send followed by a `receive`
with one clause. Each entry names the process and the function that called the
cold module:

```erlang
#{sched := #{cold_code := [#{id := 3, pid := _, at := {my_client, commit, 2}}]}}
```

The scheduler also logs a warning.

`cold_code` does not replace `preload`. `cold_code` is detected after the run is
already affected. It identifies the cause and does not repair the run.

`preload` loads the modules of the named applications only. A module of the
harness that is outside these applications, such as a module in a directory of
`extra_src_dirs`, is cold until a process calls it. Load such a module in
`init/2` with `code:ensure_loaded/1` before `init/2` spawns a process.
""".
-endif.
-spec run(module(), map()) -> result().
run(Mod, Opts) ->
    drive(Mod, Opts, generate).

-if(?DOCATTRS).
-doc """
Replays a recorded trace instead of generating a run.

The seed still seeds the system. The driver draws no choice from the seed: every
step, operation and clock advance comes from `Trace`. `Opts` takes the options of
`run/2` and the `lenient` option.

A strict replay is the default. A strict replay ends with an error when the
trace does not apply:

| `outcome` | Cause |
|---|---|
| `{error, {diverged, Id, Runnable}}` | The recorded step names process `Id`, which is not in the list of runnable processes. |
| `{error, {clock_diverged, Ms, Now}}` | The clock advanced to `Now`, not to the recorded `Ms`. |
| `{error, {clock_diverged, Ms, no_timer}}` | The trace records a clock advance and no timer is pending. |

With `lenient => true`, a replay skips a recorded step of a process that is not
runnable and a clock advance with no pending timer. A lenient replay accepts
whatever clock value an advance reaches. The result counts the skipped entries
in `skipped`.

- Use a lenient replay for shrinking. The removal of an operation leaves the
  steps of that operation without a runnable process. A strict replay would
  report a divergence for almost every candidate, and the shrinker would learn
  nothing.
- Do not use a lenient replay to verify a trace.

The `trace` of the result of a lenient replay is the schedule that ran.
`eta_shrink` uses that trace to obtain a trace that replays strictly.
""".
-endif.
-spec replay(module(), [entry()], map()) -> result().
replay(Mod, Trace, Opts) ->
    drive(Mod, Opts, {replay, Trace}).

-if(?DOCATTRS).
-doc """
Runs one seed after another and stops at the first run that does not pass. A
violation is shrunk.

`Seeds` is a list of seeds. `sweep/3` calls `run/2` once for each seed, in the
order of the list, with `seed` set to that seed. `Opts` takes the options of
`run/2` and the following options:

| Option | Default | Meaning |
|---|---|---|
| `shrink` | `true` | Shrinks the trace of a violation with `eta_shrink:shrink/3`. |
| `match` | see `eta_shrink:shrink/3` | Passed to `eta_shrink:shrink/3`. |
| `max_tests` | 500 | Passed to `eta_shrink:shrink/3`. |

A `seed` in `Opts` is ignored.

The result has the following keys:

| Key | Present | Value |
|---|---|---|
| `outcome` | always | `ok` when every seed passed. Otherwise the outcome of the first run that did not pass. |
| `runs` | always | The number of seeds that were run, the failing seed included. |
| `seed` | when a run did not pass | The seed of that run. |
| `result` | when a run did not pass | The result of `run/2` for that seed. |
| `shrunk` | for a violation, unless `shrink` is `false` | The result of `eta_shrink:shrink/3` on the trace of that run. |

A run with the outcome `{error, Reason}` also stops the sweep. `eta_shrink`
shrinks violations only, so the result has no `shrunk` key in that case.

```erlang
case eta_run:sweep(my_harness, lists:seq(1, 200), #{max_ops => 25, preload => [my_app]}) of
    #{outcome := ok} ->
        ok;
    #{outcome := {violation, V}, seed := Seed, shrunk := #{trace := Minimal, verified := true}} ->
        error({violation, V, Seed, Minimal})
end.
```

To reproduce the failure, replay the `trace` of `shrunk` with the same options
and the reported seed. If `verified` of `shrunk` is `false`, replay the `trace`
of `result`.

`sweep/3` does not call `audit/1`. A sweep that returns `ok` shows that no seed
of the list reached a violation. It does not show that the runs were
deterministic.
""".
-endif.
-spec sweep(module(), [integer()], map()) -> sweep().
sweep(Mod, Seeds, Opts) when is_atom(Mod), is_list(Seeds), is_map(Opts) ->
    RunOpts = maps:without([shrink, match, max_tests], Opts),
    sweep(Mod, Seeds, Opts, RunOpts, 0).

sweep(_Mod, [], _Opts, _RunOpts, Runs) ->
    #{outcome => ok, runs => Runs};
sweep(Mod, [Seed | Seeds], Opts, RunOpts, Runs) when is_integer(Seed) ->
    Result = run(Mod, RunOpts#{seed => Seed}),
    case maps:get(outcome, Result) of
        ok ->
            sweep(Mod, Seeds, Opts, RunOpts, Runs + 1);
        Outcome ->
            Failed = #{outcome => Outcome, runs => Runs + 1, seed => Seed, result => Result},
            case Outcome of
                {violation, _} -> shrink_failed(Mod, Failed, Opts);
                {error, _} -> Failed
            end
    end.

shrink_failed(Mod, Failed = #{seed := Seed, result := #{trace := Trace}}, Opts) ->
    case maps:get(shrink, Opts, true) of
        true ->
            ShrinkOpts = maps:remove(shrink, Opts#{seed => Seed}),
            Failed#{shrunk => eta_shrink:shrink(Mod, Trace, ShrinkOpts)};
        false ->
            Failed
    end.

-if(?DOCATTRS).
-doc """
Spawns a process that performs an operation. Call `spawn_op/1` from `execute/2`
instead of `spawn/1`.

A process from a plain `spawn/1` in `execute/2` is not deterministic:

1. The driver is not traced. `eta_sched` therefore does not adopt a process that
   the driver creates until the driver registers it.
2. Until registration, the new process runs on the real scheduler.
3. Two such processes, from operations injected close together, both send their
   first message during that time. Real time decides the order in which the
   messages arrive. The seed does not.

One such process alone is usually harmless. With two, one seed can produce two
different traces.

The process that `spawn_op/1` spawns blocks before it runs `Fun`. The process
therefore cannot act before the scheduler owns it. `eta_run` releases the process
after registration. From that point the scheduler decides when the process runs,
as for every other process.
""".
-endif.
-spec spawn_op(fun(() -> term())) -> pid().
spawn_op(Fun) ->
    eta_sched:spawn(Fun).

%% ---------------------------------------------------------------------------
%% Reading a result
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Returns a result with the `trace` key replaced by `trace_length`, the length of
the trace. Use `summary/1` to print a result.

A run with 20 operations produces a few hundred trace entries. A shell that
prints the whole result prints the trace and truncates the other fields.

```erlang
#{outcome := ok, steps := 97, trace_length := 213, modules_loaded := []} =
    eta_run:summary(eta_run:run(my_harness, #{seed => 1})).
```

`summary/1` accepts any map with a `trace` key, including a
`t:eta_shrink:result/0`. For a shrink result, `trace_length` shows which trace
the result holds:

- `trace_length` equals `shrunk` when `verified` is `true`.
- `trace_length` equals `original` when `verified` is `false`, because an
  unverified shrink returns the original trace.

To read what a run did, use `eta_log`. The trace is the input of `replay/3` and
`eta_shrink`.
""".
-endif.
-spec summary(map()) -> map().
summary(Result = #{trace := Trace}) ->
    (maps:remove(trace, Result))#{trace_length => length(Trace)}.

-if(?DOCATTRS).
-doc """
Checks whether the seed of a run reproduces the run.

```erlang
ok = eta_run:audit(eta_run:run(my_harness, Opts)).
```

Several fields of a result report that the wall clock, not the schedule, decided
a part of the interleaving. A seed does not reproduce such a run. None of these
conditions makes an invariant fail. The scheduler logs a warning for a step
time-out and for cold code. `audit/1` checks every such field, so that a caller
does not need to know the list of fields.

`audit/1` returns `ok`, or `{suspect, Reasons}` with one `{Check, Found}` pair
for each check that failed:

| Check | Result field | Expected | Meaning | Fix |
|---|---|---|---|---|
| `modules_loaded` | `modules_loaded` | `[]` | Code was loaded during the run, so a scheduled process made a synchronous call to `code_server`. | The `preload` option. |
| `cold_code` | `sched.cold_code` | `[]` | A process still waited on the code server when the run ended. The run was not quiescent, and the load finished too late to appear in `modules_loaded`. Each entry names the function that called the cold module. | The `preload` option. |
| `adopted_late` | `sched.adopted_late` | 0 | Processes ran before the scheduler owned them. | Spawn through `eta_run:spawn_op/1` and `eta_sched:spawn/1`. |
| `timeouts` | `sched.timeouts` | 0 | Steps ended before the process reached a `receive`. The scheduler suspended the process at an arbitrary point. | See `eta_sched`. |
| `stray_timers` | `stray_timers` | 0 | A process that the scheduler does not own, or a dead process, held a timer. | See `run/2`. |
| `net_unmanaged` | `net.unmanaged` | 0 | A process other than the stepped process sent a message, so the wall clock decided the time of the send. | See `eta_net`. |
| `rand_unmanaged` | `rand.unmanaged` | 0 | A process other than the stepped process drew from `rand`, so the wall clock decided the time of the draw. | See `eta_rand`. |

The return value is `{suspect, Reasons}` and not `{error, _}`, because the run
took place and a violation that it found is real. The seed is not certain to
reproduce that violation.

Assert on `audit/1` next to the invariants in every test.
""".
-endif.
-spec audit(result()) -> ok | {suspect, [{atom(), term()}]}.
audit(Result = #{modules_loaded := Modules, sched := Sched}) ->
    Net = maps:get(net, Result, #{}),
    Rand = maps:get(rand, Result, #{}),
    Checks = [
        {modules_loaded, Modules, []},
        {adopted_late, maps:get(adopted_late, Sched, 0), 0},
        {timeouts, maps:get(timeouts, Sched, 0), 0},
        %% The half of the cold-code problem `modules_loaded` cannot see: a load
        %% that had not finished when the run did. See `eta_sched:stats/1`.
        {cold_code, maps:get(cold_code, Sched, []), []},
        {stray_timers, maps:get(stray_timers, Result, 0), 0},
        %% A message that drew a delay with no clock to hang it on was delivered
        %% immediately, so the network was quieter than its policy said. Not a
        %% determinism hole — every run reaching here has a clock — but it is the
        %% same class of "the run did not do what you asked" as the rest.
        %% A send by a process other than the one being stepped, so when it landed
        %% was decided by wall clock. Nothing else in this list catches it — the
        %% run audits clean and the trace diverges anyway. See
        %% `eta_sched:stepping/0`.
        {net_unmanaged, maps:get(unmanaged, Net, 0), 0},
        %% The same failure for `rand`: a draw by a process other than the one
        %% being stepped advanced, or created, a stream at a moment wall clock
        %% chose. See `eta_rand`.
        {rand_unmanaged, maps:get(unmanaged, Rand, 0), 0}
    ],
    case [{What, Found} || {What, Found, Clean} <- Checks, Found =/= Clean] of
        [] -> ok;
        Suspect -> {suspect, Suspect}
    end.

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Writes a trace to a file as a self-contained reproduction, after checking that
the trace still reproduces.

`save_fixture/4` returns:

- `{ok, Outcome}` when the fixture was written. `Outcome` is the outcome of the
  replay.
- `{error, {did_not_replay, Reason}}` when the strict replay ended with
  `{error, Reason}`. No file is written.
- `{error, Reason}` when the file could not be written.

## Comparison with a pinned seed

A seed identifies a schedule only for one particular `generate/2`. A change to
the mix of operations changes what every pinned seed tests:

- A test that asserts a violation fails, so the change is visible.
- A test that asserts `ok` still passes and no longer tests the original
  schedule. Nothing reports the change.

A trace does not depend on `generate/2`. `replay/3` never calls `generate/2` and
draws nothing from the seed. A saved trace therefore stays valid when the
workload is rewritten or the seed changes.

- Pin a seed to test that seeds reproduce.
- Pin a trace as a regression test for a defect.

## Contents

A fixture holds the trace, the harness module, the options, the outcome and the
time of saving. The `lenient` option is not stored.

The options are stored because a reproduction depends on them. A trace that
needs `config => #{mode => broken}` does not reproduce without that option, and
`eta_shrink` then reports that there is nothing to shrink. A test that replays a
fixture cannot omit the options.

## Verification

`save_fixture/4` replays the trace strictly before it writes the file, and
stores the outcome of that replay in the fixture. Every fixture on disk
therefore reproduced at the time of saving.

Take the trace from a result of `eta_shrink:shrink/3` whose `verified` is
`true`. `eta_shrink` performs the same check for that trace.

## Limitations

- A fixture cannot show that a fix works. The replay of a failing trace against
  a fixed implementation does not return `ok`. The fix changes which messages
  exist, so the recorded step ids are no longer runnable, and the replay returns
  `{error, {diverged, _, _}}`. That a fix works is a property of the whole
  system. Test it with a sweep of seeds.
""".
-endif.
-spec save_fixture(file:name_all(), module(), [entry()], map()) ->
    {ok, outcome()} | {error, term()}.
save_fixture(Path, Mod, Trace, Opts) ->
    Result = replay(Mod, Trace, Opts#{lenient => false}),
    Outcome = maps:get(outcome, Result),
    case Outcome of
        {error, Reason} ->
            {error, {did_not_replay, Reason}};
        _ ->
            Fixture = #{
                version => ?FIXTURE_VERSION,
                harness => Mod,
                trace => Trace,
                opts => maps:remove(lenient, Opts),
                outcome => Outcome,
                saved => calendar:universal_time()
            },
            case file:write_file(Path, term_to_binary(Fixture)) of
                ok -> {ok, Outcome};
                {error, Reason} -> {error, Reason}
            end
    end.

-if(?DOCATTRS).
-doc "Reads a fixture and does not run it. Raises an error for a file that is not a readable fixture of the supported version.".
-endif.
-spec load_fixture(file:name_all()) -> fixture().
load_fixture(Path) ->
    {ok, Bin} = file:read_file(Path),
    case binary_to_term(Bin) of
        Fixture = #{version := ?FIXTURE_VERSION} -> Fixture;
        #{version := V} -> error({eta_run, {unsupported_fixture_version, V, Path}});
        _ -> error({eta_run, {not_a_fixture, Path}})
    end.

-if(?DOCATTRS).
-doc """
Replays a fixture strictly and returns the full result. The replay uses the
harness and the options that were saved with the fixture.

A test therefore needs only the name of the file:

```erlang
#{outcome := {violation, #{property := atomicity}}} =
    eta_run:replay_fixture("test/fixtures/atomicity.eta").
```
""".
-endif.
-spec replay_fixture(file:name_all()) -> result().
replay_fixture(Path) ->
    #{harness := Mod, trace := Trace, opts := Opts} = load_fixture(Path),
    replay(Mod, Trace, Opts#{lenient => false}).

-if(?DOCATTRS).
-doc """
Replays a fixture and compares the outcome with the outcome that was recorded
when the fixture was saved.

- `ok` means that the fixture still reproduces.
- `{changed, #{expected := Expected, actual := Actual}}` means that the system
  no longer produces the recorded outcome.

After a fix, the expected result is `{changed, _}`. The actual outcome is then
usually a divergence error and not `ok`. `save_fixture/4` gives the reason.
""".
-endif.
-spec check_fixture(file:name_all()) ->
    ok | {changed, #{expected := outcome(), actual := outcome()}}.
check_fixture(Path) ->
    #{outcome := Expected} = load_fixture(Path),
    case maps:get(outcome, replay_fixture(Path)) of
        Expected -> ok;
        Actual -> {changed, #{expected => Expected, actual => Actual}}
    end.

%% ---------------------------------------------------------------------------
%% Driving
%% ---------------------------------------------------------------------------

drive(Mod, Opts, Source) ->
    Seed = maps:get(seed, Opts, 0),
    ok = preload(maps:get(preload, Opts, [])),
    %% Before `init/2`, so that anything the system logs while starting up is in
    %% the record too. The driver names itself once, here, and every entry it
    %% writes from now on is tagged as the framework's rather than the system's.
    ok = start_log(maps:get(log, Opts, true)),
    ok = eta_log:label('$eta'),
    %% Before the system, always — see the module doc.
    %% The wall clock the system reads is pinned to the seed as well. Left
    %% real, a run and its replay would start at different times, and any
    %% decision derived from `os:timestamp/0` — a `rand` seeded from it, which
    %% riak_core's claimant does — would differ between them with nothing in
    %% the trace to show for it.
    ok = eta_time:start(#{seed => Seed, system_ms => ?SYSTEM_EPOCH_MS + Seed * 1000}),
    %% And the network before the system for the same reason the clock is: a
    %% policy installed after the system has started has already had the startup
    %% traffic go past it, and startup runs on the real scheduler. That is how a
    %% seeded fault schedule stops being a function of its seed. Started perfect
    %% by default, so a harness that wants faults only after its cluster has
    %% synced calls `eta_net:set_policy/1` from `init/2` rather than reseeding.
    ok = start_net(maps:get(net, Opts, false), Seed),
    %% And the simulated disk, under the same rule as the network: a run owns
    %% its lifetime, including when it wants none. See `eta_disk`.
    ok = start_disk(maps:get(disk, Opts, false), Seed),
    %% And the seeded `rand` streams, for the same reason again: a process that
    %% draws during `init/2` gets its stream from this run's seed rather than
    %% from OTP's entropy. See `eta_rand`.
    ok = eta_rand:start(#{seed => Seed}),
    try
        {ok, Sut} = Mod:init(Seed, maps:get(config, Opts, #{})),
        Sched0 = eta_sched:new(#{seed => Seed}),
        Sched = eta_sched:register(Sched0, Mod:processes(Sut)),
        %% Snapshot here rather than at the top: whatever `init/2` loaded was
        %% loaded before a scheduler existed, which is exactly where a system is
        %% supposed to warm its code path. Only what loads from *this* point is
        %% a real-clock dependency, and hoisting the register call out of the
        %% record makes the ordering explicit rather than relying on the
        %% unspecified evaluation order of record fields.
        Loaded = erlang:loaded(),
        R = #r{
            mod = Mod,
            sut = Sut,
            sched = Sched,
            loaded = Loaded,
            rand = rand:seed_s(exsss, {Seed + 11, Seed + 23, Seed + 37}),
            seed = Seed,
            budget = maps:get(max_steps, Opts, 10000),
            ops_left = maps:get(max_ops, Opts, 50),
            settle_left = maps:get(settle_steps, Opts, 2000),
            op_p = maps:get(op_p, Opts, 0.3),
            quiet_p = maps:get(quiet_p, Opts, 0.3),
            check_every = maps:get(check_every, Opts, 1),
            check_timeout = maps:get(check_timeout, Opts, ?CHECK_TIMEOUT),
            lenient = maps:get(lenient, Opts, false),
            busy_limit = maps:get(busy_steps, Opts, infinity)
        },
        %% Startup's own processes belong to no entry, and are the one set whose
        %% ids a shrink can never disturb — nothing deletes `init/2`. Dropping
        %% them here keeps them from being attributed to whatever runs first.
        _ = eta_sched:take_adopted(Sched),
        {Outcome, R1} =
            case Source of
                generate ->
                    loop(R);
                {replay, Trace} ->
                    %% A recorded run counts its ids; a replay is told them. See
                    %% `eta_sched:pin/2`.
                    ok = eta_sched:pin_mode(Sched, pinned(Trace)),
                    replay_loop(R, Trace)
            end,
        finish(Outcome, R1)
    after
        %% The network before the clock, because `in_flight/0` reads the clock to
        %% decide what has already been delivered. Both outlive `finish/2`, which
        %% is where the counters are read — the Elixir original tore its network
        %% down first and its non-vacuity guard reported zero drops on a run that
        %% had dropped plenty, a guard that failed closed only by accident.
        eta_net:stop(),
        eta_disk:stop(),
        eta_rand:stop(),
        eta_time:stop()
    end.

%% `net => false` (the default) runs with no network at all, which is exactly the
%% behaviour of every run written before there was one — and it is enforced rather
%% than assumed.
%%
%% The network is a named ETS table, so it is global to the VM and outlives
%% whoever started it. A run that merely declined to start one would still route
%% every send through a network some *earlier* test left running, under that
%% test's policy: a walkthrough that injects its faults in its own workload would
%% quietly be dropping messages as well. Stopping is also what the `after` clause
%% does on the way out, so this makes the rule symmetric — **a run owns the
%% network's lifetime**, including when it wants none.
start_net(false, _Seed) ->
    eta_net:stop();
start_net(true, Seed) ->
    start_net(#{}, Seed);
start_net(Opts, Seed) when is_map(Opts) ->
    eta_net:start(#{seed => maps:get(seed, Opts, Seed), policy => maps:get(policy, Opts, #{})}).

%% `disk => false` (the default) runs with no simulated disk: every `file` call
%% the transform rewrote delegates to `file`. `true` starts one with the default
%% policy, and a map may carry `seed` and `policy`. See `eta_disk:start/1`.
start_disk(false, _Seed) ->
    eta_disk:stop();
start_disk(true, Seed) ->
    start_disk(#{}, Seed);
start_disk(Opts, Seed) when is_map(Opts) ->
    eta_disk:start(#{seed => maps:get(seed, Opts, Seed), policy => maps:get(policy, Opts, #{})}).

%% Load every module of the named applications, before there is a scheduler to
%% be outside of.
%%
%% Loading a module on demand is a synchronous call into `code_server`, which the
%% scheduler does not own, so a scheduled process reaching a cold module blocks
%% outside the schedule and is made runnable again by wall clock. `modules_loaded`
%% reports that after the fact; this is how you stop it happening.
%%
%% It is the *only* reliable fix, because warming is per code path rather than
%% per VM. Running one seed does not warm the branch a later seed takes — a
%% workload that first reaches a timeout handler loads code no earlier seed
%% touched — so "run it twice" fixes one seed and not the next.
%%
%% Deliberately not automatic beyond the defaults. `eta_run` is handed a module,
%% not an application, so it cannot infer what to load, and loading every module
%% of every loaded application would drag in Mix, ExUnit and the whole of OTP,
%% firing any `-on_load` functions they carry.
-if(?DOCATTRS).
-doc """
Loads every module of the named applications and of `kernel`, `stdlib` and
`eta`.

`run/2` calls `preload/1` with the value of its `preload` option. `preload/1` is
exported for code that uses `eta_sched` directly. Such code has the cold code
problem of a run with `preload => false`, and has no `modules_loaded` field that
reports the problem.

- Call `preload/1` once, before the scheduler is created.
- `preload(false)` does nothing, so a caller can pass an option value unchanged.
- `preload/1` raises `{eta_run, {preload_failed, App, Reason}}` when an
  application cannot be loaded or has no module list.

An example in Elixir:

    setup_all do
      :ok = :eta_run.preload([:my_app])
    end
""".
-endif.
-spec preload([atom()] | false) -> ok.
preload(false) ->
    ok;
preload(Apps) when is_list(Apps) ->
    %% `kernel` and `stdlib` because a system under test reaches them and nobody
    %% would think to name them; `eta` because a transformed module's rewritten
    %% calls land in `eta_time` from inside a scheduled process.
    lists:foreach(fun preload_app/1, [kernel, stdlib, eta | Apps]).

preload_app(App) ->
    case application:load(App) of
        ok -> ok;
        {error, {already_loaded, App}} -> ok;
        {error, Reason} -> error({eta_run, {preload_failed, App, Reason}})
    end,
    case application:get_key(App, modules) of
        {ok, Modules} ->
            _ = code:ensure_modules_loaded(Modules),
            ok;
        undefined ->
            %% Loaded but with no module list, which means the `.app` is not
            %% what it claims to be. Silently preloading nothing is exactly the
            %% failure this option exists to prevent.
            error({eta_run, {preload_failed, App, no_modules}})
    end.

%% `log => false` for a run that does not want the record. `stamps` rather than
%% `stop`, so `eta_log:log/1` keeps returning real sequence numbers: a harness is
%% told to stamp its operations from them, and stamps that all read 0 would make
%% any "A finished before B started" invariant vacuous without saying so.
%%
%% Either way the previous run's log is discarded, so `analyze/0` cannot quietly
%% show you an older story.
start_log(false) -> eta_log:trace(stamps);
start_log(true) -> eta_log:trace(start).

%% The generated run. One action per iteration, invariants after each.
loop(R = #r{budget = 0}) ->
    {{error, step_budget_exhausted}, R};
%% Every operation is in and the settle budget is spent: a normal end.
%%
%% A system with periodic timers never reaches "nothing runnable and nothing
%% pending" — a replication heartbeat and a prune timer see to that, so an idle
%% cluster produces work forever and the only other terminal state is
%% the safety bound. Ending on a bounded settle phase makes quiescence-by-timer a
%% success rather than a budget error, and the phase is not dead time: it is where
%% the invariants get checked with no client traffic, which is the only way the
%% quiet-period defects are reachable at all.
loop(R = #r{ops_left = 0, settle_left = 0}) ->
    final(settle_budget, R);
loop(R = #r{busy = Busy, busy_limit = Limit}) when Busy >= Limit ->
    busy(R);
loop(R = #r{sched = Sched, ops_left = OpsLeft}) ->
    case OpsLeft =:= 0 andalso settle_done(R) of
        true -> final(settle_done, R);
        false -> loop_step(R, eta_sched:runnable(Sched), OpsLeft)
    end.

%% `busy_steps` steps have passed without the clock moving: it moves now, to the
%% next deadline, as though those steps had taken the time.
%%
%% Time here passes only when nothing is runnable, which is right for a system
%% that waits and wrong for one that spins. A client that retries the moment it
%% is turned away keeps something runnable forever, so the timer that would end
%% the spin never fires, and the run spends its budget at one instant. On a real
%% machine the spin costs time like anything else, and timers fire through it.
%% Recorded as a `clock` entry like any other advance, so a replay takes it in
%% the same place.
busy(R = #r{sched = Sched, trace = Trace}) ->
    case eta_time:advance_to_next(schedulable(Sched)) of
        true ->
            Now = eta_time:now_ms(),
            _ = eta_log:log({clock, Now}),
            Created = eta_sched:take_adopted(Sched),
            loop(spend(R#r{trace = [entry(clock, Now, Created) | Trace]}));
        false ->
            %% Nothing pending: spinning is all there is, and the budget will say so.
            loop(R#r{busy = 0})
    end.

loop_step(R, Runnable, OpsLeft) ->
    case choose(R, Runnable, OpsLeft > 0) of
        {step, Id, R1} -> after_action(do_step(R1, Id));
        {op, R1} -> after_action(do_op(R1));
        {idle, R1} -> idle(R1)
    end.

%% Whether the harness says its settle phase has what it was waiting for. See
%% `eta_harness`. Not asked during a replay, which ends where its trace's `final`
%% entry says the run ended.
settle_done(#r{mod = Mod, sut = Sut}) ->
    erlang:function_exported(Mod, settle_done, 1) andalso Mod:settle_done(Sut) =:= true.

%% What to do next. See the module doc on why the nothing-runnable case is the
%% interesting one.
choose(R, [], false) ->
    {idle, R};
choose(R, [], true) ->
    case roll(R) of
        {P, R1} when P < R1#r.quiet_p -> {idle, R1};
        {_, R1} -> {op, R1}
    end;
choose(R, Runnable, false) ->
    pick_step(R, Runnable);
choose(R, Runnable, true) ->
    case roll(R) of
        {P, R1} when P < R1#r.op_p -> {op, R1};
        {_, R1} -> pick_step(R1, Runnable)
    end.

pick_step(R = #r{rand = Rand}, Runnable) ->
    {I, Rand1} = rand:uniform_s(length(Runnable), Rand),
    {step, lists:nth(I, Runnable), R#r{rand = Rand1}}.

roll(R = #r{rand = Rand}) ->
    {P, Rand1} = rand:uniform_s(Rand),
    {P, R#r{rand = Rand1}}.

%% Nothing is runnable: only the clock can produce more work. If it cannot, and
%% there are no operations left to inject, the run is over — that is quiescence,
%% and it is the normal way a run ends.
%%
%% **Letting time pass is an action, and it goes in the trace.** It was left out at
%% first on the reasoning that the clock is a function of the timers and the timers
%% are a function of the schedule, so a replay would advance in the same places by
%% itself. It does not: `replay_loop/2` only walks the entries it is given, so a
%% recorded run of a system with timers replayed against a clock that never moved.
%% Nothing became runnable, every recorded step was refused, and a strict replay
%% failed on entry 0 — which reads as a scheduling divergence and is nothing of the
%% sort. On a timer-driven system it made `eta_shrink` a no-op: the shrinker replays
%% original trace to classify it, got a clean run, and reported "nothing to shrink"
%% for a failure that had just happened.
idle(R = #r{ops_left = OpsLeft, sched = Sched, trace = Trace}) ->
    case eta_time:advance_to_next(schedulable(R#r.sched)) of
        true ->
            Now = eta_time:now_ms(),
            _ = eta_log:log({clock, Now}),
            %% A timer firing can start a process — `eta_sched` adopts one that
            %% appears between steps rather than leaving it unsupervised — so a
            %% clock entry carries its creations like any other.
            Created = eta_sched:take_adopted(Sched),
            loop(spend(R#r{trace = [entry(clock, Now, Created) | Trace]}));
        false when OpsLeft > 0 ->
            %% `quiet_p` chose to let time pass and there was no time to pass.
            after_action(do_op(R));
        false ->
            %% Nothing runnable and no deadline that could make anything
            %% runnable. This is the strong ending, and the only one a
            %% `check_final/2` may read as proof rather than as evidence.
            final(quiescent, R)
    end.

%% The last thing a normally-ending run does. A budget error skips it, because a
%% run that hit the safety bound was still going and has no final state to judge;
%% so does a violation, which has already ended the run and would otherwise be
%% overwritten by a second verdict about a system that stopped early.
%% **How the run ended goes in the trace**, for the reason `idle/1` records its
%% clock entries: a replay walks the entries it is given and cannot re-derive
%% this one. Whether a *replayed* run would have stopped by quiescence or by
%% budget is not a question its trace answers, and guessing would let a replay
%% return a different verdict from the run it is reproducing.
final(Settled, R = #r{mod = Mod, sut = Sut, trace = Trace}) ->
    _ = eta_log:log({final, Settled}),
    R1 = R#r{trace = [{final, Settled} | Trace]},
    do_final(Mod, Settled, Sut, R1).

do_final(Mod, Settled, Sut, R) ->
    case erlang:function_exported(Mod, check_final, 2) of
        false ->
            {ok, R};
        true ->
            case safe_check_final(Mod, Settled, Sut, R#r.check_timeout) of
                ok -> {ok, R};
                Other -> {Other, R}
            end
    end.

%% The log entry goes in *before* the step runs, so that everything the chosen
%% process records lands underneath it. That ordering is what makes the log read
%% as "the scheduler picked r2, and here is what r2 then did".
do_step(R = #r{sched = Sched, trace = Trace, steps = Steps}, Id) ->
    _ = eta_log:log({step, Id}),
    %% `step_adopting/2` rather than a step and a separate question about what it
    %% created: one round trip, for the reason that function documents.
    {_Outcome, Created, _} = eta_sched:step_adopting(Sched, Id),
    spend(R#r{trace = [entry(step, Id, Created) | Trace], steps = Steps + 1}).

do_op(R) ->
    #r{mod = Mod, sut = Sut, rand = Rand} = R,
    {Op, Rand1} = Mod:generate(Sut, Rand),
    apply_op(R#r{rand = Rand1}, Op).

apply_op(R, Op) ->
    #r{mod = Mod, sut = Sut, sched = Sched, trace = Trace, ops = Ops} = R,
    _ = eta_log:log({op, Op}),
    Sut1 = Mod:execute(Op, Sut),
    %% An operation is issued by spawning; pick up whatever it created. Already
    %% known pids are ignored, so re-registering the whole set is correct.
    %% Registering is also what lets them run: a gated child gets its token from
    %% the scheduler, and registering is the route when the parent — here, the
    %% driver — is not traced. See `spawn_op/1`.
    %%
    %% `register_adopting/2` because *who* it created is recorded too, so that a
    %% replay can give those processes the same ids without recounting — the whole
    %% reason deleting an operation no longer renames the survivors. See
    %% `eta_sched:pin/2`.
    {Sched1, Created} = eta_sched:register_adopting(Sched, Mod:processes(Sut1)),
    spend(R#r{
        sut = Sut1,
        sched = Sched1,
        trace = [entry(op, Op, Created) | Trace],
        ops = Ops + 1,
        ops_left = R#r.ops_left - 1
    }).

spend(R = #r{trace = [{clock, _} | _]}) ->
    spend1(R#r{busy = 0});
spend(R = #r{trace = [{clock, _, _} | _]}) ->
    spend1(R#r{busy = 0});
spend(R = #r{busy = Busy}) ->
    spend1(R#r{busy = Busy + 1}).

spend1(R = #r{budget = B, since_check = N, ops_left = 0, settle_left = S}) ->
    R#r{budget = B - 1, since_check = N + 1, settle_left = max(0, S - 1)};
spend1(R = #r{budget = B, since_check = N}) ->
    R#r{budget = B - 1, since_check = N + 1}.

%% Invariants, every `check_every` actions.
after_action(R = #r{check_every = Every, since_check = N}) when N < Every ->
    loop(R);
after_action(R = #r{mod = Mod, sut = Sut, check_timeout = Timeout}) ->
    case safe_check(Mod, Sut, Timeout) of
        ok -> loop(R#r{since_check = 0});
        {violation, _} = V -> {V, R};
        {error, _} = E -> {E, R}
    end.

%% ---------------------------------------------------------------------------
%% Replay
%% ---------------------------------------------------------------------------

replay_loop(R, []) ->
    {ok, R};
replay_loop(R = #r{budget = 0}, _) ->
    {{error, step_budget_exhausted}, R};
%% Every entry starts by telling the scheduler which ids the processes this entry
%% creates are to be given. That is what stops a deletion elsewhere in the trace
%% from renaming them: an id means "the process the trace called 7", not "the
%% seventh process this replay happened to adopt". See `eta_sched:pin/2`.
replay_loop(R = #r{sched = Sched}, [Entry | Rest]) ->
    ok = pin(Sched, created(Entry)),
    replay_entry(R, action(Entry), Rest).

%% Most entries create nobody, and the scheduler empties the supply as it closes
%% each entry, so for those there is nothing to say and no message worth sending.
pin(_Sched, []) -> ok;
pin(Sched, Created) -> eta_sched:pin(Sched, Created).

replay_entry(R = #r{sched = Sched, lenient = Lenient, skipped = Skipped}, {step, Id}, Rest) ->
    case lists:member(Id, eta_sched:runnable(Sched)) of
        true ->
            replay_after(do_step(R, Id), Rest);
        false when Lenient ->
            %% Shrinking asks a different question: not "does this trace replay?"
            %% but "does what is left of it still fail?". Removing an operation
            %% necessarily strands the steps that belonged to it, so a strict
            %% replay would answer `diverged` for almost every candidate and the
            %% shrinker would learn nothing. Skipping lets the rest of the
            %% schedule apply.
            replay_loop(R#r{skipped = Skipped + 1}, Rest);
        false ->
            %% The recorded schedule and this run have parted company. Reporting
            %% it beats continuing, which would produce a "replay" that is not one.
            {{error, {diverged, Id, eta_sched:runnable(Sched)}}, R}
    end;
replay_entry(R, {op, Op}, Rest) ->
    replay_after(apply_op(R, Op), Rest);
%% The recorded ending. Replayed rather than re-derived, so a `check_final/2`
%% sees the same `Settled` it saw in the run being reproduced — otherwise a
%% harness that trusts `quiescent` and not `settle_budget` could answer
%% differently for the same schedule. Last entry either way, so nothing follows.
replay_entry(R = #r{mod = Mod, sut = Sut, trace = Trace}, {final, Settled}, _Rest) ->
    do_final(Mod, Settled, Sut, R#r{trace = [{final, Settled} | Trace]});
%% Time passed here. The recorded `Ms` is what the clock read *after* the advance,
%% and a strict replay holds the replay to it: landing somewhere else means the timer
%% wheel is not the one that was recorded, which is a divergence however faithfully
%% the steps line up. Lenient replay takes whatever advance is available, for the same
%% reason it skips an unrunnable step — a shrink candidate has had entries removed,
%% so its wheel is legitimately not the original's.
replay_entry(R = #r{lenient = Lenient, skipped = Skipped, trace = Trace}, {clock, Ms}, Rest) ->
    %% The same schedulability rule `idle/1` used to record the entry. Replaying
    %% under a laxer one would advance to a deadline the generating run stepped
    %% over, so a trace from a system carrying a stray timer would not replay.
    case eta_time:advance_to_next(schedulable(R#r.sched)) of
        true ->
            Now = eta_time:now_ms(),
            case Lenient orelse Now =:= Ms of
                true ->
                    _ = eta_log:log({clock, Now}),
                    Created = eta_sched:take_adopted(R#r.sched),
                    replay_after(
                        spend(R#r{trace = [entry(clock, Now, Created) | Trace]}), Rest
                    );
                false ->
                    {{error, {clock_diverged, Ms, Now}}, R}
            end;
        false when Lenient ->
            replay_loop(R#r{skipped = Skipped + 1}, Rest);
        false ->
            {{error, {clock_diverged, Ms, no_timer}}, R}
    end.

replay_after(R = #r{check_every = Every, since_check = N}, Rest) when N < Every ->
    replay_loop(R, Rest);
replay_after(R = #r{mod = Mod, sut = Sut, check_timeout = Timeout}, Rest) ->
    case safe_check(Mod, Sut, Timeout) of
        ok -> replay_loop(R#r{since_check = 0}, Rest);
        {violation, _} = V -> {V, R};
        {error, _} = E -> {E, R}
    end.

%% ---------------------------------------------------------------------------
%% Entries
%% ---------------------------------------------------------------------------

%% An entry carries a third element only when it created somebody. Most entries
%% create nobody, and a trace whose every line reads `{step, 3, []}` costs the one
%% thing a trace is read for. The two shapes mean the same thing everywhere except
%% `pinned/1`, which is asking a question about the trace as a whole.
-spec entry(op | step | clock, term(), created()) -> entry().
entry(Tag, Payload, []) -> {Tag, Payload};
entry(Tag, Payload, Created) -> {Tag, Payload, Created}.

-if(?DOCATTRS).
-doc """
Returns the action of an entry without the ids of the processes that the entry
created: `{op, Op}`, `{step, Id}`, `{clock, Ms}` or `{final, Settled}`.

Match on the result of `action/1` and not on the entry. An entry that created
processes has a third element, and an entry that created none has two elements:

```erlang
Ops = [Op || E <- Trace, {op, Op} <- [eta_run:action(E)]].
```
""".
-endif.
-spec action(entry()) -> tuple().
action({Tag, Payload, _Created}) -> {Tag, Payload};
action(Entry) -> Entry.

-if(?DOCATTRS).
-doc """
Returns the ids of the processes that an entry created, oldest first. Returns
`[]` for an entry that created none.

A replay uses these ids to give each created process the id that it had in the
recorded run. A shrunk trace therefore names the same processes as the original
trace. See `eta_sched:pin/2`. The function is for diagnosis. No caller needs to
write the ids.
""".
-endif.
-spec created(entry()) -> created().
created({_Tag, _Payload, Created}) -> Created;
created(_Entry) -> [].

%% Whether this trace knows who created whom, decided once for the whole trace
%% rather than per entry. An entry with no created-ids is ambiguous alone: it
%% means "created nobody" in a recorded trace and "recorded before there was such
%% a thing" in one written by hand or by an older build. Treating the second as the
%% first would give every process in such a trace a `{fresh, _}` id and nothing
%% would replay, so the presence of *any* creation is what turns pinning on. A
%% trace that created nothing after startup replays identically either way.
-spec pinned([entry()]) -> boolean().
pinned(Trace) ->
    lists:any(fun(Entry) -> tuple_size(Entry) =:= 3 end, Trace).

%% ---------------------------------------------------------------------------
%% Invariants
%% ---------------------------------------------------------------------------

%% `erlang:loaded/0` rather than `code:all_loaded/0`: it is a BIF returning bare
%% module names, where the latter builds `{Module, Filename}` pairs and may go
%% through the code server — which is precisely the process this is here to
%% catch traffic to.
-spec loaded_since([module()]) -> [module()].
loaded_since(Before) ->
    Known = maps:from_keys(Before, []),
    lists:sort([M || M <- erlang:loaded(), not is_map_key(M, Known)]).

%% Two sources, joined against the scheduler's id-to-pid map here so that neither
%% one has to think in ids. A process that labelled itself wins: it is the source
%% closest to the truth, and letting the harness override it is how one process
%% ends up under 2 names in the same report.
%%
%% Both are optional. A run where nobody names anything gets `p0`, `p1` and so on.
collect_labels(Mod, Sut, Sched) ->
    ByPid = maps:merge(harness_labels(Mod, Sut), eta_log:self_labels()),
    maps:fold(
        fun(Id, Pid, Acc) ->
            case maps:find(Pid, ByPid) of
                {ok, Name} -> Acc#{Id => Name};
                error -> Acc
            end
        end,
        #{},
        eta_sched:procs(Sched)
    ).

%% Wrapped because this runs during teardown, after a run that may already have
%% failed: a harness whose labelling crashes should not turn a reported violation
%% into a teardown error.
harness_labels(Mod, Sut) ->
    case erlang:function_exported(Mod, labels, 1) of
        false ->
            #{};
        true ->
            case catch Mod:labels(Sut) of
                Map when is_map(Map) -> Map;
                _ -> #{}
            end
    end.

%% Bounded, and in a process of its own, so a `check/1` that calls into a
%% suspended process is reported rather than hanging the run. It cannot catch the
%% worse case — a client API that swallows its own timeout and answers plausibly,
%% making the invariant vacuous — which is why `eta_harness` says what it says.
%% Same bounding as `safe_check/2`, and for the same reason: a callback that
%% blocks on a suspended process must not take the run with it. The system is
%% still frozen here — `finish/2` has not released the scheduler yet — so the
%% rule that `check/1` may not talk to it holds for this one too.
safe_check_final(Mod, Settled, Sut, Timeout) ->
    {Pid, MRef} =
        spawn_monitor(fun() -> exit({checked, catch Mod:check_final(Settled, Sut)}) end),
    collect_check(Pid, MRef, Timeout).

safe_check(Mod, Sut, Timeout) ->
    {Pid, MRef} = spawn_monitor(fun() -> exit({checked, catch Mod:check(Sut)}) end),
    collect_check(Pid, MRef, Timeout).

collect_check(Pid, MRef, Timeout) ->
    receive
        {'DOWN', MRef, process, Pid, {checked, ok}} ->
            ok;
        {'DOWN', MRef, process, Pid, {checked, {violation, _} = V}} ->
            V;
        {'DOWN', MRef, process, Pid, {checked, Other}} ->
            {error, {check_returned, Other}};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {check_crashed, Reason}}
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        {error, check_blocked}
    end.

%% ---------------------------------------------------------------------------
%% Teardown
%% ---------------------------------------------------------------------------

finish(Outcome, R) ->
    #r{mod = Mod, sut = Sut, sched = Sched, trace = Trace} = R,
    %% `eta_sched:run/3` makes this check when it ends. This module steps the
    %% scheduler itself, so it asks for the check at the end of the run. A
    %% process that waits on `code_server` now is then in `sched.cold_code`.
    _ = eta_sched:check_cold_code(Sched),
    Stats = eta_sched:stats(Sched),
    ClockMs = eta_time:now_ms(),
    Strays = eta_time:strays(),
    %% While both the network and the clock are still up — `in_flight` is a
    %% question about the wheel, not just a counter.
    Net = net_stats(),
    Disk = disk_stats(),
    Rand = eta_rand:stats(),
    %% Before `release/1` and `terminate/1`, so that teardown's own loading is
    %% not blamed on the run.
    Modules = loaded_since(R#r.loaded),
    %% Names, now and not before. Ids are handed out as processes register, so
    %% the mapping does not exist until the run is over, and only the harness can
    %% supply it — with its own state in hand. Doing it here keeps every callback
    %% off the hot path.
    ok = eta_log:register_labels(collect_labels(Mod, Sut, Sched)),
    %% Everything logged after this ran on the *real* scheduler, because
    %% `release/1` resumes every suspended process. It is real, it is
    %% nondeterministic, and it is not part of the run. `eta_log` hides it by
    %% default and can only do so because of this marker.
    _ = eta_log:log(released),
    %% Release before terminate: the system has to be running again before it can
    %% be shut down, or terminate/1 waits on processes that cannot answer.
    ok = eta_sched:release(Sched),
    catch Mod:terminate(Sut),
    #{
        outcome => Outcome,
        seed => R#r.seed,
        trace => lists:reverse(Trace),
        steps => R#r.steps,
        ops => R#r.ops,
        clock_ms => ClockMs,
        skipped => R#r.skipped,
        modules_loaded => Modules,
        stray_timers => Strays,
        net => Net,
        disk => Disk,
        rand => Rand,
        sched => Stats
    }.

%% `#{}` for a run with no network, which is what makes `net` safe to read
%% unconditionally and what tells a reader "none was installed" rather than
%% "none of these things happened".
net_stats() ->
    case eta_net:running() of
        true -> eta_net:stats();
        false -> #{}
    end.

%% `#{}` for a run with no simulated disk, as `net_stats/0` is for the network.
disk_stats() ->
    case eta_disk:running() of
        true -> eta_disk:stats();
        false -> #{}
    end.

%% Whether a deadline addressed to `Dest` can produce a scheduling event.
%%
%% Two conditions, and both are load-bearing. The process has to be one the
%% scheduler owns, because a deadline for anything else moves the clock on behalf
%% of something that can never take a step. And it has to be **alive**, because
%% `eta_sched:procs/1` deliberately remembers processes that have exited so that a
%% trace can name one — a dead owner's timer is exactly the stray this guards
%% against, not a reason to advance.
schedulable(Sched) ->
    Owned = maps:from_keys(maps:values(eta_sched:procs(Sched)), []),
    fun(Dest) -> is_map_key(resolve_dest(Dest), Owned) andalso alive(Dest) end.

resolve_dest(Pid) when is_pid(Pid) -> Pid;
resolve_dest(Name) when is_atom(Name) -> whereis(Name).

alive(Pid) when is_pid(Pid) -> is_process_alive(Pid);
alive(Name) when is_atom(Name) -> whereis(Name) =/= undefined.
