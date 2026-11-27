-module(eta_sched).
-behaviour(gen_server).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

%% `register/2` is deliberately the API name; it shadows the auto-imported BIF,
%% which is never used here.
-compile({no_auto_import, [register/2, spawn/1, spawn/3, spawn_link/1, spawn_link/3]}).

-if(?DOCATTRS).
-moduledoc """
A scheduler that runs one BEAM process at a time.

The scheduler owns a set of scheduled processes and keeps each of them
suspended. A step resumes one scheduled process, waits until the process blocks
in a `receive`, and suspends the process again. The sequence of stepped
processes is the choice sequence. `run/2` draws the choice sequence from a
seeded random number generator. `replay/2` repeats a recorded choice sequence.
The design is described in `docs/design.md`.

The scheduler uses only pids, message queues and trace events. It does not
depend on what the scheduled processes do.

## Example

```erlang
Sched = eta_sched:new(#{seed => 42}),
eta_sched:register(Sched, [Ping, Pong]),
gen_server:cast(Ping, {ping, 3}),
eta_sched:run(Sched, 1000),
Choices = eta_sched:choices(Sched),
#{adopted_late := 0, timeouts := 0, cold_code := []} = eta_sched:stats(Sched),
ok = eta_sched:release(Sched).
```

To repeat the run, start the same system again, register the same processes in
the same order, and call `eta_sched:replay(Sched, Choices)` in place of `run/2`.

## Model

The scheduler does not intercept messages. Erlang delivers the messages between
one ordered pair of processes in send order. When only one process runs at a
time, the order in which messages are delivered follows from the order of the
steps. The choice sequence therefore determines the interleaving of the system.

The scheduler is a `gen_server` process:

- The scheduler is the tracer of every scheduled process. Trace events arrive
  in the mailbox of the scheduler. The messages that the system under test sends
  to the driver arrive in the mailbox of the driver.
- A `receive` for trace events in the process of the driver could consume a
  `gen_server` reply that is addressed to the driver. A separate scheduler
  process removes that defect. Every `receive` that waits for a trace event
  also matches only trace messages.
- A driver that waits on a predicate, such as `eta_run`, alternates steps with
  checks of the system under test. The driver needs a mailbox that the scheduler
  does not read.
- The scheduler is not a scheduled process. The system under test does not call
  the scheduler process, so the scheduler does not need to be scheduled.
- One VM runs one scheduler at a time.

`sched()` is a handle to the scheduler process:

- A function that takes a `sched()` and returns a `sched()` returns the same
  handle.
- A handle does not hold a state of the run. Stepping an earlier handle again
  does not repeat a run, because the scheduled processes have already run.
- `release/1` stops the scheduler. Call `choices/1` and `stats/1` before
  `release/1`.

## Steps

A step does the following, in this order:

1. It reads the queue length of the process.
2. It resumes the process.
3. It waits for the `in` trace event of the process. A process that is blocked
   in a `receive` has the status `waiting` before the process has run. The
   status is therefore valid only after the `in` event.
4. It waits for an `out` trace event after which the status is `waiting` or the
   process is dead. An `out` event with any other status is a preemption. With
   the status `waiting`, the step calls `erlang:trace_delivered/1` and
   continues to wait if an `in` event follows the `out` event. The process then
   ran on after the `out` event and blocked before the status read. The step
   also continues to wait if the current function of the process is in the
   module `erlang` or `erts_internal`, other than `erlang:hibernate/3`. The
   process then waits for an answer of the VM inside a call such as
   `erlang:garbage_collect/1`, and not for a message of the system.
5. It suspends the process and collects the pending trace events with
   `erlang:trace_delivered/1`.
6. It records `blocked_at`, the queue length at which the process blocked. See
   "Runnability".

A step has one of three outcomes:

| Outcome | Meaning |
|---|---|
| `progress` | The process consumed at least 1 message. |
| `no_progress` | The process blocked and consumed no message. |
| `exited` | The process exited. |

The number of consumed messages is the sum of two numbers, minus the queue
length at the block:

- The queue length before the step.
- The number of messages that the process sent to itself during the step.

The `'receive'` trace event does not measure consumption. The VM produces the
event when a message enters the queue, whether or not a `receive` later matches
the message.

A step that does not reach a `receive` ends in a time-out. See "Limitations".

## Runnability

A scheduled process is runnable when the process has not exited and its queue
is longer than `blocked_at`. `blocked_at` is the queue length at the moment the
process last blocked. A process with no recorded block has a `blocked_at` of 0,
so a process with an empty queue is not runnable.

A `receive` blocks only after it has failed to match every queued message. The
messages that remain after a step are therefore known not to match. The
consequences are:

- `blocked_at` is recorded after every step that ends in a block.
- A process that consumed 1 message and blocked on the rest is not runnable
  until a new message arrives.
- A new message that does not match makes the process runnable for 1 step. That
  step has the outcome `no_progress` and records the new `blocked_at`.

The status `waiting` with an empty queue is not a correct test for the end of a
step. A process that is blocked in

```erlang
receive {reply, Ref, V} -> V end
```

with a queued message that does not match has the status `waiting` and a queue
that is not empty. Every `gen_server:call/3` produces this state. A scheduler
that treats such a process as runnable steps it without end, and the run never
reaches the state in which no process is runnable.

A message can arrive after the block and before the scheduler reads the queue.
An example is a process that kills another scheduled process and waits for the
`DOWN` message. The killed process dies at once although it is suspended, and
its `EXIT` and `DOWN` messages arrive in real time. `queue_at_block/3` subtracts
the messages that arrived after the block. It uses the `'receive'` trace events
that follow the blocking `out` event. When the queue is empty, the result is 0
and no further check is made.

`settled_runnable/1` runs at every choice. It scans only the processes that
have not exited, and it reads each queue length once, with
`process_info(Pid, message_queue_len)`. The read returns `undefined` for a dead
process, so no separate read of the status is needed.

### Deaths outside a step

A process that does not trap exits dies when the VM handles an exit signal for
the process. The VM does that also while the scheduler holds the process
suspended. The signal has one of two causes:

- A linked process exits. The death continues along a chain of links.
- A process calls `erlang:exit/2` on the process.

The dead process then sends the signals of its own links and monitors, at a
time that the VM chooses. The scheduler settles these deaths at three points:

| Point | What the scheduler does |
|---|---|
| The end of a step in which the process exited | Settles before the step returns. |
| The end of a step in which the process called `erlang:exit/2` | Settles before the step ends. The `EXIT` and `DOWN` messages of the deaths are in the queue of the process, and the process runs on in the same step if it waits for one of them. |
| Every choice | Settles before it reads which processes are runnable. This covers an `erlang:exit/2` outside a step, such as one by `eta_net:kill_node/2`. |

To settle, the scheduler repeats two actions until the second one finds no
dead process:

1. It waits for the `out_exited` trace event of every process that has started
   to exit. The VM sends the signals of the links and the monitors of a process
   before this event.
2. It reads every live scheduled process with `process_info/2`. The read makes
   the process handle the signals that it has received.

The scheduler learns of a call to `erlang:exit/2` from a `call` trace event.
It sets a trace pattern on `erlang:exit/2` for that purpose, so the module
that makes the call does not need `eta_transform`.

## Adoption

The scheduler adopts a process when it starts to own the process. An adopted
process is traced, is suspended and has an id. A process is adopted in one of
three ways:

| Way | Time of adoption | Counted in `adopted_late` |
|---|---|---|
| `register/2` | At the call. | No |
| A gated spawn or start, such as `spawn/1` or `start_link/3` | Before the child runs. The child starts blocked on a token, and the scheduler sends the token after it has adopted the child. | No |
| A spawn by code that `eta_transform` did not rewrite | After the child has started, through `set_on_spawn` tracing. | Yes |

A child that is adopted late runs on the BEAM scheduler until the scheduler
suspends it. A child that exits before it is suspended is adopted as exited, so
the assignment of ids does not depend on that race.

`eta_transform` points the spawn and start calls of a transformed module at the
gated functions of this module. With no scheduler running, each gated function
delegates to the function that it replaces. A transformed module therefore
behaves normally outside a simulation.

## Process ids

The scheduler gives every adopted process an id. The choice sequence records
ids and not pids, because the pids of two runs differ.

| Id | Assigned to |
|---|---|
| A non-negative integer, counted in adoption order | A process of a run without pinning. |
| An id from the trace | A process of a pinned replay. See `pin/2`. |
| `{fresh, N}` | A process that a pinned replay adopts when no pinned id remains. See `pin_mode/2`. |

## Statistics

`stats/1` returns the statistics of a run. Four fields report a loss of
determinism: `adopted_late`, `timeouts`, `ran_on` and `cold_code`.

## Determinism

A seed reproduces a run only when `stats/1` reports all of the following:

| Field | Required value | Meaning of any other value | Correction |
|---|---|---|---|
| `adopted_late` | 0 | A child ran before the scheduler suspended it. | Build the spawning module with `eta_transform`, or instrument it. |
| `timeouts` | 0 | A step was suspended at a point that the real clock chose. | None. The run is not replayable. |
| `ran_on` | 0 | A process ran on after its step had ended as a block, woken by something outside the schedule. | Point the call that waits on a process the scheduler does not own at a function that works in the calling process, as `eta_transform` does for `file`. |
| `cold_code` | `[]` | A process waited on `code_server` when a run ended. | Call `eta_run:preload/1`. |

## Limitations

- **Real-clock timers.** `eta_transform` puts `receive ... after N` on the
  virtual clock by default. Two kinds of module wake from `receive ... after N`
  on the real clock: a module that declares `-eta_after(false)`, and a module
  that is not built with `eta_transform`. A system with such a module must use
  `infinity` in a simulation.
- **Late adoption.** `set_on_spawn` tracing reports a spawn after the child
  exists. A child that is spawned with `erlang:spawn/1` therefore runs on the
  BEAM scheduler before the scheduler suspends it. A run with a high
  `adopted_late` has an interleaving that partly depends on the real clock.
- **Step time-outs.** A step ends in a time-out when the process does not reach
  a `receive`. The conditions are listed below. The scheduler then suspends the
  process where it is, logs a warning and adds 1 to `timeouts`. The scheduler
  does not record `blocked_at` for that step, and the process stays runnable
  while it is alive, whatever its queue.
- **Wake-ups from outside the schedule.** A process that waits on a process the
  scheduler does not own, such as `file_server_2`, can get its answer while the
  scheduler confirms the block, and run on after its step ended. The scheduler
  sees it from the process's trace events after the step, logs a warning, adds
  1 to `ran_on` and keeps the process runnable, as after a time-out. A process
  that ran on and blocked again in the same function is not seen.
- **Pid order.** The term order of pids is their creation order only until
  the VM has created about as many processes as its process limit
  (`erlang:system_info(process_limit)`, 1,048,576 by default). After that the
  VM reuses pid values. Measured on Erlang/OTP 28 with `+S 1`: the process
  number 1,048,490 after the start of the VM was the first with a pid below
  the pid of its predecessor. A system or a harness that sorts pids, or that
  keeps pids as keys of an ordered structure, then has a schedule that depends
  on how many processes the VM created before the run. The scheduler does not
  prevent this. It counts the children whose pid compares below the pid of an
  earlier child in `pid_reuse`. The corrections are a new VM for each group of
  runs, and an order that does not use pids, such as the ids of `ids/1`.
- **Cold code.** A process that calls a module that is not loaded makes a
  synchronous call to `code_server`, which the scheduler does not own. The
  scheduler cannot distinguish that process from a process that is blocked in a
  `receive`. If no other process is runnable, the run ends early and reports no
  failure. `run/3` records such processes in `cold_code` when it ends, and
  `check_cold_code/1` records them on request.
- **One scheduler per VM.** A second scheduler fails to start while the first
  one runs. Runs must be serial.

A step ends in a time-out under one of these conditions:

- The process is still suspended when a wait of 5 ms for a trace event ends.
  The resume had no effect.
- The awaited trace event does not arrive during 200 waits of 5 ms each, while
  the process is alive and not suspended.
- The scheduler handles 100000 trace events without the awaited event, or the
  process is scheduled out 100000 times without blocking.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    new/0,
    new/1,
    register/2,
    register_adopting/2,
    release/1,
    ids/1,
    procs/1,
    runnable/1,
    pin/2,
    pin_mode/2,
    take_adopted/1,
    step/2,
    step_adopting/2,
    run/1,
    run/2,
    run/3,
    replay/2,
    choices/1,
    stats/1,
    check_cold_code/1,
    pid/1
]).

%% Scheduler-owned spawning — what `eta_transform` points a system's `spawn` calls
%% at. `gated/1,3` are exported because they are spawned by MFA, which is what
%% makes a gated child distinguishable in the spawn trace event.
-export([
    active/0,
    current/0,
    stepping/0,
    spawn/1, spawn/3,
    spawn_link/1, spawn_link/3,
    spawn_monitor/1, spawn_monitor/3,
    spawn_opt/2, spawn_opt/4,
    gated/1, gated/3
]).

%% Client functions eta cannot gate yet — Elixir's `Task` and `Agent`, which
%% spawn and wait inside the Elixir stdlib. Raise while a scheduler is active,
%% delegate otherwise. See `unsupported/2`.
-export([unsupported/2, instrumented/1]).

%% `erlang:is_process_alive/1` for a system under simulation. See `is_alive/1`.
-export([is_alive/1]).

%% Yield points. See `yield/0`, `preempt/0` and `timeout_return/1`.
-export([yield/0, preempt/0, preempted/1, timeout_return/1]).

%% The distributed forms. Between simulated nodes they spawn on the named node;
%% anywhere else they raise while a run is active. See `dist/5`.
-export([
    spawn/2, spawn/4,
    spawn_link/2, spawn_link/4,
    spawn_monitor/2, spawn_monitor/4,
    spawn_opt/3, spawn_opt/5,
    plib_spawn/2, plib_spawn/4,
    plib_spawn_link/2, plib_spawn_link/4,
    plib_spawn_opt/3, plib_spawn_opt/5
]).

%% The `proc_lib` flavours, which additionally give the child the OTP process
%% dictionary entries. See `plib_spawn/1`.
-export([
    plib_spawn/1, plib_spawn/3,
    plib_spawn_link/1, plib_spawn_link/3,
    plib_spawn_opt/2, plib_spawn_opt/4,
    plib_start/3, plib_start/4, plib_start/5,
    plib_start_link/3, plib_start_link/4, plib_start_link/5,
    plib_start_monitor/3, plib_start_monitor/4, plib_start_monitor/5,
    gen_start/5, gen_start/6,
    gated_plib/2, gated_plib/4
]).

%% Gated `gen_server` starts — see `start_monitor/3`. `gated/5` is spawned by MFA
%% for the same reason `gated/1,3` are: the spawn trace event has to name it.
-export([
    start_monitor/3, start_monitor/4,
    start_link/3, start_link/4,
    start/3, start/4,
    gated/5
]).

%% The same for `gen_statem`. Separate entry points rather than a behaviour
%% argument, because the two differ in every step after the token: `init/1`
%% returns a different shape, and the loop is entered through a different
%% function. See `statem_start_link/3`.
-export([
    statem_start_monitor/3, statem_start_monitor/4,
    statem_start_link/3, statem_start_link/4,
    statem_start/3, statem_start/4,
    statem_gated/5
]).

%% And for `gen_fsm`, which has no `start_monitor` and enters its loop through
%% `gen_fsm:enter_loop/4,5`. See `fsm_start_link/3`.
-export([
    fsm_start_link/3, fsm_start_link/4,
    fsm_start/3, fsm_start/4,
    fsm_gated/5
]).

-compile(
    {nowarn_deprecated_function, [
        {gen_fsm, start, 3},
        {gen_fsm, start, 4},
        {gen_fsm, start_link, 3},
        {gen_fsm, start_link, 4},
        {gen_fsm, enter_loop, 4},
        {gen_fsm, enter_loop, 5}
    ]}
).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([sched/0, id/0, outcome/0, cold/0]).

%% `running` gives the in/out scheduling events quiescence is detected from.
%% `send` lets a step count self-sends, the correction term consumption needs.
%% `procs` + `set_on_spawn` adopt processes the system under test creates.
%% `exiting` gives the `out_exited` event, which a process produces after it has
%% sent the signals of its links and monitors. `call` gives an event for each
%% call to `erlang:exit/2`, which is the only function with a trace pattern
%% that the scheduler sets. See `settle/1`.
-define(TRACE_FLAGS, [running, exiting, 'receive', send, procs, call, set_on_spawn]).

%% Bound on waiting for the `exit` or the `out_exited` trace event of a process
%% that is dead.
-define(EXITED_TIMEOUT, 5000).

%% A step should never take this many scheduling events; bailing out beats hanging
%% a test suite on a process that never blocks.
-define(MAX_EVENTS_PER_STEP, 100000).

%% How long to wait for a scheduling event before looking at the process to see
%% whether one is still coming. Only paid when the event has not landed yet; the
%% common path returns the moment it does.
-define(EVENT_POLL, 5).

%% How many of those polls before giving up on an event entirely.
%%
%% This used to be a single 5ms deadline, and that was a determinism hole in the
%% middle of the machinery that exists to remove them. A trace event delayed past
%% 5ms by a loaded machine or a GC pause made the scheduler conclude the process
%% would never run, suspend it wherever it happened to be, and carry on — so the
%% suspension point was chosen by wall clock. Nothing reported it.
%%
%% Polling instead makes the wait a question about the process rather than about
%% the clock: keep waiting while it is alive and not suspended, since the event
%% is then either in flight or imminent. The bound survives only to stop a
%% genuinely wedged process hanging a test suite, which is why it is generous.
-define(EVENT_PATIENCE, 200).

%% Bound on waiting for erlang:trace_delivered/1 to report the trace stream drained.
-define(DELIVERED_TIMEOUT, 5000).

%% Bound on re-reading a held process's queue while messages are still arriving
%% after its block. See `queue_at_block/3`.
-define(LATE_SETTLE_ROUNDS, 5).

%% Presence of this table means a scheduler is running, so `spawn/1` and friends
%% gate their children. Created by the scheduler process and destroyed with it, so
%% the inertness is automatic — the same arrangement `eta_time` uses.
-define(ACTIVE, eta_sched_active).

%% What releases a gated child once the scheduler owns it.
-define(GO, '$eta_sched_go').

%% What resumes a process that yielded. See `yield/0`.
-define(YIELD_GO, '$eta_sched_yield_go').

%% A plain integer for a process the scheduler named itself, counting in adoption
%% order. `{fresh, N}` for one adopted during a *pinned* replay that its trace did
%% not account for — a separate space, so that a process the trace never named can
%% never be mistaken for one it did. See `pin/2`.
-type id() :: non_neg_integer() | {fresh, non_neg_integer()}.
-type outcome() :: progress | no_progress | exited.
-opaque sched() :: {eta_sched, pid()}.

%% One process caught waiting on the code server at quiescence. `at` is the
%% frame in the system under test that reached the cold module, which is the fact
%% that tells you what to preload.
%%
%% `undefined` when there is no such frame to read, which is not rare and is
%% worth knowing about: a **tail call** into a cold module leaves nothing on the
%% stack but the loading machinery itself. The `pid` is still the answer then —
%% `erlang:process_info(Pid, initial_call)` and the process's own label say who
%% it is, and the application it belongs to is the one to preload.
-type cold() :: #{id := id(), pid := pid(), at := mfa() | undefined}.

-record(st, {
    rand :: rand:state(),
    %% id => pid, and the reverse. Ids are stable across runs (assignment order is
    %% a function of the schedule), pids are not — so choices are recorded as ids.
    %% Stable across *edits* to a trace only under `pin/2`, which is what shrinking
    %% needs and why it exists.
    procs = #{} :: #{id() => pid()},
    ids = #{} :: #{pid() => id()},
    next_id = 0 :: id(),
    %% id => queue length at which this process was found blocked.
    blocked_at = #{} :: #{id() => non_neg_integer()},
    exited = #{} :: #{id() => true},
    %% id => pid for every process not yet known to have exited. `procs` keeps
    %% every process a run ever registered, and in a system that spawns a
    %% process per operation nearly all of them have exited. `settled_runnable/1`
    %% runs at every choice point, so it reads this map instead: its cost then
    %% depends on how many processes are alive, not on how long the run is.
    %% Updated only through `adopt/2` and `mark_exited/2`.
    live = #{} :: #{id() => pid()},
    %% Processes with an `exit` trace event and no `out_exited` trace event
    %% yet. Such a process may not have sent the signals of its links and
    %% monitors. See `settle/1`.
    dying = #{} :: #{pid() => true},
    %% Whether the process of the step in progress has called `erlang:exit/2`.
    %% See `settle_in_step/3`.
    exit_sent = false :: boolean(),
    %% The function of the last `in` or `out` event of the step in progress that
    %% the scheduler waited for, and the first other function in which the
    %% process was scheduled in or out after the step ended. See `do_drain/5`.
    last_mfa :: mfa() | undefined,
    ran_into :: mfa() | undefined,
    %% The last message that the process of the step sent, and to whom: the
    %% call that a process that ran on was waiting for. See `note_quiescence/5`.
    last_send :: {term(), term()} | undefined,
    %% Children spawned through `spawn/1` and friends, which start blocked. Tracked
    %% so `release/1` can let go of any that never got their token.
    gated = #{} :: #{pid() => true},
    %% Processes blocked in `yield/0`. A yielded process is runnable, and the
    %% step that resumes it sends it ?YIELD_GO. See `yield/0`.
    yielded = #{} :: #{id() => true},
    %% Processes whose last step ended in a time-out, suspended mid-step. Such a
    %% process is runnable while it is alive, whatever its queue. See
    %% `note_quiescence/5`.
    mid_step = #{} :: #{id() => true},
    %% Id assignment when a trace is driving. `supply` is what the entry now
    %% executing is expected to create, `adopted` is what it actually created, and
    %% `pinning` says which well an unexpected adoption draws from. See `pin/2`.
    supply = [] :: [id()],
    adopted = [] :: [id()],
    pinning = false :: boolean(),
    fresh = 0 :: non_neg_integer(),
    choices = [] :: [id()],
    adopted_late = 0 :: non_neg_integer(),
    %% Steps that ended without the process reaching a receive. See
    %% `note_quiescence/5`; any nonzero value means the run is not replayable.
    timeouts = 0 :: non_neg_integer(),
    %% Steps that ended as a block, after which the process ran on. See
    %% `note_running/2`; any nonzero value means the run is not replayable.
    ran_on = 0 :: non_neg_integer(),
    %% The highest pid among the children seen so far, and the number of
    %% children whose pid compares below it. See `note_pid_order/2`.
    pid_high :: pid() | undefined,
    pid_reuse = 0 :: non_neg_integer(),
    %% Processes found parked in `code_server` at the moment a run gave up. See
    %% `note_cold_code/1`; any entry means the run's quiescence was a lie.
    cold_code = [] :: [cold()],
    steps = 0 :: non_neg_integer()
}).

%% A step is internally bounded (?MAX_EVENTS_PER_STEP, ?EVENT_PATIENCE,
%% ?DELIVERED_TIMEOUT) and a run is bounded by MaxSteps, so the call cannot hang
%% for reasons a caller-side timeout would diagnose better than the bounds do.
-define(CALL_TIMEOUT, infinity).

%% ---------------------------------------------------------------------------
%% Lifecycle
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "Starts a scheduler with the default seed, which is 0. See `new/1`.".
-endif.
-spec new() -> sched().
new() ->
    new(#{}).

-if(?DOCATTRS).
-doc """
Starts a scheduler process and returns a handle to it.

`Opts` has 2 keys:

- `seed`: an integer that determines the choices of `run/2`. The default is 0.
- `preempt`: the probability, from 0.0 to 1.0, that `preempt/0` yields. The
  default is 0.0. See `preempt/0`.

The scheduler is linked to the caller. When the driver exits, the scheduler
exits and the suspensions that the scheduler holds end. The system under test
then runs without a scheduler and does not stay suspended.

One VM runs one scheduler at a time. A second scheduler fails to start with the
reason `{eta_sched, {scheduler_in_use, Owner, Hint}}`.
""".
-endif.
-spec new(#{seed => integer(), preempt => float()}) -> sched().
new(Opts) ->
    case maps:get(preempt, Opts, 0.0) of
        P when is_number(P), P >= 0, P =< 1 -> ok;
        Bad -> error({eta_sched, {bad_preempt, Bad, <<"expected a number from 0.0 to 1.0">>}})
    end,
    {ok, Pid} = gen_server:start_link(?MODULE, Opts, []),
    {eta_sched, Pid}.

-if(?DOCATTRS).
-doc "Returns the pid of the scheduler process, for a test that asserts on that process.".
-endif.
-spec pid(sched()) -> pid().
pid({eta_sched, Pid}) ->
    Pid.

-if(?DOCATTRS).
-doc """
Adopts a process or a list of processes. The scheduler traces each process,
suspends it and gives it an id.

Register every process of the system before any of them runs. Otherwise the run
starts from a state that the scheduler did not choose.

- A process that is already adopted is skipped.
- A process that has exited is skipped.
- A gated process that has not been sent its token is sent the token.

Returns the same handle.
""".
-endif.
-spec register(sched(), pid() | [pid()]) -> sched().
register(S, Pids) ->
    call(S, {register, Pids}),
    S.

-if(?DOCATTRS).
-doc """
Resumes every scheduled process, stops tracing and stops the scheduler.

The system then runs without a scheduler. The handle is invalid after the call.
Call `choices/1` and `stats/1` before `release/1`.

`release/1` does the following, in this order:

1. It makes `active/0` return `false`. A start that a resumed process makes
   afterwards therefore delegates to OTP. A gated start at that point would wait
   for a token that is never sent.
2. It sends the token to every gated child that still waits for it.
3. It stops tracing and resumes every scheduled process that is alive.
4. It stops the scheduler process.
""".
-endif.
-spec release(sched()) -> ok.
release(S = {eta_sched, Pid}) ->
    call(S, release),
    gen_server:stop(Pid),
    ok.

%% ---------------------------------------------------------------------------
%% Scheduler-owned spawning
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Returns whether a scheduler is running in this VM. When no scheduler is running,
`spawn/1` and the other gated functions delegate to the functions that they
replace.
""".
-endif.
-spec active() -> boolean().
active() ->
    ets:info(?ACTIVE, name) =/= undefined.

-if(?DOCATTRS).
-doc """
Returns the pid of the process that the scheduler is stepping, or `undefined`
when no step is in progress.

During a step, the returned process is the only scheduled process that runs.
Every other scheduled process is suspended. A side effect that another process
causes during a step is ordered by the real clock and not by the seed.

`undefined` does not mean that an action is outside the schedule. Between steps
the driver runs. An operation that a harness injects between steps is recorded
in the trace.

The value is read from an ETS table and not from the scheduler process. The
scheduler is a `gen_server` that is busy during a step, so a call to the
scheduler from the stepped process would deadlock.
""".
-endif.
-spec stepping() -> pid() | undefined.
stepping() ->
    try ets:lookup(?ACTIVE, stepping) of
        [{stepping, Pid}] -> Pid;
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

-if(?DOCATTRS).
-doc """
Returns the handle of the scheduler that is running in this VM, or `undefined`.

Use this function in code that is given no `sched()`. An example is an invariant
that holds only when the system is quiescent. The replicas of a registry agree
only after speculation settles. `check/1` is given the system under test and not
the schedule. The invariant calls `runnable/1` on the returned handle to
distinguish a system that has diverged from a system that is still working.

An invariant can call this function safely. The scheduler is not a scheduled
process, so it is never suspended. `runnable/1` only reads state.
""".
-endif.
-spec current() -> sched() | undefined.
current() ->
    try ets:lookup(?ACTIVE, sched) of
        [{sched, S}] -> S;
        [] -> undefined
    catch
        error:badarg -> undefined
    end.

-if(?DOCATTRS).
-doc """
Replaces `erlang:spawn/1` for a system under simulation. The child starts gated:
it blocks on a token and runs only after the scheduler has adopted it.

`spawn/3`, `spawn_link/1,3`, `spawn_monitor/1,3` and `spawn_opt/2,4` gate their
children in the same way. `eta_transform` points the spawn calls of a
transformed module at these functions.

A gated spawn proceeds as follows:

1. The child blocks in a `receive` for the token before it runs any other code.
2. The scheduler reads the spawn trace event and suspends the child.
3. The scheduler adopts the child and sends the token.
4. The child is runnable and is stepped like any other scheduled process.

A gated child is not counted in the `adopted_late` field of `stats/1`.

Adoption through `set_on_spawn` tracing alone is not sufficient. The trace event
arrives after the child exists. Until the scheduler handles the event, the child
runs on the BEAM scheduler, and the real clock orders what the child does. In a
port of a distributed registry, 1212 of the 1233 processes of a run were adopted
late, because that system spawns a short-lived helper for almost every
operation. A seed did not reproduce its schedule.

The child is spawned by module, function and arguments, not as a fun. The spawn
trace event then carries `{eta_sched, gated, _}`, and the scheduler identifies a
gated child by that value. `gated_plib`, `statem_gated` and `fsm_gated` are
identified in the same way. A new gated entry point must be added to
`is_gated/1` and to `handle_trace/2`. Otherwise its children wait for a token
that is never sent.

With no scheduler running, the function delegates to `erlang:spawn/1`. A
transformed module therefore behaves normally outside a simulation.
""".
-endif.
-spec spawn(fun(() -> term())) -> pid().
spawn(Fun) ->
    case active() of
        false -> erlang:spawn(Fun);
        true -> erlang:spawn(?MODULE, gated, [Fun])
    end.

-spec spawn(module(), atom(), [term()]) -> pid().
spawn(M, F, A) ->
    case active() of
        false -> erlang:spawn(M, F, A);
        true -> erlang:spawn(?MODULE, gated, [M, F, A])
    end.

-spec spawn_link(fun(() -> term())) -> pid().
spawn_link(Fun) ->
    case active() of
        false -> erlang:spawn_link(Fun);
        true -> erlang:spawn_link(?MODULE, gated, [Fun])
    end.

-spec spawn_link(module(), atom(), [term()]) -> pid().
spawn_link(M, F, A) ->
    case active() of
        false -> erlang:spawn_link(M, F, A);
        true -> erlang:spawn_link(?MODULE, gated, [M, F, A])
    end.

-spec spawn_monitor(fun(() -> term())) -> {pid(), reference()}.
spawn_monitor(Fun) ->
    case active() of
        false -> erlang:spawn_monitor(Fun);
        true -> erlang:spawn_monitor(?MODULE, gated, [Fun])
    end.

-spec spawn_monitor(module(), atom(), [term()]) -> {pid(), reference()}.
spawn_monitor(M, F, A) ->
    case active() of
        false -> erlang:spawn_monitor(M, F, A);
        true -> erlang:spawn_monitor(?MODULE, gated, [M, F, A])
    end.

%% The options are passed straight through, so `link`, `monitor`, heap sizes and
%% the rest keep their meanings — including the return shape, which is a bare pid
%% unless `monitor` is asked for.
-spec spawn_opt(fun(() -> term()), list()) -> pid() | {pid(), reference()}.
spawn_opt(Fun, Opts) ->
    case active() of
        false -> erlang:spawn_opt(Fun, Opts);
        true -> erlang:spawn_opt(?MODULE, gated, [Fun], Opts)
    end.

-spec spawn_opt(module(), atom(), [term()], list()) -> pid() | {pid(), reference()}.
spawn_opt(M, F, A, Opts) ->
    case active() of
        false -> erlang:spawn_opt(M, F, A, Opts);
        true -> erlang:spawn_opt(?MODULE, gated, [M, F, A], Opts)
    end.

%% ---------------------------------------------------------------------------
%% proc_lib flavours
%% ---------------------------------------------------------------------------

%% `proc_lib`'s spawns differ from `erlang`'s in one way that matters: the child
%% gets `$ancestors` and `$initial_call`, without which it is not an OTP process
%% and `sys` cannot introspect it. Routing them through the plain gated spawn
%% would drop that, so these carry it, and the inert path stays inside `proc_lib`
%% rather than falling through to `erlang`.
-spec plib_spawn(fun(() -> term())) -> pid().
plib_spawn(Fun) ->
    case active() of
        false -> proc_lib:spawn(Fun);
        true -> erlang:spawn(?MODULE, gated_plib, [Fun, plib_ctx(Fun)])
    end.

-spec plib_spawn(module(), atom(), [term()]) -> pid().
plib_spawn(M, F, A) ->
    case active() of
        false -> proc_lib:spawn(M, F, A);
        true -> erlang:spawn(?MODULE, gated_plib, [M, F, A, plib_ctx(M, F, A)])
    end.

-spec plib_spawn_link(fun(() -> term())) -> pid().
plib_spawn_link(Fun) ->
    case active() of
        false -> proc_lib:spawn_link(Fun);
        true -> erlang:spawn_link(?MODULE, gated_plib, [Fun, plib_ctx(Fun)])
    end.

-spec plib_spawn_link(module(), atom(), [term()]) -> pid().
plib_spawn_link(M, F, A) ->
    case active() of
        false -> proc_lib:spawn_link(M, F, A);
        true -> erlang:spawn_link(?MODULE, gated_plib, [M, F, A, plib_ctx(M, F, A)])
    end.

-spec plib_spawn_opt(fun(() -> term()), list()) -> pid() | {pid(), reference()}.
plib_spawn_opt(Fun, Opts) ->
    case active() of
        false -> proc_lib:spawn_opt(Fun, Opts);
        true -> erlang:spawn_opt(?MODULE, gated_plib, [Fun, plib_ctx(Fun)], Opts)
    end.

-spec plib_spawn_opt(module(), atom(), [term()], list()) -> pid() | {pid(), reference()}.
plib_spawn_opt(M, F, A, Opts) ->
    case active() of
        false -> proc_lib:spawn_opt(M, F, A, Opts);
        true -> erlang:spawn_opt(?MODULE, gated_plib, [M, F, A, plib_ctx(M, F, A)], Opts)
    end.

%% `proc_lib:start/3,4,5`, `start_link/3,4,5` and `start_monitor/3,4,5`.
%%
%% `proc_lib` spawns the child itself, inside OTP, so it is adopted with nothing
%% in its mailbox and nothing ever makes it runnable: the parent waits for an ack
%% from a child that never runs a line. Spawned here instead, gated like any
%% other start (see `plib_spawn_opt/4`), and waited for the way `proc_lib`'s own
%% `sync_start/2` waits, with a timeout on the virtual clock.
-spec plib_start(module(), atom(), [term()]) -> term().
plib_start(M, F, A) -> plib_start(M, F, A, infinity).

-spec plib_start(module(), atom(), [term()], timeout()) -> term().
plib_start(M, F, A, T) -> plib_start(M, F, A, T, []).

-spec plib_start(module(), atom(), [term()], timeout(), list()) -> term().
plib_start(M, F, A, T, Opts) ->
    case gate_start() of
        false -> proc_lib:start(M, F, A, T, Opts);
        true -> plib_sync(plib_gated(M, plain, [monitor | Opts], F, A), T)
    end.

-spec plib_start_link(module(), atom(), [term()]) -> term().
plib_start_link(M, F, A) -> plib_start_link(M, F, A, infinity).

-spec plib_start_link(module(), atom(), [term()], timeout()) -> term().
plib_start_link(M, F, A, T) -> plib_start_link(M, F, A, T, []).

-spec plib_start_link(module(), atom(), [term()], timeout(), list()) -> term().
plib_start_link(M, F, A, T, Opts) ->
    case gate_start() of
        false -> proc_lib:start_link(M, F, A, T, Opts);
        true -> plib_sync(plib_gated(M, link, [link, monitor | Opts], F, A), T)
    end.

-spec plib_start_monitor(module(), atom(), [term()]) -> term().
plib_start_monitor(M, F, A) -> plib_start_monitor(M, F, A, infinity).

-spec plib_start_monitor(module(), atom(), [term()], timeout()) -> term().
plib_start_monitor(M, F, A, T) -> plib_start_monitor(M, F, A, T, []).

-spec plib_start_monitor(module(), atom(), [term()], timeout(), list()) -> term().
plib_start_monitor(M, F, A, T, Opts) ->
    case gate_start() of
        false ->
            proc_lib:start_monitor(M, F, A, T, Opts);
        true ->
            {_Pid, Ref} = Started = plib_gated(M, monitor, [monitor | Opts], F, A),
            {plib_sync(Started, T, keep), Ref}
    end.

%% `gen:start/5,6`, the start every behaviour built on `gen` goes through:
%% `gen_server` and `gen_statem` inside OTP, and libraries' own behaviours such as
%% `gen_batch_server`. `gen` spawns with `proc_lib` inside OTP, so the child
%% would never run (see `plib_start/5`), and registers a local name in the VM's
%% namespace rather than the node's. Here the child is gated, and runs `gen`'s own
%% `init_it` with the name already in the caller's namespace (see `eta_ns`).
%%
%% `{global, _}` and `{via, _, _}` register through a process outside the
%% schedule, and are refused, as `register_name/1` refuses them.
-spec gen_start(module(), atom(), term(), module(), term(), list()) -> term().
gen_start(GenMod, LinkP, Name, Mod, Args, Opts) ->
    case gate_start() of
        false ->
            gen:start(GenMod, LinkP, Name, Mod, Args, Opts);
        true ->
            case server_name(Name) of
                {local, N} = Real ->
                    case erlang:whereis(N) of
                        undefined -> gen_spawn(GenMod, LinkP, [Real, Mod, Args, Opts], Opts);
                        Pid -> {error, {already_started, Pid}}
                    end;
                Other ->
                    {error, {?MODULE, unsupported_server_name, Other}}
            end
    end.

-spec gen_start(module(), atom(), module(), term(), list()) -> term().
gen_start(GenMod, LinkP, Mod, Args, Opts) ->
    case gate_start() of
        false -> gen:start(GenMod, LinkP, Mod, Args, Opts);
        true -> gen_spawn(GenMod, LinkP, [Mod, Args, Opts], Opts)
    end.

%% `gen:do_spawn/5,6`, through the gated `proc_lib` starts.
gen_spawn(GenMod, link, Rest, Opts) ->
    plib_start_link(
        gen, init_it, [GenMod, self(), self() | Rest], gen_timeout(Opts), gen_spawn_opts(Opts)
    );
gen_spawn(GenMod, monitor, Rest, Opts) ->
    case
        plib_start_monitor(
            gen, init_it, [GenMod, self(), self() | Rest], gen_timeout(Opts), gen_spawn_opts(Opts)
        )
    of
        {{ok, Pid}, Mon} when is_pid(Pid) ->
            {ok, {Pid, Mon}};
        {Error, Mon} ->
            receive
                {'DOWN', Mon, process, _, _} -> ok
            end,
            Error
    end;
gen_spawn(GenMod, _Nolink, Rest, Opts) ->
    plib_start(
        gen, init_it, [GenMod, self(), self | Rest], gen_timeout(Opts), gen_spawn_opts(Opts)
    ).

gen_timeout(Opts) -> proplists:get_value(timeout, Opts, infinity).
gen_spawn_opts(Opts) -> proplists:get_value(spawn_opt, Opts, []).

plib_gated(M, Kind, Opts, F, A) ->
    ok = assert_stepping(M, Kind),
    plib_spawn_opt(M, F, A, Opts).

plib_sync(Started, T) -> plib_sync(Started, T, drop).

%% `proc_lib:sync_start/2`. A start monitor keeps its monitor; the others drop it.
plib_sync({Pid, Ref}, Timeout, Monitor) ->
    Tag = make_ref(),
    TRef =
        case eta_time:running() of
            true -> eta_time:arm_after(Timeout, Tag);
            false -> undefined
        end,
    Real =
        case TRef of
            undefined -> Timeout;
            _ -> infinity
        end,
    Result =
        receive
            {ack, Pid, Return} ->
                _ = Monitor =:= drop andalso erlang:demonitor(Ref, [flush]),
                Return;
            {nack, Pid, Return} ->
                flush_exit(Pid),
                await_down(Pid, Ref),
                Return;
            {'DOWN', Ref, process, Pid, Reason} ->
                flush_exit(Pid),
                {error, Reason};
            {'$eta_after', G} when G =:= Tag ->
                plib_timeout(Pid, Ref)
        after Real ->
            plib_timeout(Pid, Ref)
        end,
    ok = eta_time:disarm_after(TRef, Tag),
    Result.

plib_timeout(Pid, Ref) ->
    true = exit(Pid, kill),
    flush_exit(Pid),
    await_down(Pid, Ref),
    {error, timeout}.

flush_exit(Pid) ->
    receive
        {'EXIT', Pid, _} -> ok
    after 0 -> ok
    end.

await_down(Pid, Ref) ->
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.

%% ---------------------------------------------------------------------------
%% The distributed forms
%% ---------------------------------------------------------------------------

%% `spawn(Node, Fun)` and its relatives ask for a process on another node.
%%
%% **Between simulated nodes they are simulated**, the way `eta_rpc` simulates an
%% `rpc`: the child is an ordinary gated spawn here, placed on `Node`, so its
%% `node()` is `Node`, its names are `Node`'s, and it dies with `Node`. As in
%% distribution the spawn connects the two nodes first. If it cannot — a node
%% that was killed, or one across a cut — the child still comes back as a pid,
%% and exits `noconnection` as soon as it runs, which is how a spawn to an
%% unreachable node looks to a caller that links to or monitors it.
%%
%% A spawn to the caller's own node is a local spawn.
%%
%% Anywhere else — a caller on no simulated node, or a `Node` the network has
%% never heard of — there is still no honest rewrite: running the child here
%% would silently put it on the wrong node, and letting it through would put it
%% outside the schedule. So while a run is active those raise, which turns a
%% system that cannot be simulated into a loud failure at the call rather than a
%% quiet loss of determinism 200 steps later. With no run in progress they
%% delegate, so a module built with the transform still works normally outside a
%% simulation.
%%
%% `spawn_opt`'s `monitor` and `link` options are the VM's own, as they are for
%% the local forms, so a cut does not fire them. Monitor with `erlang:monitor/2`,
%% which the transform points at `eta_net`, when a partition has to be seen.
spawn(N, F) ->
    dist(N, {erlang, spawn, 2}, {fn, F}, fun spawn_body/1, fun() -> erlang:spawn(N, F) end).

spawn(N, M, F, A) ->
    dist(N, {erlang, spawn, 4}, {mfa, M, F, A}, fun spawn_body/1, fun() ->
        erlang:spawn(N, M, F, A)
    end).

spawn_link(N, F) ->
    dist(N, {erlang, spawn_link, 2}, {fn, F}, fun spawn_link_body/1, fun() ->
        erlang:spawn_link(N, F)
    end).

spawn_link(N, M, F, A) ->
    dist(N, {erlang, spawn_link, 4}, {mfa, M, F, A}, fun spawn_link_body/1, fun() ->
        erlang:spawn_link(N, M, F, A)
    end).

spawn_monitor(N, F) ->
    dist(N, {erlang, spawn_monitor, 2}, {fn, F}, fun spawn_monitor_body/1, fun() ->
        erlang:spawn_monitor(N, F)
    end).

spawn_monitor(N, M, F, A) ->
    dist(N, {erlang, spawn_monitor, 4}, {mfa, M, F, A}, fun spawn_monitor_body/1, fun() ->
        erlang:spawn_monitor(N, M, F, A)
    end).

spawn_opt(N, F, O) ->
    dist(N, {erlang, spawn_opt, 3}, {fn, F}, fun(B) -> spawn_opt_body(B, O) end, fun() ->
        erlang:spawn_opt(N, F, O)
    end).

spawn_opt(N, M, F, A, O) ->
    dist(N, {erlang, spawn_opt, 5}, {mfa, M, F, A}, fun(B) -> spawn_opt_body(B, O) end, fun() ->
        erlang:spawn_opt(N, M, F, A, O)
    end).

plib_spawn(N, F) ->
    dist(N, {proc_lib, spawn, 2}, {fn, F}, fun plib_spawn_body/1, fun() -> proc_lib:spawn(N, F) end).

plib_spawn(N, M, F, A) ->
    dist(N, {proc_lib, spawn, 4}, {mfa, M, F, A}, fun plib_spawn_body/1, fun() ->
        proc_lib:spawn(N, M, F, A)
    end).

plib_spawn_link(N, F) ->
    dist(N, {proc_lib, spawn_link, 2}, {fn, F}, fun plib_spawn_link_body/1, fun() ->
        proc_lib:spawn_link(N, F)
    end).

plib_spawn_link(N, M, F, A) ->
    dist(N, {proc_lib, spawn_link, 4}, {mfa, M, F, A}, fun plib_spawn_link_body/1, fun() ->
        proc_lib:spawn_link(N, M, F, A)
    end).

plib_spawn_opt(N, F, O) ->
    dist(N, {proc_lib, spawn_opt, 3}, {fn, F}, fun(B) -> plib_spawn_opt_body(B, O) end, fun() ->
        proc_lib:spawn_opt(N, F, O)
    end).

plib_spawn_opt(N, M, F, A, O) ->
    dist(
        N,
        {proc_lib, spawn_opt, 5},
        {mfa, M, F, A},
        fun(B) -> plib_spawn_opt_body(B, O) end,
        fun() ->
            proc_lib:spawn_opt(N, M, F, A, O)
        end
    ).

%% The local gated form each distributed form becomes, applied to a body.
spawn_body({fn, F}) -> ?MODULE:spawn(F);
spawn_body({mfa, M, F, A}) -> ?MODULE:spawn(M, F, A).
spawn_link_body({fn, F}) -> ?MODULE:spawn_link(F);
spawn_link_body({mfa, M, F, A}) -> ?MODULE:spawn_link(M, F, A).
spawn_monitor_body({fn, F}) -> ?MODULE:spawn_monitor(F);
spawn_monitor_body({mfa, M, F, A}) -> ?MODULE:spawn_monitor(M, F, A).
spawn_opt_body({fn, F}, O) -> ?MODULE:spawn_opt(F, O);
spawn_opt_body({mfa, M, F, A}, O) -> ?MODULE:spawn_opt(M, F, A, O).
plib_spawn_body({fn, F}) -> ?MODULE:plib_spawn(F);
plib_spawn_body({mfa, M, F, A}) -> ?MODULE:plib_spawn(M, F, A).
plib_spawn_link_body({fn, F}) -> ?MODULE:plib_spawn_link(F);
plib_spawn_link_body({mfa, M, F, A}) -> ?MODULE:plib_spawn_link(M, F, A).
plib_spawn_opt_body({fn, F}, O) -> ?MODULE:plib_spawn_opt(F, O);
plib_spawn_opt_body({mfa, M, F, A}, O) -> ?MODULE:plib_spawn_opt(M, F, A, O).

-type body() :: {fn, fun()} | {mfa, module(), atom(), [term()]}.
-spec dist(
    term(),
    {module(), atom(), arity()},
    body(),
    fun((body()) -> pid() | {pid(), reference()}),
    fun(() -> pid() | {pid(), reference()})
) -> pid() | {pid(), reference()}.
dist(Node, MFA, Body, Spawn, Delegate) ->
    case eta_net:local_node() of
        undefined ->
            no_dist(active(), MFA, Delegate);
        Node ->
            %% Where the parent is and as faultable, as the scheduler would place
            %% it on adoption — said here as well because with no scheduler
            %% running nothing adopts it.
            Result = Spawn(Body),
            ok = eta_net:inherit(self(), child(Result)),
            Result;
        _Here ->
            case eta_net:is_node(Node) of
                false ->
                    no_dist(active(), MFA, Delegate);
                true ->
                    Run =
                        case eta_net:connect_node(Node) of
                            true -> Body;
                            _ -> {mfa, erlang, exit, [noconnection]}
                        end,
                    Result = Spawn(Run),
                    ok = eta_net:place(Node, [child(Result)]),
                    Result
            end
    end.

child({Pid, _Ref}) -> Pid;
child(Pid) -> Pid.

no_dist(false, _MFA, Delegate) ->
    Delegate();
no_dist(true, MFA, _Delegate) ->
    error(
        {eta_sched,
            {no_distribution, MFA,
                <<"eta simulates distribution only between simulated nodes; place the caller and the target with eta_net">>}}
    ).

%% `M:F(A, B)` becomes `eta_sched:unsupported({M, F, 2}, [A, B])`, for the
%% functions `eta_transform`'s `?SCHED_UNSUPPORTED` lists — Elixir's `Task` and
%% `Agent`, whose spawns and waits happen inside the Elixir stdlib. The
%% scheduler cannot gate a process the stdlib creates, so it would run outside
%% the schedule; a `Task.await/2` is a `receive ... after` in a module no
%% transform touched, so its wait would sit on the real clock. Same position
%% `no_dist/3` takes on the distributed spawns and `eta_net:unsupported/2`
%% takes on the unroutable sends, for the same reason: there is no honest
%% local substitute, and letting the call through would mean a run reporting
%% determinism it does not have. A module `Eta.Beam.instrument/1` has rewritten
%% no longer has the hazard, so its calls go through; see `instrumented/1`.
%%
%% Gated on `active()` rather than on a network, because the hazard is the
%% scheduler's — a run without a network still cannot afford an ungated spawn.
-spec unsupported({module(), atom(), arity()}, [term()]) -> term().
unsupported({M, F, _A} = MFA, Args) ->
    case active() andalso not persistent_term:get({?MODULE, instrumented, M}, false) of
        false ->
            apply(M, F, Args);
        true ->
            error(
                {eta_sched,
                    {unsupported, MFA, <<
                        "this function spawns or waits inside the Elixir standard "
                        "library, where the scheduler cannot gate it: a process it "
                        "created would run outside the schedule, and a wait would "
                        "sit on the real clock. Spawn through spawn/1 or a "
                        "gen_server/gen_statem start instead"
                    >>}}
            )
    end.

%% Records modules `Eta.Beam.instrument/1` has rewritten. The hazard behind
%% `unsupported/2` is that a module's spawns and waits sit where no transform
%% reaches; once the module itself has been rewritten they do not, and its calls
%% go through.
-spec instrumented([module()]) -> ok.
instrumented(Mods) ->
    lists:foreach(fun(M) -> persistent_term:put({?MODULE, instrumented, M}, true) end, Mods).

%% Computed in the *parent*, because `$ancestors` is the parent's list with the
%% parent on the front and the child cannot see it.
plib_ctx(Fun) ->
    {module, M} = erlang:fun_info(Fun, module),
    {name, N} = erlang:fun_info(Fun, name),
    {arity, A} = erlang:fun_info(Fun, arity),
    {[self() | own_ancestors()], {M, N, A}}.

plib_ctx(M, F, A) ->
    {[self() | own_ancestors()], {M, F, length(A)}}.

-if(?DOCATTRS).
-doc false.
-endif.
-spec gated(fun(() -> term())) -> term().
gated(Fun) ->
    _ = wait_for_token(),
    Fun().

-if(?DOCATTRS).
-doc false.
-endif.
-spec gated(module(), atom(), [term()]) -> term().
gated(M, F, A) ->
    _ = wait_for_token(),
    apply(M, F, A).

-if(?DOCATTRS).
-doc false.
-endif.
gated_plib(Fun, {Ancestors, InitialCall}) ->
    _ = wait_for_token(),
    put('$ancestors', Ancestors),
    put('$initial_call', InitialCall),
    Fun().

-if(?DOCATTRS).
-doc false.
-endif.
gated_plib(M, F, A, {Ancestors, InitialCall}) ->
    _ = wait_for_token(),
    put('$ancestors', Ancestors),
    put('$initial_call', InitialCall),
    apply(M, F, A).

%% An empty mailbox and a selective receive, so the child is quiescent from birth
%% and cannot act before the scheduler has it.
wait_for_token() ->
    receive
        ?GO -> ok
    end.

-if(?DOCATTRS).
-doc """
Replaces `gen_server:start_monitor/3` for a system under simulation. The child
is gated, so the scheduler adopts it before it runs `init/1`.

`start_monitor/4`, `start_link/3,4` and `start/3,4` follow the same rules. The
4-arity functions take the server name as the first argument.

## Start sequence

The gated child does the following, in this order:

1. It waits for the token of the scheduler.
2. It sets the `$ancestors` and `$initial_call` process dictionary entries that
   `proc_lib` sets for a process it starts.
3. It registers the server name, if a name is given.
4. It runs `init/1`.
5. It sends the result of the start to the parent.
6. It enters the loop through `gen_server:enter_loop/3,4`, or through
   `gen_server:enter_loop/4,5` for a named server.

The result is an OTP process. `sys:get_state/1`, `sys:get_status/1` and
`sys:suspend/1` work on it, and `$initial_call` is `{Mod, init, 1}`.

## Supported returns of `init/1`

| Return of `init/1` | Result |
|---|---|
| `{ok, State}` | The server starts. |
| `{ok, State, {continue, C}}` | The server starts and enters its loop with `{continue, C}`. `gen_server` runs `handle_continue/2` before it takes a message, and handles every return of the callback as it does after any `init/1`. See "The first continue". |
| `{ok, State, hibernate}` | The server starts. The hibernation request is dropped. |
| `{ok, State, infinity}` | The server starts. |
| `{ok, State, 0}` | The server starts, yields (see `yield/0`), and enters its loop with a time-out of 0, which delivers `timeout` when the mailbox is empty. |
| `{ok, State, {timeout, Time, {hibernate, Tag}}}` from `supervisor` | The server starts. The hibernation request of the OTP 28 `supervisor` is dropped. |
| `{stop, Reason}` | The start returns `{error, Reason}`. |
| `ignore` | The start returns `ignore`. |
| Any other value, including `{ok, State, Timeout}` with `Timeout` above 0 | The start returns `{error, {eta_sched, unsupported_init, Return}}`, and the child exits with the same reason. |

An unsupported return is refused because this function replaces a start path.
Handling a return incorrectly without a report would be a worse defect than a
failed start.

## The first continue

`gen_server` runs the `handle_continue/2` that `init/1` asks for. The scheduler
does not run the callback.

| Return of `handle_continue/2` | Result |
|---|---|
| `{noreply, State}` | The server waits for a message. |
| `{noreply, State, {continue, C}}` | `gen_server` runs `handle_continue/2` again. |
| `{noreply, State, hibernate}` | The server hibernates and waits for a message. |
| `{noreply, State, infinity}` | The server waits for a message. |
| `{noreply, State, 0}` | The server yields (see `timeout_return/1`), and `gen_server` delivers `timeout` when the mailbox is empty. |
| `{noreply, State, Timeout}` with `Timeout` above 0 | `gen_server` arms the time-out on the real clock, as it does when another callback returns the value. The time-out is not on the virtual clock. |
| `{stop, Reason, State}` | `gen_server` calls `terminate/2`, and the server exits with `Reason`. |
| An error or an exit | `gen_server` calls `terminate/2`, and the server exits with the reason. |
| A throw | `gen_server` takes the thrown value as the return of the callback. |
| Any other value | `gen_server` calls `terminate/2`, and the server exits with `{bad_return_value, Value}`. |

## Errors

- A server name other than `{local, Name}` returns
  `{error, {eta_sched, unsupported_server_name, ServerName}}`. `{global, _}` and
  `{via, _, _}` register through a process that the scheduler does not own.
- A local name that is already registered returns
  `{error, {already_started, Pid}}`.
- A child that is killed before it sends the result returns `{error, Reason}`.
- A call while a scheduler is running and no step is in progress raises
  `{eta_sched, {start_outside_schedule, {Mod, Kind}, Hint}}`. `Kind` is
  `monitor`, `link` or `plain`. No process would send the token. Start the
  process from an operation with `eta_run:spawn_op/1`, or before the scheduler
  exists.

## Delegation

The function delegates to `gen_server` in two cases:

- No scheduler is running.
- The scheduler is stepping a process other than the caller. The caller is then
  a process that the scheduler does not own, such as `kernel_safe_sup`.

## Limitations

- `Options` is not used when the start is gated. A start time-out in `Options`
  therefore has no effect. Waiting for a start time-out would make the run
  depend on the real clock.

## Design

`gen_server:start_*` spawns the child inside OTP. `gen:do_spawn/5` calls
`proc_lib:start_monitor/5`, which calls `erlang:spawn_opt(proc_lib, init_p, …)`.
A transform of the system under test does not reach that call. The child would
be adopted late, and the run would not be replayable. In the registry port, one
such child per group commit made one seed produce a different schedule on each
run.

Replacing `proc_lib` with a transformed copy was rejected for these reasons:

- stdlib is a sticky directory. Loading a replacement fails with
  `sticky_directory` unless `code:unstick_dir/1` is first called on the ebin
  directory of stdlib.
- Every OTP process in the VM starts through `proc_lib`, including the processes
  of ExUnit and Logger. With a broken copy loaded, `Agent.start_link/1` fails
  with `undef`.
- The copy is 1600 lines of OTP code that must follow each OTP release.

This function therefore builds an equivalent process and does not intercept
`proc_lib`.
""".
-endif.
-spec start_monitor(module(), term(), list()) ->
    {ok, {pid(), reference()}} | ignore | {error, term()}.
start_monitor(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_server:start_monitor(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, monitor)
    end.

-spec start_link(module(), term(), list()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_server:start_link(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, link)
    end.

-spec start(module(), term(), list()) -> {ok, pid()} | ignore | {error, term()}.
start(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_server:start(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, plain)
    end.

%% The 4-arity forms, which name the server. Registration happens in the *child*,
%% before `init/1`, which is where `gen` does it and is what makes
%% `{error, {already_started, Pid}}` mean what it means.
-spec start_monitor(gen_server:server_name(), module(), term(), list()) ->
    {ok, {pid(), reference()}} | ignore | {error, term()}.
start_monitor(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_server:start_monitor(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, monitor)
    end.

-spec start_link(gen_server:server_name(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
start_link(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_server:start_link(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, link)
    end.

-spec start(gen_server:server_name(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
start(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_server:start(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, plain)
    end.

-if(?DOCATTRS).
-doc """
Replaces `gen_statem:start_monitor/3` for a system under simulation.
`statem_start_monitor/4`, `statem_start_link/3,4` and `statem_start/3,4` follow
the same rules.

The function follows the rules of `start_monitor/3`, with these differences:

- The child enters the loop through `gen_statem:enter_loop/6`. That function
  reaches the same `enter/8` as `init_it/6` of `gen_statem`. The callback mode
  is therefore read, and the initial state enter call is made, as in a start by
  OTP.
- With no scheduler running, the function delegates to `gen_statem`.
- The supported returns of `init/1` are the following:

| Return of `init/1` | Result |
|---|---|
| `{ok, State, Data}` | The state machine starts. |
| `{ok, State, Data, Actions}` | The state machine starts with `Actions`. |
| `{stop, Reason}` | The start returns `{error, Reason}`. |
| `ignore` | The start returns `ignore`. |
| Any other value | The start returns `{error, {eta_sched, unsupported_init, Return}}`, and the child exits with the same reason. |
""".
-endif.
-spec statem_start_monitor(module(), term(), list()) ->
    {ok, {pid(), reference()}} | ignore | {error, term()}.
statem_start_monitor(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_statem:start_monitor(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, monitor, statem_gated)
    end.

-spec statem_start_link(module(), term(), list()) -> {ok, pid()} | ignore | {error, term()}.
statem_start_link(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_statem:start_link(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, link, statem_gated)
    end.

-spec statem_start(module(), term(), list()) -> {ok, pid()} | ignore | {error, term()}.
statem_start(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_statem:start(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, plain, statem_gated)
    end.

-spec statem_start_monitor(gen_statem:server_name(), module(), term(), list()) ->
    {ok, {pid(), reference()}} | ignore | {error, term()}.
statem_start_monitor(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_statem:start_monitor(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, monitor, statem_gated)
    end.

-spec statem_start_link(gen_statem:server_name(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
statem_start_link(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_statem:start_link(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, link, statem_gated)
    end.

-spec statem_start(gen_statem:server_name(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
statem_start(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_statem:start(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, plain, statem_gated)
    end.

gated_start(Name, Mod, Args, Kind) ->
    gated_start(Name, Mod, Args, Kind, gated).

gated_start(Name, Mod, Args, Kind, Entry) ->
    ok = assert_stepping(Mod, Kind),
    Parent = self(),
    Ancestors = [Parent | own_ancestors()],
    MFA = [Parent, Ancestors, Name, Mod, Args],
    {Pid, Ref} =
        case Kind of
            monitor -> erlang:spawn_monitor(?MODULE, Entry, MFA);
            link -> {erlang:spawn_link(?MODULE, Entry, MFA), undefined};
            %% Monitored for the length of the start. Nothing else would tell the
            %% parent about a child killed before it acknowledged.
            plain -> erlang:spawn_monitor(?MODULE, Entry, MFA)
        end,
    await_start(Pid, Ref, Kind).

%% A gated child is released when the scheduler adopts it, and the scheduler
%% adopts what the process it is stepping creates. A start from any other
%% process while a scheduler is active — the harness's `execute/2` is the
%% usual one, through a transformed module's `start_link/3` — would wait in
%% `await_start/3` for a token nothing sends, with the driver blocked and the
%% run unable to end. Raising is the only useful answer; `eta_run:spawn_op/1`
%% is the way to do it from an operation.
assert_stepping(Mod, Kind) ->
    case stepping() of
        Self when Self =:= self() ->
            ok;
        _ ->
            error(
                {?MODULE,
                    {start_outside_schedule, {Mod, Kind}, <<
                        "a gated start from a process the scheduler is not stepping "
                        "would wait for a token nothing sends. Start it from an "
                        "operation via eta_run:spawn_op/1, or before the scheduler "
                        "exists in init/2"
                    >>}}
            )
    end.

%% Whether a start should be gated. Not when there is no scheduler, and not when
%% the caller is a process the scheduler doesn't own: a VM service such as
%% `kernel_safe_sup`, running a `supervisor` that `Eta.Beam.instrument/1`
%% rewrote, starting a child of its own because something in the run asked it to.
%% Such a caller can only be running while another process holds the step, since
%% every process the scheduler owns is suspended unless it is the one stepping.
%% Its child belongs to the VM, not the run, so it starts the way OTP starts it.
gate_start() ->
    active() andalso
        case stepping() of
            undefined -> true;
            Self when Self =:= self() -> true;
            _Other -> false
        end.

%% `infinity`, deliberately: see the note on start timeouts above. The child cannot
%% run until the scheduler adopts it, and the scheduler is not waiting on us.
await_start(Pid, Ref, Kind) ->
    receive
        {'$eta_started', Pid, {ok, Pid}} ->
            case Kind of
                monitor ->
                    {ok, {Pid, Ref}};
                _ ->
                    _ = drop_monitor(Ref),
                    {ok, Pid}
            end;
        {'$eta_started', Pid, Other} ->
            _ = drop_monitor(Ref),
            Other;
        {'DOWN', Ref, process, Pid, Reason} ->
            {error, Reason};
        %% A parent that traps exits, which every supervisor does, learns of a
        %% child killed mid-start this way, as it does from `proc_lib`.
        {'EXIT', Pid, Reason} when Kind =:= link ->
            {error, Reason}
    end.

drop_monitor(undefined) -> ok;
drop_monitor(Ref) -> erlang:demonitor(Ref, [flush]).

-if(?DOCATTRS).
-doc false.
-endif.
gated(Parent, Ancestors, Name0, Mod, Args) ->
    _ = wait_for_token(),
    Name = server_name(Name0),
    %% What proc_lib:init_p/3 would have set. Without these the process is not an
    %% OTP process: no crash-report formatting, and `sys` cannot introspect it.
    put('$ancestors', Ancestors),
    put('$initial_call', {Mod, init, 1}),
    case register_name(Name) of
        ok ->
            gated_init(Parent, Name, Mod, Args);
        {error, _} = Err ->
            Parent ! {'$eta_started', self(), Err},
            exit(normal)
    end.

%% A local name on a simulated node goes into that node's namespace, so the same
%% server can be started once per node. Resolved here, in the child, which already
%% sits on its parent's node. See `eta_ns`.
server_name({local, N}) -> {local, eta_ns:name(N)};
server_name(Other) -> Other.

%% `{local, N}` only. `{global, _}` and `{via, _, _}` both register through a
%% service process the scheduler does not own, so a start would block on
%% something outside the schedule — the same class of real-time dependency as
%% `code_server`. Refused rather than delegated, because delegating would produce
%% an ungated child and a run that quietly stopped being reproducible.
register_name(undefined) ->
    ok;
register_name({local, N}) ->
    try
        true = erlang:register(N, self()),
        ok
    catch
        error:badarg -> {error, {already_started, whereis(N)}}
    end;
register_name(Other) ->
    {error, {eta_sched, unsupported_server_name, Other}}.

gated_init(Parent, Name, Mod, Args) ->
    case Mod:init(Args) of
        {ok, State} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            enter_loop(Mod, Name, State);
        %% OTP 28's `supervisor` asks to hibernate after an idle second, on every
        %% start. That changes how it waits and nothing about what it does, so
        %% dropping the request here costs memory and no behaviour. It is the one
        %% time-out action let through: any other could fire and change the run.
        {ok, State, {timeout, _Idle, {hibernate, _Tag}}} when Mod =:= supervisor ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            enter_loop(Mod, Name, State);
        %% The instrumented `supervisor`, which `eta_transform` stops asking to
        %% hibernate. `infinity` is no time-out at all.
        {ok, State, infinity} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            enter_loop(Mod, Name, State);
        %% Hibernating changes how the server waits for its next message and
        %% nothing about what it does, and it involves no clock. Dropped, at the
        %% cost of memory.
        {ok, State, hibernate} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            enter_loop(Mod, Name, State);
        {ok, State, {continue, C}} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            enter_loop(Mod, Name, State, {continue, C});
        %% A time-out of 0 reads no clock. `gen_server` delivers `timeout` when
        %% the mailbox is empty. The server yields first, so the scheduler decides
        %% what runs before the server continues, and a message that arrives in
        %% the meantime is handled before `timeout`, as in OTP. See `yield/0`.
        {ok, State, 0} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            ok = yield(),
            enter_loop(Mod, Name, State, 0);
        {stop, Reason} ->
            Parent ! {'$eta_started', self(), {error, Reason}},
            exit(Reason);
        ignore ->
            Parent ! {'$eta_started', self(), ignore},
            exit(normal);
        Other ->
            %% `{ok, State, Timeout}` lands here. A time-out that fires when the
            %% server has been idle is a real-clock behaviour that would need
            %% simulating, and guessing at it would be a stand-in that lies.
            Parent ! {'$eta_started', self(), {error, {eta_sched, unsupported_init, Other}}},
            exit({eta_sched, unsupported_init, Other})
    end.

%% A named server has to enter its loop knowing its name, or `gen_server` will not
%% answer calls addressed to the name.
enter_loop(Mod, undefined, State) -> gen_server:enter_loop(Mod, [], State);
enter_loop(Mod, Name, State) -> gen_server:enter_loop(Mod, [], State, Name).

%% `Action` is a time-out of 0 or `{continue, C}`. `gen_server` runs
%% `handle_continue/2` before it takes a message, and `gen_server` handles every
%% return of the callback.
enter_loop(Mod, undefined, State, Action) -> gen_server:enter_loop(Mod, [], State, Action);
enter_loop(Mod, Name, State, Action) -> gen_server:enter_loop(Mod, [], State, Name, Action).

-if(?DOCATTRS).
-doc false.
-endif.
statem_gated(Parent, Ancestors, Name0, Mod, Args) ->
    _ = wait_for_token(),
    Name = server_name(Name0),
    put('$ancestors', Ancestors),
    put('$initial_call', {Mod, init, 1}),
    case register_name(Name) of
        ok ->
            statem_gated_init(Parent, Name, Mod, Args);
        {error, _} = Err ->
            Parent ! {'$eta_started', self(), Err},
            exit(normal)
    end.

statem_gated_init(Parent, Name, Mod, Args) ->
    case Mod:init(Args) of
        {ok, State, Data} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            statem_enter_loop(Mod, Name, State, Data, []);
        {ok, State, Data, Actions} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            statem_enter_loop(Mod, Name, State, Data, Actions);
        {stop, Reason} ->
            Parent ! {'$eta_started', self(), {error, Reason}},
            exit(Reason);
        ignore ->
            Parent ! {'$eta_started', self(), ignore},
            exit(normal);
        Other ->
            Parent ! {'$eta_started', self(), {error, {eta_sched, unsupported_init, Other}}},
            exit({eta_sched, unsupported_init, Other})
    end.

%% `enter_loop/6` rather than the shorter forms, because `Server` and `Actions`
%% are both being passed and the 5-arity one has to guess between them. An
%% anonymous machine names itself, which is what `gen_statem:enter_loop/4` does.
statem_enter_loop(Mod, undefined, State, Data, Actions) ->
    gen_statem:enter_loop(Mod, [], State, Data, self(), Actions);
statem_enter_loop(Mod, Name, State, Data, Actions) ->
    gen_statem:enter_loop(Mod, [], State, Data, Name, Actions).

-if(?DOCATTRS).
-doc """
Replaces `gen_fsm:start_link/3` for a system under simulation. `fsm_start_link/4`
and `fsm_start/3,4` follow the same rules. `gen_fsm` has no `start_monitor`.

The function follows the rules of `statem_start_link/3`, with these differences:

- The child enters the loop through `gen_fsm:enter_loop/4`, or through
  `gen_fsm:enter_loop/5` for a named state machine.
- With no scheduler running, the function delegates to `gen_fsm`.
- The supported returns of `init/1` are the following:

| Return of `init/1` | Result |
|---|---|
| `{ok, StateName, StateData}` | The state machine starts. |
| `{ok, StateName, StateData, Timeout}`, with a virtual clock running | The state machine starts. `eta_fsm:init_return/1` puts the time-out on the virtual clock. |
| `{ok, StateName, StateData, hibernate}`, with a virtual clock running | `eta_fsm` raises `unsupported_timeout` in the child, and the start returns `{error, Reason}`. |
| `{ok, StateName, StateData, Timeout}`, with no virtual clock running | The start returns `{error, {eta_sched, unsupported_init, Return}}`. |
| `{stop, Reason}` | The start returns `{error, Reason}`. |
| `ignore` | The start returns `ignore`. |
| Any other value | The start returns `{error, {eta_sched, unsupported_init, Return}}`, and the child exits with the same reason. |
""".
-endif.
-spec fsm_start_link(module(), term(), list()) -> {ok, pid()} | ignore | {error, term()}.
fsm_start_link(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_fsm:start_link(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, link, fsm_gated)
    end.

-spec fsm_start(module(), term(), list()) -> {ok, pid()} | ignore | {error, term()}.
fsm_start(Mod, Args, Options) ->
    case gate_start() of
        false -> gen_fsm:start(Mod, Args, Options);
        true -> gated_start(undefined, Mod, Args, plain, fsm_gated)
    end.

-spec fsm_start_link(gen_server:server_name(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
fsm_start_link(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_fsm:start_link(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, link, fsm_gated)
    end.

-spec fsm_start(gen_server:server_name(), module(), term(), list()) ->
    {ok, pid()} | ignore | {error, term()}.
fsm_start(Name, Mod, Args, Options) ->
    case gate_start() of
        false -> gen_fsm:start(Name, Mod, Args, Options);
        true -> gated_start(Name, Mod, Args, plain, fsm_gated)
    end.

-if(?DOCATTRS).
-doc false.
-endif.
fsm_gated(Parent, Ancestors, Name0, Mod, Args) ->
    _ = wait_for_token(),
    Name = server_name(Name0),
    put('$ancestors', Ancestors),
    put('$initial_call', {Mod, init, 1}),
    case register_name(Name) of
        ok ->
            fsm_gated_init(Parent, Name, Mod, Args);
        {error, _} = Err ->
            Parent ! {'$eta_started', self(), Err},
            exit(normal)
    end.

%% `init_return/1` takes a `{ok, S, D, Timeout}` onto the virtual clock and
%% returns `{ok, S, D}`; with no clock it returns the value untouched, and that
%% lands in the refusing clause below — a real-clock time-out under a scheduler
%% is the thing this exists to prevent.
fsm_gated_init(Parent, Name, Mod, Args) ->
    case eta_fsm:init_return(Mod:init(Args)) of
        {ok, StateName, StateData} ->
            Parent ! {'$eta_started', self(), {ok, self()}},
            fsm_enter_loop(Mod, Name, StateName, StateData);
        {stop, Reason} ->
            Parent ! {'$eta_started', self(), {error, Reason}},
            exit(Reason);
        ignore ->
            Parent ! {'$eta_started', self(), ignore},
            exit(normal);
        Other ->
            Parent ! {'$eta_started', self(), {error, {eta_sched, unsupported_init, Other}}},
            exit({eta_sched, unsupported_init, Other})
    end.

fsm_enter_loop(Mod, undefined, StateName, StateData) ->
    gen_fsm:enter_loop(Mod, [], StateName, StateData);
fsm_enter_loop(Mod, Name, StateName, StateData) ->
    gen_fsm:enter_loop(Mod, [], StateName, StateData, Name).

own_ancestors() ->
    case get('$ancestors') of
        undefined -> [];
        A -> A
    end.

%% ---------------------------------------------------------------------------
%% Inspection
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Returns the id of every adopted process, in ascending order. The list includes
processes that have exited. See "Process ids" in the module documentation.
""".
-endif.
-spec ids(sched()) -> [id()].
ids(S) ->
    call(S, ids).

-if(?DOCATTRS).
-doc """
Returns a map from id to pid for every adopted process.

A trace records ids, and a caller holds pids. The map relates the two. `eta_run`
uses the map to turn `{step, 7}` into a name at teardown.

The map includes processes that have exited, because a trace entry can name an
exited process.
""".
-endif.
-spec procs(sched()) -> #{id() => pid()}.
procs(S) ->
    call(S, procs).

-if(?DOCATTRS).
-doc """
Returns the ids of the runnable processes, in ascending order.

A process is runnable when it has not exited and its queue is longer than the
queue length at which it last blocked. See "Runnability" in the module
documentation.
""".
-endif.
-spec runnable(sched()) -> [id()].
runnable(S) ->
    call(S, runnable).

-if(?DOCATTRS).
-doc """
Returns the statistics of the run as a map.

| Field | Value | Value in a deterministic run |
|---|---|---|
| `steps` | The number of steps taken. | Any |
| `processes` | The number of adopted processes, including exited processes. | Any |
| `exited` | The number of adopted processes that have exited. | Any |
| `adopted_late` | The number of children that were adopted after they had started to run. | 0 |
| `timeouts` | The number of steps that ended before the process reached a `receive`. | 0 |
| `ran_on` | The number of steps that ended as a block, after which the process ran on because something outside the schedule woke it. | 0 |
| `cold_code` | A list of `t:cold/0`, one for each process that waited on `code_server` when a run ended. | `[]` |
| `pid_reuse` | The number of children whose pid compares below the pid of an earlier child. See "Limitations" in the module documentation. | 0, if the system or its harness depends on the order of pids |
| `unpinned` | The number of processes that a pinned replay adopted with no pinned id. See `pin_mode/2`. | 0 in a run without pinning and in a replay that follows its trace |
| `preempt_points` | The number of calls of `preempt/0` by a stepped process, while the probability of the `preempt` option is above 0.0. | Any |
| `preemptions` | The number of those calls that yielded. | Any |

A non-zero `adopted_late`, `timeouts` or `ran_on`, or a non-empty `cold_code`,
means that the seed does not reproduce the run. See "Determinism" in the module
documentation.

Each `cold_code` entry gives the process and the frame of the system under test
that called a module that was not loaded:

```erlang
#{cold_code := [#{id := 3, pid := Pid, at := {my_client, commit, 2}}]} =
    eta_sched:stats(Sched).
```

A non-empty `cold_code` means that the run was not quiescent when it ended. The
code server, and not the schedule, would have woken at least one process. The
run ended early, and the real clock orders everything after that point. To
correct this, pass the application that `at` names to `eta_run:preload/1`. See
`note_cold_code/1`.
""".
-endif.
-spec stats(sched()) -> #{atom() => term()}.
stats(S) ->
    call(S, stats).

-if(?DOCATTRS).
-doc """
Records in `cold_code` each scheduled process that waits on `code_server` now.

`run/3` makes this check when it ends. A caller that drives the scheduler with
`step/2` or `step_adopting/2` calls this function when its run ends, before
`stats/1`. `eta_run` does so.

Call the function only at the end of a run. A process that waits on
`code_server` in the middle of a run can still finish its load before the run
ends.
""".
-endif.
-spec check_cold_code(sched()) -> sched().
check_cold_code(S) ->
    call(S, check_cold_code),
    S.

-if(?DOCATTRS).
-doc "Returns the choice sequence, oldest first. Pass the result to `replay/2`.".
-endif.
-spec choices(sched()) -> [id()].
choices(S) ->
    call(S, choices).

%% ---------------------------------------------------------------------------
%% Pinned ids
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Sets the ids that the scheduler gives to the next processes that it adopts.

`eta_run` uses this function in a replay. In the recorded run, `eta_run` stores
on each trace entry the ids of the processes that the entry created. Before
`eta_run` replays an entry, it passes those ids to this function.

- `Ids` is consumed in adoption order.
- The ids that are left over are discarded when the entry closes. The entry
  closes at `take_adopted/1`, `register_adopting/2` or `step_adopting/2`. An
  entry is not required to create every pinned process. When shrinking removes
  an operation, the processes of that operation are never adopted, and no other
  process changes its id.
- An entry that creates no process needs no call, because the supply of pinned
  ids is empty at the start of every entry.
- The call is a cast. The scheduler handles it before the next call or trace
  event that the caller causes.
- Use this function only in a run with `pin_mode/2` set to `true`.

Without pinning, an id is a count of adoptions: the id N names the Nth process
that the run created. `eta_shrink` deletes trace entries and replays the rest.
Deleting the entry that created one process would change the id of every later
process. The remaining `{step, Id}` entries would then name other processes, and
the replay would skip them. The shrinker would conclude that the deletion
changed the result. With pinning, an id names the process that the trace gave
that id, and deleting another entry does not change it.
""".
-endif.
-spec pin(sched(), [id()]) -> ok.
pin({eta_sched, Pid}, Ids) ->
    %% A cast, because there is nothing to wait for and this runs once per trace
    %% entry that creates anything. Ordering is still guaranteed: the caller's next
    %% `step/2`, and any trace event a caller's operation provokes, arrive behind
    %% it in the same mailbox.
    gen_server:cast(Pid, {pin, Ids}).

-if(?DOCATTRS).
-doc """
Sets whether the run takes ids from the trace (`true`) or from the adoption
counter (`false`). The default is `false`.

The mode applies to a whole run and not to one entry. An entry with no pinned
ids has two possible meanings:

- In a trace that records ids, the entry created no process.
- In a trace that records no ids, the entry gives no information.

`eta_run` chooses the mode once, from the trace that it is given.

With `true`, a process that is adopted when no pinned id remains is given a
`{fresh, N}` id and not the next integer. The id therefore cannot equal an id
that a later entry pins.
""".
-endif.
-spec pin_mode(sched(), boolean()) -> ok.
pin_mode(S, Pinning) when is_boolean(Pinning) ->
    call(S, {pin_mode, Pinning}).

-if(?DOCATTRS).
-doc """
Returns the ids that were adopted since the previous call, oldest first, and
clears that record. The call also discards the pinned ids that were not used.

A recording run writes the returned ids into its trace entry. A later replay
passes them to `pin/2`, so the same processes have the same ids.
""".
-endif.
-spec take_adopted(sched()) -> [id()].
take_adopted(S) ->
    call(S, take_adopted).

-if(?DOCATTRS).
-doc """
Does the work of `register/2` and `take_adopted/1` in one call to the scheduler.
Returns `{Sched, Adopted}`.

Each call to the scheduler waits until the scheduler has handled the trace
events that the previous call produced. That wait grows with the number of
processes in the system. The driver calls this function after every operation,
and it calls `step_adopting/2` for every step. A trace entry therefore costs 1
call and not 2.
""".
-endif.
-spec register_adopting(sched(), pid() | [pid()]) -> {sched(), [id()]}.
register_adopting(S, Pids) ->
    {ok, Adopted} = call(S, {register_adopting, Pids}),
    {S, Adopted}.

-if(?DOCATTRS).
-doc "Does `step/2` and `take_adopted/1` in one call to the scheduler. See `register_adopting/2`.".
-endif.
-spec step_adopting(sched(), id()) -> {outcome(), [id()], sched()}.
step_adopting(S, Id) ->
    {Outcome, Adopted} = call(S, {step_adopting, Id}),
    {Outcome, Adopted, S}.

%% ---------------------------------------------------------------------------
%% Stepping and driving
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Resumes the process `Id`, waits until it blocks in a `receive`, and suspends it
again. The step is added to the choice sequence.

Returns `{Outcome, Sched}`. `Outcome` is one of:

- `progress`: the process consumed at least 1 message.
- `no_progress`: the process blocked and consumed no message. A selective
  `receive` matched none of the queued messages.
- `exited`: the process exited.
""".
-endif.
-spec step(sched(), id()) -> {outcome(), sched()}.
step(S, Id) ->
    {call(S, {step, Id}), S}.

-if(?DOCATTRS).
-doc "Calls `run/2` with a `MaxSteps` of 10000.".
-endif.
-spec run(sched()) -> sched().
run(S) ->
    run(S, 10000).

-if(?DOCATTRS).
-doc """
Steps runnable processes until no process is runnable or `MaxSteps` steps have
been taken. The seeded random number generator chooses the process of each
step.

Returns the same handle. `choices/1` then returns the choice sequence for
`replay/2`.
""".
-endif.
-spec run(sched(), non_neg_integer()) -> sched().
run(S, MaxSteps) ->
    run(S, MaxSteps, fun() -> false end).

-if(?DOCATTRS).
-doc """
Does the work of `run/2` and calls `OnIdle` when no process is runnable. This
function is the discrete-event loop.

`OnIdle` returns whether it created new work:

- `true`: the run continues. The call counts as 1 step against `MaxSteps`, so a
  callback that always returns `true` still ends the run.
- `false`: the run ends. The scheduler then records the processes that wait on
  `code_server`. See `stats/1`.

Virtual time uses this callback:

```erlang
eta_sched:run(Sched, MaxSteps, fun eta_time:advance_to_next/0)
```

- The clock moves to the next deadline when no process is runnable at the
  current instant.
- The clock never moves while a process is runnable. The order of events is
  therefore deterministic.
- A long time-out takes no real time.
- The run ends when no process is runnable and no timer is pending.

The scheduler has no notion of time. The callback defines what more work means.

`OnIdle` runs in the scheduler process, not in the process of the caller.
`eta_time` uses ETS and can be called from any process, so
`eta_time:advance_to_next/0` is not affected. Do not pass a callback that reads
the mailbox of the driver.
""".
-endif.
-spec run(sched(), non_neg_integer(), fun(() -> boolean())) -> sched().
run(S, MaxSteps, OnIdle) ->
    call(S, {run, MaxSteps, OnIdle}),
    S.

-if(?DOCATTRS).
-doc """
Steps the processes that `Choices` names, in order. The random number generator
is not used.

Returns one of:

- `{ok, Sched}`: every choice was stepped.
- `{{error, {diverged, Id, Runnable}}, Sched}`: the choice `Id` named a process
  that was not runnable. `Runnable` is the list of runnable ids at that point.

A divergence means that the run did not follow the recorded path. The replay
stops at the first divergence and does not skip the choice, because a run that
skips a choice is not the recorded run.
""".
-endif.
-spec replay(sched(), [id()]) ->
    {ok | {error, {diverged, id(), [id()]}}, sched()}.
replay(S, Choices) ->
    {call(S, {replay, Choices}), S}.

call({eta_sched, Pid}, Request) ->
    gen_server:call(Pid, Request, ?CALL_TIMEOUT).

%% ---------------------------------------------------------------------------
%% Server
%% ---------------------------------------------------------------------------

init(Opts) ->
    Seed = maps:get(seed, Opts, 0),
    %% See `eta_time`'s `claim/3`. Unguarded, `ets:new/2` on an existing named
    %% table raises a bare `badarg` from inside this `init/1`, which is loud but
    %% says nothing about the cause.
    case ets:info(?ACTIVE, owner) of
        undefined ->
            ok;
        Other ->
            error(
                {eta_sched,
                    {scheduler_in_use, Other, <<
                        "one per VM; keep runs serial (`async: false`) and do "
                        "not drive two at once"
                    >>}}
            )
    end,
    _ = ets:new(?ACTIVE, [named_table, public, set]),
    true = ets:insert(?ACTIVE, {sched, {?MODULE, self()}}),
    %% The state of `preempt/0`. The stepped process reads and writes it. The
    %% generator is separate from the generator of the schedule, so a run with a
    %% probability of 0.0 has the schedule that it had without the option.
    case maps:get(preempt, Opts, 0.0) of
        P when P > 0 ->
            true = ets:insert(?ACTIVE, [
                {preempt, P, rand:seed_s(exsss, {Seed + 7, Seed + 19, Seed + 37})},
                {preempt_points, 0},
                {preemptions, 0}
            ]);
        _ ->
            %% `new/1` has checked the value. With 0.0 there is no row, and
            %% `preempt/0` returns after one lookup.
            true
    end,
    %% A traced process then produces a `call` trace event for each call to
    %% `erlang:exit/2`. See `settle_in_step/3`.
    _ = erlang:trace_pattern({erlang, exit, 2}, true, []),
    {ok, #st{rand = rand:seed_s(exsss, {Seed, Seed + 1, Seed + 2})}}.

handle_call({register, Pids}, _From, St) ->
    {reply, ok, do_register(St, Pids)};
%% The same work, closing out the trace entry it belongs to on the way back. A
%% separate tag rather than a flag on the reply, so that `register/2` cannot
%% quietly consume a record its caller was going to ask for.
handle_call({register_adopting, Pids}, _From, St) ->
    {Adopted, St1} = close_entry(do_register(St, Pids)),
    {reply, {ok, Adopted}, St1};
handle_call(release, _From, St) ->
    %% Inactive *before* anything resumes. A resumed process runs on the real
    %% scheduler at once, and one that starts a child through a rewritten
    %% `gen_server:start` would otherwise find a scheduler still active and
    %% nobody stepping — a gated start nothing will release, refused with
    %% `start_outside_schedule`. riak_core's Plumtree did exactly that at
    %% teardown, from an exchange tick it had queued during the run.
    ok = deactivate(),
    {reply, ok, do_release(St)};
handle_call(ids, _From, St = #st{procs = Procs}) ->
    {reply, lists:sort(maps:keys(Procs)), St};
handle_call(procs, _From, St = #st{procs = Procs}) ->
    {reply, Procs, St};
handle_call(runnable, _From, St) ->
    {Ids, St1} = settled_runnable(St),
    {reply, Ids, St1};
handle_call(choices, _From, St = #st{choices = Choices}) ->
    {reply, lists:reverse(Choices), St};
handle_call({pin_mode, Pinning}, _From, St) ->
    {reply, ok, St#st{pinning = Pinning}};
handle_call(take_adopted, _From, St) ->
    {Adopted, St1} = close_entry(St),
    {reply, Adopted, St1};
handle_call(check_cold_code, _From, St) ->
    {reply, ok, note_cold_code(St)};
handle_call(stats, _From, St) ->
    #st{
        steps = Steps,
        procs = Procs,
        exited = Exited,
        adopted_late = Late,
        timeouts = Timeouts,
        ran_on = RanOn,
        cold_code = Cold,
        fresh = Fresh,
        pid_reuse = PidReuse
    } = St,
    Reply = #{
        steps => Steps,
        processes => maps:size(Procs),
        exited => maps:size(Exited),
        adopted_late => Late,
        timeouts => Timeouts,
        ran_on => RanOn,
        cold_code => Cold,
        %% Children whose pid compares below the pid of an earlier child. See
        %% `note_pid_order/2`.
        pid_reuse => PidReuse,
        %% Processes a pinned replay adopted that its trace did not account for.
        %% Zero on a generating run, and on a faithful replay. See `pin/2`.
        unpinned => Fresh,
        %% The calls of `preempt/0` by a stepped process, and the calls that
        %% yielded. Both are 0 when the probability is 0.0.
        preempt_points => preempt_counter(preempt_points),
        preemptions => preempt_counter(preemptions)
    },
    {reply, Reply, St};
handle_call({step, Id}, _From, St) ->
    {Outcome, St1} = do_step(St, Id),
    {reply, Outcome, St1};
handle_call({step_adopting, Id}, _From, St) ->
    {Outcome, St1} = do_step(St, Id),
    {Adopted, St2} = close_entry(St1),
    {reply, {Outcome, Adopted}, St2};
handle_call({run, MaxSteps, OnIdle}, _From, St) ->
    {reply, ok, do_run(St, MaxSteps, OnIdle)};
handle_call({replay, Choices}, _From, St) ->
    {Result, St1} = do_replay(St, Choices),
    {reply, Result, St1}.

handle_cast({pin, Ids}, St) ->
    %% An overwrite rather than an append: the previous entry's leftovers are
    %% already gone, dropped by `close_entry/1`. See `pin/2`.
    {noreply, St#st{supply = Ids}};
handle_cast(_Msg, St) ->
    {noreply, St}.

%% Trace events that arrive between calls: the same handling a step would give
%% them. Adopting a child here rather than at the next step is what keeps a
%% process spawned during an idle window from running unsupervised.
handle_info({trace, _, _, _} = T, St) ->
    {noreply, handle_trace(St, T)};
handle_info({trace, _, _, _, _} = T, St) ->
    {noreply, handle_trace(St, T)};
%% A drain that timed out can leave this behind; it is not an error.
handle_info({trace_delivered, _Pid, _Ref}, St) ->
    {noreply, St};
handle_info(_Msg, St) ->
    {noreply, St}.

%% Suspends belong to this process, so they lift when it exits — but only after
%% the VM has cleaned up, and an untraced-but-suspended process in the meantime
%% is a confusing thing to leave behind. Release explicitly.
terminate(_Reason, St) ->
    ok = deactivate(),
    _ = do_release(St),
    ok.

%% Ends `active/0`. Idempotent, since `release/1` reaches it twice — once from
%% the call and once from the stop that follows.
deactivate() ->
    try
        ets:delete(?ACTIVE)
    catch
        error:badarg -> ok
    end,
    ok.

%% ---------------------------------------------------------------------------
%% Registration
%% ---------------------------------------------------------------------------

do_register(St, Pids) when is_list(Pids) ->
    lists:foldl(fun(Pid, Acc) -> do_register(Acc, Pid) end, St, Pids);
do_register(St = #st{ids = Ids, gated = Gated}, Pid) when is_pid(Pid) ->
    case maps:is_key(Pid, Ids) of
        true ->
            St;
        false ->
            %% A dead pid is not an error: a system under test declares its
            %% processes through `processes/1`, which is re-consulted after every
            %% operation, and short-lived client processes are routinely finished
            %% by then. `erlang:trace/3` raises `badarg` on a dead pid, so this
            %% would otherwise take the run down for something that is nothing.
            try
                erlang:trace(Pid, true, ?TRACE_FLAGS),
                %% Before the suspend, and from here rather than from whoever
                %% first sends to it: finding out who spawned a process means
                %% asking it, and an asker that is being stepped ends its step
                %% by waiting for the answer. See `eta_net:introduce/1`.
                ok = eta_net:introduce(Pid),
                erlang:suspend_process(Pid),
                St1 = adopt(St, Pid),
                %% A gated child is waiting for a token only the scheduler can
                %% send. When its parent is traced, the spawn event delivers it;
                %% when the parent is the driver — or anything else the scheduler
                %% does not own — there is no spawn event, and this is the only
                %% route. Deliberately the same three steps as `handle_trace`,
                %% reached the other way round.
                case is_gated(Pid) andalso not maps:is_key(Pid, Gated) of
                    true ->
                        Pid ! ?GO,
                        St1#st{gated = Gated#{Pid => true}};
                    false ->
                        St1
                end
            catch
                %% `trace/3` raises `badarg` on a dead pid, and
                %% `suspend_process/1` raises two different ways for that one
                %% reason — see `hold/1`. All of them mean the same thing here.
                error:badarg -> St;
                error:exited -> St
            end
    end.

%% The VM's own record of how the process was started, not the `$initial_call`
%% in its dictionary — `proc_lib` overwrites the latter, and this has to survive
%% that.
%% Whether a gated child is still blocked on its token with none queued for
%% it. Safe on a suspended process, and `undefined` — dead — is `false`.
needs_token(Pid) ->
    case erlang:process_info(Pid, [current_function, messages]) of
        [{current_function, {?MODULE, wait_for_token, 0}}, {messages, Msgs}] ->
            not lists:member(?GO, Msgs);
        _ ->
            false
    end.

is_gated(Pid) ->
    case erlang:process_info(Pid, initial_call) of
        {initial_call, {?MODULE, gated, _}} -> true;
        {initial_call, {?MODULE, gated_plib, _}} -> true;
        {initial_call, {?MODULE, statem_gated, _}} -> true;
        {initial_call, {?MODULE, fsm_gated, _}} -> true;
        _ -> false
    end.

%% A child that died before it could be suspended is still adopted, as exited.
%%
%% Skipping it looks harmless — there is nothing left to schedule — and is not: an
%% unpinned id is assigned by counting adoptions, so whether a child is skipped
%% decides whether every process after it keeps its id. A registry's OTP-spawned
%% commit workers are short enough to lose that race, and were observed adopted in
%% one run and gone in the next. Adopting either way makes id assignment
%% independent of liveness, which is the property; a dead process is never
%% runnable, so the id costs nothing else.
%%
%% `pin/2` makes this irrelevant to a *replay*, which is told its ids rather than
%% counting them. It is still load-bearing for the run being recorded, which is
%% where the ids come from.
%%
%% Honest about the effect: this changed **nothing measurable** on the registry —
%% 8 distinct traces across 20 runs, with and without. The dominant cause is what
%% that same late-adopted child *does* before it is suspended, and it masks this
%% entirely. Kept because it is strictly more deterministic and will matter once
%% the dominant cause is gone, not because it was seen to help.
adopt_exited(St, Child) ->
    St1 = adopt(St, Child),
    ok = record_proc(Child, dead),
    Id = maps:get(Child, St1#st.ids),
    mark_exited(St1, Id).

%% Closing out a trace entry: hand back what it adopted, and drop whatever it did
%% not use of what was pinned for it.
%%
%% Reading the record takes it, because the question is always "since when" and
%% the answer is always "since I last asked". Three replies carry it — `step`,
%% `register` and `take_adopted` — because making the caller ask separately costs
%% it a second drain of this process's mailbox. See `register_adopting/2`.
%%
%% Clearing the supply here rather than at the next `pin/2` is what lets a caller
%% skip the `pin/2` entirely for an entry that created nobody: the supply is empty
%% at every entry boundary because whatever closed the last entry emptied it.
-spec close_entry(#st{}) -> {[id()], #st{}}.
close_entry(St = #st{adopted = Adopted}) ->
    {lists:reverse(Adopted), St#st{adopted = [], supply = []}}.

-spec adopt(#st{}, pid()) -> #st{}.
adopt(St0, Pid) ->
    {Id, St = #st{procs = Procs, ids = Ids, live = Live, adopted = Adopted}} = mint(St0),
    %% For `is_alive/1`, which the stepped process calls.
    ok = record_proc(Pid, alive),
    St#st{
        procs = Procs#{Id => Pid},
        ids = Ids#{Pid => Id},
        live = Live#{Id => Pid},
        adopted = [Id | Adopted]
    }.

%% The spawn events of a run arrive in the order in which the children were
%% created. The VM numbers pids upwards, so a child normally has a higher pid
%% than every child before it, and the term order of pids is their creation
%% order. After the VM has created about as many processes as its process
%% limit (`erlang:system_info(process_limit)`, 1,048,576 by default), it
%% reuses pid values, and a new process can compare below an older one. Code
%% that sorts pids, or that keeps pids in an ordered structure, then orders the
%% same processes differently from one run of a seed to the next. The count is
%% reported as `pid_reuse` in `stats/1`.
-spec note_pid_order(#st{}, pid()) -> #st{}.
note_pid_order(St = #st{pid_high = undefined}, Child) ->
    St#st{pid_high = Child};
note_pid_order(St = #st{pid_high = High}, Child) when Child > High ->
    St#st{pid_high = Child};
note_pid_order(St = #st{pid_reuse = Reuse}, _Child) ->
    St#st{pid_reuse = Reuse + 1}.

-spec mark_exited(#st{}, id()) -> #st{}.
mark_exited(St = #st{exited = Exited, live = Live}, Id) ->
    St#st{exited = Exited#{Id => true}, live = maps:remove(Id, Live)}.

%% Where an id comes from. A trace that pinned one is answered from the supply; a
%% generating run counts. The third clause is the interesting one: a *pinned*
%% replay that adopts a process its trace did not account for must not take the
%% next integer, because that integer may be one a later entry is still going to
%% pin. See `pin/2`.
-spec mint(#st{}) -> {id(), #st{}}.
mint(St = #st{supply = [Id | Rest]}) ->
    {Id, St#st{supply = Rest}};
mint(St = #st{pinning = false, next_id = Id}) ->
    {Id, St#st{next_id = Id + 1}};
mint(St = #st{pinning = true, fresh = N}) ->
    {{fresh, N}, St#st{fresh = N + 1}}.

do_release(St = #st{procs = Procs, gated = Gated, yielded = Yielded}) ->
    %% A process still blocked in `yield/0` would wait forever otherwise.
    maps:foreach(
        fun(Id, true) ->
            case maps:find(Id, Procs) of
                {ok, Pid} -> catch Pid ! ?YIELD_GO;
                error -> ok
            end
        end,
        Yielded
    ),
    %% Anything still waiting for its token would block forever otherwise.
    %% Only those, though: `gated` holds every child that was ever sent a
    %% token, and a second one to a child that already has, or had, its first
    %% lands in its mailbox as an ordinary message — a `gen_server` without a
    %% catch-all `handle_info/2` crashes on it at teardown. Found by running
    %% riak_core_broadcast under simulation.
    maps:foreach(
        fun(Pid, true) ->
            case needs_token(Pid) of
                true -> catch Pid ! ?GO;
                false -> ok
            end
        end,
        Gated
    ),
    maps:foreach(
        fun(_Id, Pid) ->
            %% `process_info/2` rather than `is_process_alive/1`, for the reason
            %% in `proc_state/3`: these are still suspended when this runs.
            %% Both calls are safe rather than guarded, because the status
            %% above is a read and these are actions on something that can die
            %% in between — the same window `step/2` documents, and the same one
            %% `hold/1` was widened for. `erlang:trace/3` raises `badarg` on a
            %% pid that is gone, and raising here kills the scheduler while it
            %% is being torn down, so the run reports nothing at all. Reached by
            %% any system whose processes are replaced as it runs.
            case status(Pid) =/= dead of
                true ->
                    safe_untrace(Pid),
                    safe_resume(Pid);
                false ->
                    ok
            end
        end,
        Procs
    ),
    St#st{procs = #{}, ids = #{}, live = #{}, gated = #{}, yielded = #{}}.

%% ---------------------------------------------------------------------------
%% Stepping
%% ---------------------------------------------------------------------------

%% The runnable ids, after every death is settled. The scan of the queue
%% lengths makes each live process handle its signals, so the scan also finds
%% a process that an exit signal killed. See `settle/1`.
-spec settled_runnable(#st{}) -> {[id()], #st{}}.
settled_runnable(St0) ->
    St1 = await_dying(St0),
    Live = lists:sort(maps:to_list(St1#st.live)),
    States = [{Id, Pid, proc_state(St1, Id, Pid)} || {Id, Pid} <- Live],
    case [Pid || {_Id, Pid, dead} <- States] of
        [] -> {[Id || {Id, _Pid, runnable} <- States], St1};
        Dead -> settled_runnable(note_deaths(Dead, St1))
    end.

%% One `process_info/2` read per live process, and this runs for every live
%% process at every choice.
%%
%% The queue length is read with `process_info/2`, which does not need the
%% target to run. Every process here is suspended by the scheduler.
%%
%% Liveness needs no read of its own: the read returns `undefined` for a dead
%% process. A separate `status` read doubled the cost of the scan, and the
%% scan was the largest cost of a long run.
%%
%% A process that yielded is runnable while it is alive. A process with an
%% empty queue and no `blocked_at` is not runnable: a step of such a process
%% wastes a choice.
-spec proc_state(#st{}, id(), pid()) -> runnable | idle | dead.
proc_state(#st{blocked_at = Blocked, yielded = Yielded, mid_step = MidStep}, Id, Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        undefined ->
            dead;
        {message_queue_len, N} ->
            case
                maps:is_key(Id, Yielded) orelse maps:is_key(Id, MidStep) orelse
                    N > maps:get(Id, Blocked, 0)
            of
                true -> runnable;
                false -> idle
            end
    end.

%% Settles the deaths of scheduled processes that happened outside a step of
%% the dead process. Returns whether a process died or finished its exit.
%%
%% A process that does not trap exits dies when the VM handles an exit signal
%% for the process, also while the scheduler holds the process suspended. The
%% signal comes from a linked process that exits or from `erlang:exit/2`. The
%% dead process then sends the signals of its own links and monitors, at a
%% time that the VM chooses.
%%
%% 1. The scheduler waits for the `out_exited` trace event of every process
%%    that has an `exit` trace event. The VM sends the signals of the links
%%    and the monitors of a process before the `out_exited` event. The VM
%%    removes the process from `erlang:processes/0` before it sends these
%%    signals, so the absence of the process there is not a sufficient
%%    condition.
%% 2. The scheduler reads the status of every live scheduled process. The
%%    signals of step 1 were sent before the read, so a process that one of
%%    them kills is found dead. A process that traps exits has the `EXIT`
%%    message in its queue after its next read, and a process with a monitor
%%    has the `DOWN` message.
%% 3. The scheduler handles the `exit` trace event of every process that step
%%    2 found dead, and starts again at step 1. The procedure ends when step 2
%%    finds no dead process.
%%
%% Only trace events of dead processes are taken from the mailbox, so the
%% trace events of the step in progress stay for `drain_trace/2`.
-spec settle(#st{}) -> {boolean(), #st{}}.
settle(St) ->
    settle(St, false).

settle(St0, Changed0) ->
    Changed = Changed0 orelse map_size(St0#st.dying) > 0,
    St1 = await_dying(St0),
    Live = lists:sort(maps:to_list(St1#st.live)),
    case [Pid || {_Id, Pid} <- Live, status(Pid) =:= dead] of
        [] -> {Changed, St1};
        Dead -> settle(note_deaths(Dead, St1), true)
    end.

%% Waits for the `out_exited` trace event of every process in `dying`.
-spec await_dying(#st{}) -> #st{}.
await_dying(St = #st{dying = Dying}) when map_size(Dying) =:= 0 ->
    St;
await_dying(St = #st{dying = Dying}) ->
    lists:foldl(
        fun(Pid, Acc) ->
            receive
                {trace, Pid, out_exited, _} = T -> handle_trace(Acc, T)
            after ?EXITED_TIMEOUT ->
                logger:warning("eta_sched: no out_exited trace event for ~p", [Pid]),
                Acc#st{dying = maps:remove(Pid, Acc#st.dying)}
            end
        end,
        St,
        lists:sort(maps:keys(Dying))
    ).

%% Handles the `exit` trace event of each process of `Dead`, in the given
%% order. A dead process with no such event is marked as exited.
-spec note_deaths([pid()], #st{}) -> #st{}.
note_deaths(Dead, St) ->
    lists:foldl(
        fun(Pid, Acc = #st{ids = Ids, live = Live}) ->
            Id = maps:get(Pid, Ids),
            case maps:is_key(Id, Live) of
                false ->
                    Acc;
                true ->
                    receive
                        {trace, Pid, exit, _} = T -> handle_trace(Acc, T)
                    after ?EXITED_TIMEOUT ->
                        logger:warning("eta_sched: no exit trace event for ~p", [Pid]),
                        ok = record_proc(Pid, dead),
                        mark_exited(Acc, Id)
                    end
            end
        end,
        St,
        Dead
    ).

%% Records the state of a process for `is_alive/1`. A trace event can arrive
%% after `release/1` has deleted the table, so a missing table is not an
%% error.
-spec record_proc(pid(), alive | dead) -> ok.
record_proc(Pid, State) ->
    try ets:insert(?ACTIVE, {{proc, Pid}, State}) of
        true -> ok
    catch
        error:badarg -> ok
    end.

-spec do_step(#st{}, id()) -> {outcome(), #st{}}.
do_step(St00 = #st{procs = Procs}, Id) ->
    Pid = maps:get(Id, Procs),
    %% A process that yielded is resumed with its token. The token is sent before
    %% the queue is read, so the step counts it as a consumed message.
    St0 = resume_yielded(
        St00#st{
            exit_sent = false,
            last_mfa = undefined,
            ran_into = undefined,
            last_send = undefined,
            mid_step = maps:remove(Id, St00#st.mid_step)
        },
        Id,
        Pid
    ),
    QueueBefore = queue_len(Pid),
    %% Published for the duration of the step, and erased after it. While a step
    %% is in progress this is the *only* process that is supposed to be running,
    %% so anything else that acts during it is acting outside the schedule.
    %% `eta_net` uses it to tell an on-schedule send from an off-schedule one; see
    %% `stepping/0`.
    true = ets:insert(?ACTIVE, {stepping, Pid}),
    safe_resume(Pid),
    {Quiescence, St1} = await_quiescent(St0, Pid),
    true = ets:delete(?ACTIVE, stepping),
    St2 = St1#st{steps = St1#st.steps + 1, choices = [Id | St1#st.choices]},
    %% Reading the status and then acting on it is a read followed by an action on
    %% something that can change in between, so the two are taken as one: hold the
    %% process first, and let a failure to hold it *be* the death.
    %%
    %% Splitting them was a latent crash. A step ends when the process stops being
    %% runnable, which is usually a receive but is equally the last thing it does
    %% before returning — so a short-lived worker (a registry member's gather
    %% helper, a transaction worker) routinely dies in the window between the two
    %% calls. `suspend_process/1` raises on a pid that is gone, which took the
    %% scheduler down for something that is nothing. Every other call site in this
    %% module already guarded it; this one did not, and a system spawning such
    %% workers under an injected node fault hit it about one run in three.
    %%
    %% The trace is drained either way. It was not before, and that was the more
    %% consequential half: `trace_delivered/1` is the only thing that says the
    %% tracer has every event, so a process that spawned a child and then exited
    %% in the same step left the spawn event sitting in the mailbox, to be adopted
    %% whenever `handle_info/2` next ran rather than at a point the schedule
    %% fixes.
    case hold(Pid) of
        false ->
            _ = ets:take(?ACTIVE, {yielded, Pid}),
            {_SelfSends, _Late, StDead} = drain_trace(St2, Pid),
            %% The exit can make a linked process die. See `settle/1`.
            {_Changed, StSettled} = settle(mark_exited(StDead, Id)),
            {exited, StSettled};
        true ->
            {SelfSends, Late, St3} = drain_trace(note_yield(St2, Id, Pid), Pid),
            {QueueAfter, St3a} = queue_at_block(St3, Pid, Late),
            Consumed = QueueBefore + SelfSends - QueueAfter,
            St4 = note_quiescence(St3a, Id, Pid, ran_on(St3a, Quiescence), QueueAfter),
            Outcome =
                case Consumed > 0 of
                    true -> progress;
                    false -> no_progress
                end,
            {Outcome, St4}
    end.

%% A step that ended as a block, of a process that then ran on, did not end at a
%% block. It ends as `ran_on`, which `note_quiescence/5` counts in `ran_on`, and
%% the process stays runnable as after a time-out.
ran_on(#st{ran_into = {_, _, _}}, blocked) -> ran_on;
ran_on(_St, Quiescence) -> Quiescence.

mfa_string({M, F, A}) -> io_lib:format("~p:~p/~p", [M, F, A]).

send_string(undefined) ->
    "none";
send_string({Msg, To}) ->
    io_lib:format("~100000tP to ~s", [Msg, 8, dest_string(To)]).

%% A registered name says more than a pid: `file_server_2`, `code_server`.
dest_string(To) when is_pid(To) ->
    case erlang:process_info(To, registered_name) of
        {registered_name, Name} -> io_lib:format("~p (~p)", [To, Name]);
        _ -> io_lib:format("~p", [To])
    end;
dest_string(To) ->
    io_lib:format("~p", [To]).

%% Moves a process that ended its step in `yield/0` into `yielded`. The process
%% wrote the mark itself, before it blocked.
note_yield(St = #st{yielded = Yielded}, Id, Pid) ->
    case ets:take(?ACTIVE, {yielded, Pid}) of
        [] -> St;
        [_] -> St#st{yielded = Yielded#{Id => true}}
    end.

resume_yielded(St = #st{yielded = Yielded}, Id, Pid) ->
    case maps:is_key(Id, Yielded) of
        true ->
            Pid ! ?YIELD_GO,
            St#st{yielded = maps:remove(Id, Yielded)};
        false ->
            St
    end.

%% The length the process's queue had when the process blocked.
%%
%% `blocked_at` must be that length. A message that arrives later is one the
%% receive has not seen, and it must make the process runnable. Reading the
%% queue after the step does not give that length. Every other owned process is
%% suspended during a step, but a suspended process still dies at once from an
%% exit signal, and the `EXIT` and `DOWN` it then sends arrive in real time. So
%% a process that kills another and waits for the `DOWN`, which is what
%% `supervisor:shutdown/1` does to a child that does not trap exits, is often
%% blocked before the `DOWN` arrives and suspended before the queue is read. The
%% `DOWN` was then counted as a message the receive had rejected, the process
%% was not runnable, and the run waited on the virtual clock for the receive's
%% time-out: 30 seconds for each such child of a supervisor.
%%
%% The `'receive'` trace events say which messages arrived after the block. The
%% blocking `out` event was the last event `await_quiescent/2` consumed, so
%% every `'receive'` event for this process that the drains find came after it.
%% A suspended process still produces these events, because it still takes
%% signals into its queue.
%%
%% The most common case is an empty queue. Then the answer is 0 and needs no
%% further check: a `blocked_at` of 0 cannot count any message as rejected, so
%% every later arrival makes the process runnable. This case skips the second
%% `trace_delivered` round trip, which otherwise cost about 20 microseconds on
%% every step.
%%
%% The next case has no late arrival: the queue is read, a second drain finds
%% nothing new, and the length is exact. Otherwise the queue's contents are
%% compared with the late messages. The late messages that are still at the end
%% of the queue are subtracted. A late message that is not in the queue was
%% consumed, because the process ran again between its block and the hold. The
%% comparison is repeated while further messages arrive, a bounded number of
%% times, and the old reading is the fallback.
-spec queue_at_block(#st{}, pid(), [term()]) -> {non_neg_integer(), #st{}}.
queue_at_block(St, Pid, Late0) ->
    case queue_len(Pid) of
        0 -> {0, St};
        Queue -> queue_at_block(St, Pid, Late0, Queue)
    end.

-spec queue_at_block(#st{}, pid(), [term()], pos_integer()) -> {non_neg_integer(), #st{}}.
queue_at_block(St, Pid, Late0, Queue) ->
    case drain_trace(St, Pid) of
        {_, [], St1} when Late0 =:= [] ->
            {Queue, St1};
        {_, More, St1} ->
            settle_late(St1, Pid, Late0 ++ More, ?LATE_SETTLE_ROUNDS)
    end.

-spec settle_late(#st{}, pid(), [term()], non_neg_integer()) -> {non_neg_integer(), #st{}}.
settle_late(St, Pid, Late, Rounds) ->
    Messages =
        case erlang:process_info(Pid, messages) of
            {messages, Ms} -> Ms;
            undefined -> []
        end,
    case drain_trace(St, Pid) of
        {_, [], St1} ->
            {length(Messages) - late_in_queue(Late, Messages), St1};
        {_, _More, St1} when Rounds =< 1 ->
            {queue_len(Pid), St1};
        {_, More, St1} ->
            settle_late(St1, Pid, Late ++ More, Rounds - 1)
    end.

%% How many messages at the end of `Messages` are the last of `Late`, in order.
-spec late_in_queue([term()], [term()]) -> non_neg_integer().
late_in_queue(Late, Messages) ->
    late_in_queue(Late, Messages, min(length(Late), length(Messages))).

late_in_queue(_Late, _Messages, 0) ->
    0;
late_in_queue(Late, Messages, K) ->
    case
        lists:nthtail(length(Messages) - K, Messages) =:=
            lists:nthtail(length(Late) - K, Late)
    of
        true -> K;
        false -> late_in_queue(Late, Messages, K - 1)
    end.

%% Suspend a process, answering whether there was one to suspend. `false` means it
%% has exited, which is the only reason `suspend_process/1` raises here: the pid is
%% one this scheduler owns, so it is local, and nothing else suspends it.
%%
%% It raises **two** ways for that one reason, and the difference between them is
%% a race rather than a distinction worth acting on. `suspend_process/1` blocks
%% until the target has actually stopped, so:
%%
%% - already dead when the call is made — `error:badarg`
%% - dies while the call is waiting for it to stop — `error:exited`
%%
%% Catching only the first is a driver that dies on the second. Which one you get
%% depends on whether the target was *running* when the scheduler reached for it,
%% so the gap is invisible to a system whose processes only ever sit in receives
%% and opens up as soon as they start exiting on purpose — an agent aborting, a
%% `gen_server` stopping, anything that ends a step by terminating.
%%
%% Measured on OTP 28, racing a suspend against a process spending its last few
%% reductions: 19598 suspends, 398 `badarg`, 4 `exited` out of 20000. Rare enough
%% to survive a lot of testing, common enough to take a run down.
-spec hold(pid()) -> boolean().
hold(Pid) ->
    try
        erlang:suspend_process(Pid),
        true
    catch
        error:badarg -> false;
        error:exited -> false
    end.

%% Where a process blocked, but only when it actually blocked.
%%
%% On a completed step the queue length is meaningful: a receive blocks only
%% after failing to match *every* queued message, so whatever is left is known
%% not to match, whether or not the step consumed anything first. Recording it
%% unconditionally is what makes selective receive work — recording it only on
%% an unproductive step would leave a process that consumed one message and
%% blocked on the rest looking runnable, costing a wasted step every time round.
%%
%% On a step that timed out, none of that holds. The process was suspended
%% wherever it happened to be rather than at a receive, so its mailbox says
%% nothing about what it has scanned. Recording a block it never reached would
%% mark it blocked at a queue length it may never grow past, stranding it for
%% the rest of the run. Leaving `blocked_at` alone keeps it runnable, so the
%% next step re-runs it and the schedule usually repairs itself.
-spec note_quiescence(#st{}, id(), pid(), blocked | timeout | ran_on, non_neg_integer()) -> #st{}.
note_quiescence(St = #st{blocked_at = Blocked}, Id, _Pid, blocked, QueueAfter) ->
    St#st{blocked_at = Blocked#{Id => QueueAfter}};
note_quiescence(
    St = #st{
        ran_on = RanOn,
        mid_step = MidStep,
        last_mfa = BlockedIn,
        ran_into = RanInto,
        last_send = LastSend
    },
    Id,
    Pid,
    ran_on,
    _QueueAfter
) ->
    %% Read on the suspended process, once per such step. The read makes the
    %% process handle a signal, and its `in` and `out` events go with the drain,
    %% not into the next step.
    Stack =
        case erlang:process_info(Pid, current_stacktrace) of
            {current_stacktrace, S} -> S;
            undefined -> dead
        end,
    {_SelfSends, _Late, St1} = drain_trace(St, Pid),
    logger:warning(
        "eta_sched: ~p ran on after its step had ended as a block in ~s, into ~s, "
        "so it was suspended mid-step. Something outside the schedule woke it, such "
        "as the answer of a VM service. The last message it sent in the step: ~s. "
        "Its stack now: ~100000tP. "
        "This run's interleaving is partly wall clock and its seed will not "
        "reproduce. See stats/1's `ran_on`.",
        [Pid, mfa_string(BlockedIn), mfa_string(RanInto), send_string(LastSend), Stack, 30]
    ),
    St1#st{ran_on = RanOn + 1, mid_step = MidStep#{Id => true}};
note_quiescence(St = #st{timeouts = Timeouts, mid_step = MidStep}, Id, Pid, timeout, _QueueAfter) ->
    logger:warning(
        "eta_sched: no scheduling event for ~p within ~wms, so it was suspended "
        "mid-step. This run's interleaving is partly wall clock and its seed will "
        "not reproduce. See stats/1's `timeouts`.",
        [Pid, ?EVENT_POLL * ?EVENT_PATIENCE]
    ),
    St#st{timeouts = Timeouts + 1, mid_step = MidStep#{Id => true}}.

%% Called at the one moment it can be called: a run has found nothing runnable
%% and its idle hook has declined to move the clock, so it is about to return —
%% believing the system quiescent.
%%
%% A process waiting on `code_server` is, from here, indistinguishable from one
%% blocked in a receive. It is not runnable, it holds no timer, and if it is the
%% last thing standing then the run ends at what looks exactly like quiescence,
%% having done a fraction of the work, and reports success. `eta_run`'s
%% `modules_loaded` does not catch it either: the load completes after the run
%% has finished, so nothing is recorded against the run at all.
%%
%% It is catchable because it has a signature. `code_server:call/1` is a send
%% followed by a receive with one clause, so a process blocked there is blocked
%% *in that function*, and `current_function` says so. That is one
%% `process_info/2` per owned process, once per `run/3` call, on the path where
%% the run is ending anyway.
%%
%% Recorded rather than raised. The run happened, its violation (if any) is
%% real, and the caller decides — which is the same position `audit/1` takes on
%% every other wall-clock leak. See `stats/1`.
-spec note_cold_code(#st{}) -> #st{}.
note_cold_code(St = #st{procs = Procs, exited = Exited, cold_code = Cold}) ->
    Found = [
        cold_entry(Id, Pid)
     || {Id, Pid} <- lists:sort(maps:to_list(Procs)),
        not maps:is_key(Id, Exited),
        in_code_server(Pid)
    ],
    case Found -- Cold of
        [] ->
            St;
        New ->
            logger:warning(
                "eta_sched: the run ended with ~w process(es) waiting on code_server, so "
                "what looked like quiescence was not. The interleaving from here is wall "
                "clock. Preload the application: ~p",
                [length(New), New]
            ),
            St#st{cold_code = Cold ++ New}
    end.

%% `current_function` rather than the stack, because it is the cheap read and the
%% one that cannot be ambiguous: `code_server:call/1` has a single receive in it.
in_code_server(Pid) ->
    case erlang:process_info(Pid, current_function) of
        {current_function, {code_server, call, 1}} -> true;
        _ -> false
    end.

cold_entry(Id, Pid) ->
    At =
        case erlang:process_info(Pid, current_stacktrace) of
            {current_stacktrace, Stack} -> cold_site(Stack);
            undefined -> undefined
        end,
    #{id => Id, pid => Pid, at => At}.

%% The first frame that is not the loading machinery itself, which is the line in
%% the system under test that reached a module it had not touched. Both routes in
%% are covered: the implicit one through `error_handler:undefined_function/3`,
%% and an explicit `code:ensure_loaded/1` — which is worth naming separately,
%% because it goes to the code server *every time* for a module that is not
%% there to be found.
cold_site([{M, _F, _A, _Loc} | Rest]) when
    M =:= code_server; M =:= code; M =:= error_handler; M =:= erl_prim_loader
->
    cold_site(Rest);
cold_site([{M, F, A, _Loc} | _]) ->
    {M, F, A};
cold_site(_) ->
    undefined.

%% Wait for the process to run and then block again.  See the module doc on why
%% the `in` event must be awaited before status is trusted.
%%
%% `blocked` means the process reached a receive it cannot satisfy, which is what
%% a completed step is. `timeout` means it did not, and the caller must treat
%% everything it would otherwise conclude from the mailbox as unreliable.
-spec await_quiescent(#st{}, pid()) -> {blocked | timeout, #st{}}.
await_quiescent(St, Pid) ->
    case await_event(St, Pid, in, ?MAX_EVENTS_PER_STEP) of
        %% A process that exited did finish; there is nothing left to strand.
        {exited, St1} -> {blocked, St1};
        {timeout, St1} -> {timeout, St1};
        {ok, St1} -> await_block(St1, Pid, ?MAX_EVENTS_PER_STEP)
    end.

-spec await_block(#st{}, pid(), non_neg_integer()) -> {blocked | timeout, #st{}}.
await_block(St, Pid, Budget) when Budget > 0 ->
    case await_event(St, Pid, out, Budget) of
        {exited, St1} ->
            {blocked, St1};
        {timeout, St1} ->
            {timeout, St1};
        {ok, St1} ->
            %% Scheduled out — but that also happens on preemption, so only a
            %% `waiting` status means it is genuinely blocked in a receive.
            case status(Pid) of
                waiting -> confirm_block(St1, Pid, Budget);
                dead -> {blocked, St1};
                _ -> await_block(St1, Pid, Budget - 1)
            end
    end;
await_block(St, Pid, _Budget) ->
    logger:warning("eta_sched: ~p never blocked; suspending it mid-flight", [Pid]),
    {timeout, St}.

%% Checks that the `out` event that `await_block/3` took was the last `out`
%% event of the step.
%%
%% The status is read after the `out` event, not at the event. The VM can
%% schedule a process out and in again in the middle of a step. Two causes are
%% known:
%%
%% - The process reaches the reduction limit.
%% - The process calls `erlang:demonitor(Ref, [flush])` after a reply through
%%   an alias with the option `reply_demonitor`. The VM then schedules the
%%   process out in `erts_internal:flush_monitor_messages/3`.
%%   `gen_server:check_response/3`, `gen_server:receive_response/2` and
%%   `gen_server:wait_response/2` make this call.
%%
%% The process can run on and block in its `receive` before the scheduler reads
%% the status. The status is then `waiting` at an `out` event from the middle
%% of the step. Without this check the step ended at that event, and the
%% `'receive'` events of the rest of the step counted as arrivals after the
%% block. A message that the process sent to itself in the rest of the step
%% was then not part of `blocked_at`, and the process stayed runnable.
%%
%% `erlang:trace_delivered/1` makes every trace event of the process up to now
%% arrive. An `in` event among them means that the process ran after the `out`
%% event, so the wait continues with the next `out` event. The other events
%% stay in the mailbox for `drain_trace/2`. A status read and
%% `erlang:trace_delivered/1` do not make a blocked process produce an `in`
%% event.
-spec confirm_block(#st{}, pid(), non_neg_integer()) -> {blocked | timeout, #st{}}.
confirm_block(St, Pid, Budget) ->
    Ref = erlang:trace_delivered(Pid),
    receive
        {trace_delivered, Pid, Ref} -> ok
    after ?DELIVERED_TIMEOUT ->
        logger:warning("eta_sched: trace_delivered timed out for ~p", [Pid])
    end,
    receive
        {trace, Pid, in, _} -> await_block(St, Pid, Budget - 1)
    after 0 ->
        case St#st.exit_sent orelse map_size(St#st.dying) > 0 of
            true -> settle_in_step(St#st{exit_sent = false}, Pid, Budget);
            false -> blocked_or_vm_wait(St, Pid, Budget)
        end
    end.

%% Ends the step, unless the process waits for an answer of the VM.
%%
%% Some functions of the `erlang` module send a request to another process
%% and wait for the answer in a `receive` of their own. Examples are
%% `erlang:process_info/2` of another process, `erlang:garbage_collect/1` and
%% `erlang:check_process_code/2`. The process is then scheduled out with the
%% status `waiting`, in the middle of the call. The answer arrives at a time
%% that the VM chooses, so a step that ended here ended before or after the
%% rest of the call.
%%
%% The step continues until the answer has arrived: the scheduler waits for
%% the next `in` trace event of the process and then for the next block. When
%% no answer arrives within the bound of `await_event/4`, the step ends as a
%% time-out, and `stats/1` counts it in `timeouts`.
-spec blocked_or_vm_wait(#st{}, pid(), non_neg_integer()) -> {blocked | timeout, #st{}}.
blocked_or_vm_wait(St, Pid, Budget) ->
    case vm_wait(Pid) of
        false ->
            {blocked, St};
        true ->
            case await_event(St, Pid, in, Budget) of
                {ok, St1} -> await_block(St1, Pid, Budget - 1);
                {exited, St1} -> {blocked, St1};
                {timeout, St1} -> {timeout, St1}
            end
    end.

%% Whether the process waits in a `receive` of the modules `erlang` or
%% `erts_internal`. Such a `receive` waits for an answer of the VM to a
%% request of the process, and not for a message of the system under test.
%% The functions are `erts_internal:await_result/1`,
%% `erlang:garbage_collect/2`, `erlang:check_process_code/3` and others of
%% the same kind.
%%
%% `erlang:hibernate/3` is the exception: a hibernating process waits for a
%% message of the system.
-spec vm_wait(pid()) -> boolean().
vm_wait(Pid) ->
    case erlang:process_info(Pid, current_function) of
        {current_function, {erlang, hibernate, 3}} -> false;
        {current_function, {erlang, _, _}} -> true;
        {current_function, {erts_internal, _, _}} -> true;
        _ -> false
    end.

%% Settles the deaths that the process of the step caused before the step
%% ends. The process called `erlang:exit/2`, or a process started to exit
%% during the step.
%%
%% The `EXIT` and `DOWN` messages of these deaths are in the queue of the
%% process after `settle/1`. A process that kills another process and waits
%% for the `DOWN` message, as `supervisor:shutdown/2` does, then takes the
%% message in the same step in every run. Without this, the message arrived
%% before or after the end of the step, at a time that the VM chose.
%%
%% A message that arrived makes the VM schedule the process in, so the wait
%% for the block starts again. The read of `message_queue_len` makes the
%% process handle the signals that it has received before the read of the
%% status.
-spec settle_in_step(#st{}, pid(), non_neg_integer()) -> {blocked | timeout, #st{}}.
settle_in_step(St0, Pid, Budget) ->
    case settle(St0) of
        {false, St} ->
            blocked_or_vm_wait(St, Pid, Budget);
        {true, St} ->
            case erlang:process_info(Pid, [message_queue_len, status]) of
                undefined -> {blocked, St};
                [_, {status, waiting}] -> confirm_block(St, Pid, Budget - 1);
                _ -> await_block(St, Pid, Budget - 1)
            end
    end.

%% Consume trace messages until `Want` (`in` or `out`) arrives for this pid.
%%
%% Every clause matches a trace-shaped message and nothing else. The scheduler now
%% has its own mailbox, so the only other traffic here is its own API calls — but
%% eating one of those would be just as confusing as eating a reply used to be.
-spec await_event(#st{}, pid(), in | out, non_neg_integer()) ->
    {ok | exited | timeout, #st{}}.
await_event(St, Pid, Want, Budget) ->
    await_event(St, Pid, Want, Budget, ?EVENT_PATIENCE).

-spec await_event(#st{}, pid(), in | out, non_neg_integer(), non_neg_integer()) ->
    {ok | exited | timeout, #st{}}.
await_event(St, Pid, Want, Budget, Patience) when Budget > 0, Patience > 0 ->
    receive
        {trace, Pid, Want, MFA} ->
            {ok, St#st{last_mfa = MFA}};
        {trace, Pid, out_exited, _} = T ->
            {exited, handle_trace(St, T)};
        {trace, Pid, exit, Reason} ->
            %% Reason is passed through rather than flattened to `normal`: nothing
            %% here reads it, but `eta_net` does — a simulated monitor's DOWN
            %% carries the real exit reason. See `eta_net:notify_exit/2`.
            {exited, handle_trace(St, {trace, Pid, exit, Reason})};
        {trace, _, _, _} = T ->
            await_event(handle_trace(St, T), Pid, Want, Budget - 1, Patience);
        {trace, Pid, send, Msg, To} = T ->
            await_event(
                handle_trace(St#st{last_send = {Msg, To}}, T), Pid, Want, Budget - 1, Patience
            );
        {trace, _, _, _, _} = T ->
            await_event(handle_trace(St, T), Pid, Want, Budget - 1, Patience)
    after ?EVENT_POLL ->
        %% Nothing yet. Whether to keep waiting is a question about the process,
        %% not about how long we have waited.
        case status(Pid) of
            dead ->
                {exited, St};
            suspended ->
                %% The resume did not take, so this process is not going to run
                %% and no event is coming. The one case where giving up is right.
                {timeout, St};
            _ ->
                %% Alive and not suspended, so it is running, runnable, or about
                %% to be scheduled in. The event is in flight.
                await_event(St, Pid, Want, Budget, Patience - 1)
        end
    end;
await_event(St, _Pid, _Want, _Budget, _Patience) ->
    {timeout, St}.

%% Collect this tracee's pending trace messages, synchronised with
%% erlang:trace_delivered/1 so a step never races the trace stream.  Returns how
%% many messages the process sent to *itself* during the step — the only way its
%% mailbox can grow while it holds the CPU alone, and so the correction term the
%% consumption count needs — and the messages delivered to it, oldest first.
%% Called after the step's blocking `out` event, those are the messages that
%% arrived after the process blocked. See `queue_at_block/3`.
-spec drain_trace(#st{}, pid()) -> {non_neg_integer(), [term()], #st{}}.
drain_trace(St, Pid) ->
    Ref = erlang:trace_delivered(Pid),
    do_drain(St, Pid, Ref, 0, []).

-spec do_drain(#st{}, pid(), reference(), non_neg_integer(), [term()]) ->
    {non_neg_integer(), [term()], #st{}}.
do_drain(St, Pid, Ref, SelfSends, Received) ->
    receive
        {trace_delivered, Pid, Ref} ->
            {SelfSends, lists:reverse(Received), St};
        {trace, Pid, send, _Msg, Pid} ->
            do_drain(St, Pid, Ref, SelfSends + 1, Received);
        {trace, Pid, 'receive', Msg} ->
            do_drain(St, Pid, Ref, SelfSends, [Msg | Received]);
        {trace, Pid, Running, MFA} when Running =:= in; Running =:= out ->
            do_drain(note_running(St, MFA), Pid, Ref, SelfSends, Received);
        {trace, _, _, _} = T ->
            do_drain(handle_trace(St, T), Pid, Ref, SelfSends, Received);
        {trace, _, _, _, _} = T ->
            do_drain(handle_trace(St, T), Pid, Ref, SelfSends, Received)
    after ?DELIVERED_TIMEOUT ->
        logger:warning("eta_sched: trace_delivered timed out for ~p", [Pid]),
        {SelfSends, lists:reverse(Received), St}
    end.

%% An `in` or `out` event after the block. A blocked process is still scheduled
%% in and out after its step, without running any code of its own, to handle a
%% signal, such as a read of its `current_function` or of its messages. Those
%% events carry the function of the `receive` it blocked in. An event in another
%% function means that the process left the `receive` and ran on, because
%% something outside the schedule woke it during the confirmation of the block.
%% `confirm_block/3` cannot see that: the `in` event of that wake-up can arrive
%% after the answer to `erlang:trace_delivered/1`. Measured on Erlang/OTP 29,
%% with a process that asks `file_server_2` and then calls a dirty NIF: the step
%% ended as a block in 17 of 500 trials with 1 scheduler and 234 of 500 with 4,
%% and nothing stepped the process again.
%%
%% A process that ran on and blocked again in the same function is not seen.
%%
%% Only a function of the form `{Module, Function, Arity}` is recorded. The VM
%% can report another term when it does not know the function. Such a term
%% must not take the place of a later function.
note_running(St = #st{last_mfa = MFA}, MFA) -> St;
note_running(St = #st{last_mfa = undefined}, _MFA) -> St;
note_running(St = #st{ran_into = undefined}, MFA = {_, _, _}) -> St#st{ran_into = MFA};
note_running(St, _MFA) -> St.

%% Trace events that are not about the step in progress: adopt spawned children,
%% note exits, ignore the rest.
-spec handle_trace(#st{}, tuple()) -> #st{}.
%% A gated child (see `spawn/1`) is already blocked, so there is no race to lose:
%% adopt it and hand it its token. It does not count as adopted late, because it
%% has not run.
handle_trace(
    St0 = #st{}, {trace, Parent, spawn, Child, {?MODULE, F, _}}
) when F =:= gated; F =:= gated_plib; F =:= statem_gated; F =:= fsm_gated ->
    St = #st{ids = Ids, gated = Gated} = note_pid_order(St0, Child),
    %% A child belongs wherever its parent does. `eta_net` is inert if no network
    %% is running, and a no-op if the parent was never placed — see
    %% `eta_net:place/2` for why a topology that does not follow spawning is a
    %% topology that goes stale the first time the system creates a worker.
    ok = eta_net:inherit(Parent, Child),
    case maps:is_key(Child, Ids) of
        true ->
            St;
        false ->
            try
                erlang:suspend_process(Child),
                St1 = adopt(St, Child),
                Child ! ?GO,
                St1#st{gated = Gated#{Child => true}}
            catch
                %% Gone before the suspend, or gone during it; see `hold/1`.
                error:badarg -> St;
                error:exited -> St
            end
    end;
handle_trace(St0 = #st{}, {trace, Parent, spawn, Child, _MFA}) ->
    St = #st{ids = Ids} = note_pid_order(St0, Child),
    ok = eta_net:inherit(Parent, Child),
    case maps:is_key(Child, Ids) of
        true ->
            St;
        false ->
            %% set_on_spawn already applied our trace flags, so the child is
            %% traced but running. Suspend it as fast as we can and record that
            %% the window existed.
            %%
            %% It may already be gone: a system that spawns short-lived helpers —
            %% a registry member's gather and snapshot workers, a generic server's
            %% transaction workers — routinely finishes one before the spawn event
            %% has even been handled. `suspend_process/1` raises on a pid that is
            %% gone, which would take the scheduler down for something that is
            %% nothing. There is nothing left to schedule, so it is not adopted.
            try
                erlang:suspend_process(Child),
                St1 = adopt(St, Child),
                St1#st{adopted_late = St#st.adopted_late + 1}
            catch
                %% Gone before the suspend, or gone during it; see `hold/1`. This
                %% is the site most exposed to the second, because the child here
                %% is by definition still running.
                error:badarg -> adopt_exited(St, Child);
                error:exited -> adopt_exited(St, Child)
            end
    end;
handle_trace(St = #st{ids = Ids}, {trace, Pid, exit, Reason}) ->
    %% The scheduler is the tracer for every process in a run, so this is the one
    %% place an exit is observed at a point the schedule fixes rather than
    %% whenever the BEAM happens to run a watcher. `eta_net` has no other source
    %% for it, and is inert if no network is running. See
    %% `eta_net:notify_exit/2`.
    ok = eta_net:notify_exit(Pid, Reason),
    %% For `is_alive/1`. Recorded for every process whose exit is traced,
    %% whether or not the scheduler has adopted it.
    ok = record_proc(Pid, dead),
    %% Its timers go with it. A deadline addressed to a dead process can make
    %% nothing runnable, so leaving it in the wheel only gives the clock a
    %% place to advance to for no reason, and the audit a stray to report. A
    %% `gen_fsm` that crashed on a partition with a 60-second time-out armed
    %% was how it showed up.
    _ = eta_time:forget(Pid),
    St1 = St#st{dying = (St#st.dying)#{Pid => true}},
    case maps:find(Pid, Ids) of
        {ok, Id} -> mark_exited(St1, Id);
        error -> St1
    end;
%% The process has sent the signals of its links and monitors. See `settle/1`.
handle_trace(St = #st{dying = Dying}, {trace, Pid, out_exited, _}) ->
    St#st{dying = maps:remove(Pid, Dying)};
%% Only the process of a step runs during the step, so the call is a call of
%% that process. See `settle_in_step/3`.
handle_trace(St, {trace, _Pid, call, {erlang, exit, [_, _]}}) ->
    St#st{exit_sent = true};
%% Every other trace event (in, out, 'receive', send elsewhere, link, …) is not
%% scheduling-relevant.
handle_trace(St, {trace, _Pid, _Event, _A}) ->
    St;
handle_trace(St, {trace, _Pid, _Event, _A, _B}) ->
    St.

%% ---------------------------------------------------------------------------
%% Driving
%% ---------------------------------------------------------------------------

-spec do_run(#st{}, non_neg_integer(), fun(() -> boolean())) -> #st{}.
do_run(St, 0, _OnIdle) ->
    St;
do_run(St0, MaxSteps, OnIdle) ->
    {Runnable, St} = settled_runnable(St0),
    case Runnable of
        [] ->
            case OnIdle() of
                true -> do_run(St, MaxSteps - 1, OnIdle);
                false -> note_cold_code(St)
            end;
        Ids ->
            {I, Rand} = rand:uniform_s(length(Ids), St#st.rand),
            Id = lists:nth(I, Ids),
            {_Outcome, St1} = do_step(St#st{rand = Rand}, Id),
            do_run(St1, MaxSteps - 1, OnIdle)
    end.

-spec do_replay(#st{}, [id()]) -> {ok | {error, {diverged, id(), [id()]}}, #st{}}.
do_replay(St, []) ->
    {ok, St};
do_replay(St0, [Id | Rest]) ->
    {Runnable, St} = settled_runnable(St0),
    case lists:member(Id, Runnable) of
        true ->
            {_Outcome, St1} = do_step(St, Id),
            do_replay(St1, Rest);
        false ->
            {{error, {diverged, Id, Runnable}}, St}
    end.

%% ---------------------------------------------------------------------------
%% Process introspection
%% ---------------------------------------------------------------------------

-spec queue_len(pid()) -> non_neg_integer().
queue_len(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        undefined -> 0
    end.

-spec status(pid()) -> atom().
-if(?DOCATTRS).
-doc """
Replaces `erlang:is_process_alive/1` for a system under simulation. Returns
whether `Pid` is alive.

`erlang:is_process_alive/1` on another process sends a signal, and the target
replies when it next runs. During a run, every scheduled process other than the
stepped process is suspended. The caller would wait until the scheduler resumes
the target, and the step would not end. `eta_transform` points the call at this
function.

While a scheduler is active, the function answers from the record of the
scheduler, and sends no signal:

| `Pid` | Result |
|---|---|
| The calling process | `true` |
| A process whose exit the scheduler has traced, or that `eta_net:kill_node/2` has killed | `false` |
| A process that the scheduler owns and that has not exited | `true` |
| Any other process, and every process when no scheduler is active | The result of `process_info(Pid, status)` |

`process_info/2` on a suspended process also sends a signal. The reply arrives
at a time that the VM decides: before the caller is scheduled out, or after.
In the second case the scheduler saw the caller blocked and ended the step, and
the caller became runnable again when the reply arrived. A harness whose
system called `is_process_alive/1` on a suspended process therefore had seeds
that produced two schedules. The record of the scheduler removes that wait.

## Limitations

- A process that a harness kills with `exit/2`, and not with
  `eta_net:kill_node/2`, is reported as alive until the scheduler has handled
  the exit trace event of the process.
""".
-endif.
-spec is_alive(pid()) -> boolean().
is_alive(Pid) when Pid =:= self() ->
    true;
is_alive(Pid) ->
    case recorded(Pid) of
        dead -> false;
        alive -> not eta_net:exited(Pid);
        unknown -> status(Pid) =/= dead
    end.

%% What the scheduler has recorded about `Pid`. See `adopt/2` and the exit
%% clause of `handle_trace/2`.
recorded(Pid) ->
    try ets:lookup(?ACTIVE, {proc, Pid}) of
        [{_, State}] -> State;
        [] -> unknown
    catch
        error:badarg -> unknown
    end.

status(Pid) ->
    case erlang:process_info(Pid, status) of
        {status, Status} -> Status;
        undefined -> dead
    end.

%% A process may already be dead, or not suspended at all if something outside
%% the scheduler touched it.
-spec safe_resume(pid()) -> ok.
safe_resume(Pid) ->
    try
        erlang:resume_process(Pid),
        ok
    catch
        _:_ -> ok
    end.

%% Same reason as `safe_resume/1`: turning tracing off is an action on a pid
%% that may already be gone, and `erlang:trace/3` answers that with `badarg`.
-spec safe_untrace(pid()) -> ok.
safe_untrace(Pid) ->
    try
        _ = erlang:trace(Pid, false, ?TRACE_FLAGS),
        ok
    catch
        _:_ -> ok
    end.

%% ---------------------------------------------------------------------------
%% Yield points
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Ends the step of the calling process, and makes the process runnable.

A step ends when the process blocks in a `receive`. A process that has more
work and no message to wait for never blocks, so no other process can run until
the work is done. On the BEAM, preemption lets other processes run in between.
`yield/0` gives the scheduler that choice point: the process blocks on a token
that only the scheduler sends, and the scheduler treats it as runnable. When the
seed chooses the process, the step sends the token and the process continues.
Other processes may run first, and messages that they send are in the mailbox of
the process when it continues.

The process writes a mark into the table of the scheduler before it blocks.
The step that ends reads the mark. A replay follows the same rule, so a trace
that contains a yield replays exactly.

Returns `ok`. Outside a step of the calling process, for example with no
scheduler running, `yield/0` returns at once.
""".
-endif.
-spec yield() -> ok.
yield() ->
    Self = self(),
    case stepping() of
        Self ->
            true = ets:insert(?ACTIVE, {{yielded, Self}}),
            receive
                ?YIELD_GO -> ok
            end;
        _ ->
            ok
    end.

-if(?DOCATTRS).
-doc """
A preemption point: yields with the probability of the `preempt` option.

A step runs a process until the process blocks in a `receive`. Code between two
`receive` expressions is therefore atomic in a run. On the BEAM it is not: a
process can lose its scheduler thread between any 2 function calls, and another
process can read or write shared state in between. Shared state is an ETS table
that another process reads, an `atomics` or `counters` array, or a
`persistent_term`. A system that writes 2 rows in one callback, and has a reader
in another process, has states on the BEAM that no run reaches.

`preempt/0` makes such a state reachable. The seed decides at each call whether
the process yields (see `yield/0`). With the probability 0.0, which is the
default, the function reads one ETS row and returns.

`eta_transform` puts a call of `preempt/0` before each call that the attribute
`-eta_preempt(...)` of a module names. See "Preemption points" in
`eta_transform`. A module can also call the function directly.

- The decisions come from a generator of their own, which is seeded from the
  seed of the scheduler. A run and its replay with the same probability make the
  same decisions.
- Outside a step of the calling process, for example with no scheduler
  running, the function returns at once.
- `stats/1` counts the calls in `preempt_points` and the yields in
  `preemptions`.

A harness reads the state of the system between steps. With a probability above
0.0, a step can end inside a callback, so `check/1` of the harness can see the
state between 2 writes of one callback. An invariant on the shared state of a
process must hold in that state, or the harness must skip the invariant while
`preempted/1` is `true` for the process.

Returns `ok`.
""".
-endif.
-spec preempt() -> ok.
preempt() ->
    Self = self(),
    case stepping() of
        Self ->
            case ets:lookup(?ACTIVE, preempt) of
                [{preempt, P, Rand0}] ->
                    {Draw, Rand1} = rand:uniform_s(Rand0),
                    true = ets:insert(?ACTIVE, {preempt, P, Rand1}),
                    _ = ets:update_counter(?ACTIVE, preempt_points, 1),
                    case Draw < P of
                        true ->
                            _ = ets:update_counter(?ACTIVE, preemptions, 1),
                            %% The mark is for `preempted/1`. A process that
                            %% dies while it waits leaves the mark, which is
                            %% then a mark of a dead process.
                            true = ets:insert(?ACTIVE, {{preempted, Self}}),
                            ok = yield(),
                            %% The scheduler releases a waiting process when a
                            %% run ends, and then deletes the table.
                            try
                                true = ets:delete(?ACTIVE, {preempted, Self}),
                                ok
                            catch
                                error:badarg -> ok
                            end;
                        false ->
                            ok
                    end;
                [] ->
                    ok
            end;
        _ ->
            ok
    end.

-if(?DOCATTRS).
-doc """
Whether `Pid` waits in `preempt/0`: the process yielded at a preemption point
and has not continued.

A harness calls the function in `check/1`. While it returns `true`, the process
is between 2 calls of one callback, and the state that the process shares with
other processes can be between 2 writes. An invariant that holds only at the end
of a callback is skipped for that process and checked at a later call of
`check/1`.

Returns `false` with no scheduler running.
""".
-endif.
-spec preempted(pid()) -> boolean().
preempted(Pid) when is_pid(Pid) ->
    try
        ets:member(?ACTIVE, {preempted, Pid})
    catch
        error:badarg -> false
    end.

preempt_counter(Counter) ->
    case ets:lookup(?ACTIVE, Counter) of
        [{_, N}] -> N;
        [] -> 0
    end.

-if(?DOCATTRS).
-doc """
The return value of a `gen_server` callback, after a yield if the value carries
a time-out of 0.

`eta_transform` passes the value of `handle_call/3`, `handle_cast/2`,
`handle_info/2` and `handle_continue/2` of a `gen_server` through this function.
`{noreply, State, 0}` makes `gen_server` deliver `timeout` as soon as the
mailbox is empty. Without a yield, a server that returns a time-out of 0 again
from its `timeout` callback runs in one step until it blocks, and no other
process can run in between. The function yields (see `yield/0`) and then returns
the value unchanged, so `gen_server` still handles a message that arrived during
the yield before `timeout`.

`{reply, Reply, State, 0}` is returned unchanged without a yield: the reply is
sent by `gen_server` after the callback returns, and a yield would delay it. In
a module with the network pass, the reply pass of `eta_transform` sends the
reply first and turns the value into `{noreply, State, 0}`, which yields.
""".
-endif.
-spec timeout_return(term()) -> term().
timeout_return({noreply, _State, 0} = Return) ->
    ok = yield(),
    Return;
timeout_return(Return) ->
    Return.
