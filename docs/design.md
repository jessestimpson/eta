# Design

This document is the design of eta for people who change eta. It states what eta
does, how the components divide the work, the reason for each significant design
decision, the known limitations, and the open problems. The user manual is the
walkthrough in [`docs/01`](01-what-dst-is.md) through
[`docs/07`](07-a-journey-through-dst-elixir.md).

eta was extracted from the simulation suite of `dgen`, a durable distributed
`gen_server` with a replicated process registry. Some measurements below come
from `dgen_registry`, and they name it.

## AI disclosure

This document is LLM-generated.

## Goals

eta makes a test of a concurrent BEAM system deterministic. A run is a function of
a seed.

1. **Exact replay.** A seed reproduces a run's schedule and its result. A recorded
   trace replays without the seed.
2. **Virtual time.** A timer fires when the run advances the clock to its
   deadline, not when the wall clock reaches it. 100 minutes of simulated time,
   200 heartbeat ticks at 30 s, run in 8 ms of real time. A test can therefore
   afford thousands of seeds instead of a few.
3. **Fault injection.** Message loss, delay, network partitions, node kills,
   timer loss, timer skew and disk crashes are drawn from the seed and replay
   with it.
4. **Shrinking.** A failing trace is reduced to a short trace that still fails.

eta is not a proof. A model checker such as TLC explores every interleaving of an
abstraction of the system. eta samples interleavings of the real code. The two
methods miss different defects, and a project gains from both.

## Approach

### Serializing processes

eta runs exactly one process at a time. A process runs until it blocks in a
`receive` or exits. The scheduler then chooses the next process from a seeded
random generator. The interleaving of the whole system is therefore the sequence
of the scheduler's choices.

The mechanism uses `erlang:suspend_process/1`, `erlang:resume_process/1`,
`erlang:trace/3` and `erlang:process_info/2`. It does not intercept messages.
Erlang guarantees that messages between one ordered pair of processes arrive in
the order they were sent. When only one process runs at a time, the global order
of messages is the order in which the senders were stepped. Control of which
process runs is therefore sufficient for a deterministic message order.

Control of order is not sufficient for a fault model. A process that sends to
three peers does so within one step, so a broadcast that reaches some peers and
not others is not a state that scheduling alone can produce. `eta_net` provides
those states. See [Network](#network).

### Sources of nondeterminism

| Source | Remedy | Module |
|---|---|---|
| Preemptive process scheduling | One process runs at a time, chosen by the seed | `eta_sched` |
| Timers, clock reads and `receive ... after` | Virtual clock and timer wheel | `eta_time`, `eta_statem`, `eta_fsm` |
| Process creation inside OTP and libraries | Gated spawns and starts; in-memory rewriting of dependencies | `eta_sched`, `Eta.Beam` |
| Message delivery between nodes | Simulated network | `eta_net`, `eta_ns`, `eta_rpc` |
| `rand` without an explicit state | Per-process streams derived from the seed | `eta_rand` |
| Iteration order of hash-based ETS tables | Results sorted while a run is active | `eta_ets` |
| Calls to VM service processes (`code_server`, `file_server`, `dets_server`, `application_controller`, `logger`) | Preloading, and in-process replacements | `eta_run:preload/1`, `eta_file`, `eta_dets`, `eta_app`, `eta_logger` |
| Durability of files | Simulated disk with crash semantics | `eta_disk` |
| External services such as a database | A deterministic substitute supplied by the project | none |

References and pids differ between runs. They affect a run only when they affect
control flow, for example when a system sorts by a pid or iterates a table keyed
by references. `eta_ets` sorts iteration results. A sort of references is
stable only in a VM with one scheduler thread (`+S 1:1`), because each scheduler
thread makes references in its own sequence.

## Architecture

### Components

| Module | Responsibility |
|---|---|
| `eta_sched` | Owns the set of scheduled processes. Steps one process at a time, detects when a step ends, records the choices, and adopts the processes that a step creates. |
| `eta_time` | Virtual clock and timer wheel. Replaces the `erlang` timer and clock functions. |
| `eta_transform` | Parse transform. Points a module's timer, clock, spawn, send, monitor and name calls at eta, and rewrites `receive ... after`. |
| `eta_run` | Run driver. Turns a seed into a run, checks invariants after each action, records the trace, and replays a trace. |
| `eta_harness` | The behaviour that a system under test implements for `eta_run`. |
| `eta_shrink` | Delta debugging over a failing trace. |
| `eta_net` | Simulated network: loss, delay, partitions, node kills, and the events that a link or node failure delivers. |
| `eta_ns`, `eta_rpc` | A namespace of registered names, ETS tables and `persistent_term` keys per simulated node; `rpc` and `erpc` between simulated nodes. |
| `eta_observe` | Publishes a process's state on each callback return so that an invariant can read it while the process is suspended. |
| `eta_log` | Event log on the same timeline as the schedule, with process names, for reading a failure. |
| `eta_statem`, `eta_fsm` | `gen_statem` and `gen_fsm` time-outs on the virtual clock. |
| `eta_rand`, `eta_ets` | Seeded `rand`; stable ETS iteration order. |
| `eta_disk`, `eta_file`, `eta_dets`, `eta_app`, `eta_logger` | Replacements for calls that would otherwise wait on a VM service process. `eta_disk` also simulates crash loss of unsynced writes. |
| `Eta`, `Eta.Beam`, `mix compile.eta` | Elixir support: the opt-in, the post-compilation rewrite, and in-memory rewriting of dependencies. |

### The harness contract

A system under test implements `eta_harness`:

```erlang
-callback init(Seed :: integer(), Config :: map()) -> {ok, state()}.
-callback processes(state()) -> [pid()].
-callback generate(state(), rand:state()) -> {op(), rand:state()}.
-callback execute(op(), state()) -> state().
-callback check(state()) -> ok | {violation, violation()}.
-callback terminate(state()) -> ok.
%% Optional:
-callback check_final(settled(), state()) -> ok | {violation, violation()}.
-callback settle_done(state()) -> boolean().
-callback labels(state()) -> #{pid() => term()}.
```

Three rules follow from serialization. A harness that breaks one of them can
fail without reporting an error.

1. **`execute/2` must not block.** Every scheduled process is suspended while the
   driver runs, so a synchronous call from the driver is never answered. An
   operation spawns a process through `eta_run:spawn_op/1`. That function starts
   the process blocked until the scheduler has registered it. A plain `spawn/1`
   runs on the real scheduler until registration, and two such processes from
   close operations reach their first receiver in wall-clock order.
2. **`check/1` must read state out of band.** An invariant that calls a suspended
   process cannot get an answer. `eta_run` bounds `check/1` by the
   `check_timeout` option (default 5000 ms) and reports `{error, check_blocked}`.
   A client function that catches its own time-out does not reach that bound: it
   returns a plausible value such as `undefined`, and the invariant passes without
   checking anything. `eta_observe` and ETS tables are the supported ways to read state.
3. **`init/2` must return a system that does nothing the schedule did not ask
   for.** "Ready" is not sufficient. In `dgen_registry`, about 1 start in 5 left
   an elector with an unprocessed call, and the seeds stopped reproducing. A
   first call into a module that is not yet loaded is the same kind of defect:
   the load is a synchronous call to `code_server`. The `preload` option loads
   the named applications before the run.

### Code transformation

`eta_transform` rewrites call targets in the modules that opt in. It changes
nothing else. Every replacement function delegates to the original when no run is
active, so a transformed module behaves normally outside a simulation.

| Pass | Rewrites | Opt-out |
|---|---|---|
| Time | `erlang` timer and clock functions, `os:system_time`, `timer:sleep/1`, `calendar:universal_time/0` | none |
| `after` | `receive ... after T` into a receive on a virtual timer | `-eta_after(false)` |
| Spawn | `spawn*`, `proc_lib` spawns and starts, `gen:start`, `gen_server`, `gen_statem` and `gen_fsm` starts | none |
| Network | `!`, `erlang:send`, `gen_server` and `gen_statem` calls, casts and replies, monitors, node identity, registered names, named ETS tables, `persistent_term`, `rpc`, `erpc` | `-eta_net(false)` |
| Observe | Republishes declared state on each callback return | absent unless `-eta_observe(...)` |
| Random | `rand` functions without an explicit state, `crypto:strong_rand_bytes/1` | none |

**Only qualified calls are rewritten, with two exceptions.** `erlang:monotonic_time()`
is rewritten and `monotonic_time()` is not, because the time functions are not
auto-imported: an unqualified call refers to a function of the module itself.
`spawn/1,3`, `spawn_link/1,3` and `monitor/2` are auto-imported, so a bare call is
the BIF. Those are rewritten when the module does not define a function with the
same name and arity.

**The `after` rewrite.** `receive Cs after T -> B end` becomes:

```erlang
begin
    Ref = make_ref(),
    TRef = eta_time:arm_after(T, Ref),
    receive
        Pat1 -> eta_time:disarm_after(TRef, Ref), Body1;
        ...
        {'$eta_after', G} when G =:= Ref -> B
    end
end
```

Three details are required for correctness:

1. `after 0` does not use the timer wheel. It is a poll of the mailbox. A virtual
   timer would make it a wait.
2. The disarm is at the head of each clause, not after the `receive`. A disarm
   after the `receive` takes the clause body out of tail position. A recursive
   receive loop then grows its stack: 200,005 words after 50,000 iterations,
   against 5 words for the original.
3. The time-out clause matches a fresh variable and compares it in a guard. A
   match on the bound reference produces a compiler warning on every receive.

The rewrite costs 2 ETS operations per receive, also when a message matches at
once.

**OTP's own processes are built, not intercepted.** `gen_server:start_link`
spawns inside `proc_lib`, which no transform of a project's code reaches.
Replacing `proc_lib` with a transformed copy is not practical: stdlib is a sticky
directory, a broken copy breaks every OTP process in the VM including ExUnit's,
and the copy is pinned to one OTP release. eta builds an equivalent process
instead. `eta_sched:start_monitor/3` spawns a gated process, sets the
`$ancestors` and `$initial_call` entries that `proc_lib` would set, runs `init/1`,
and enters the loop with `gen_server:enter_loop`. `sys:get_state/1` and
`sys:get_status/1` work on the result. An `init/1` return shape that eta does not
support is refused, not guessed.

**Elixir.** Elixir has no supported parse transform hook. `mix compile.eta` reads
the abstract format from each opted-in beam's debug info, runs `eta_transform` on
it unchanged, and writes the beam back. The Elixir compiler inlines `send/2`,
`spawn/1`, `Process.monitor/1` and similar calls to the `:erlang` calls that the
tables already match. Table entries for `Elixir.*` modules cover the calls that
are not inlined, such as `GenServer` starts and the calendar constructors.

**Dependencies.** `Eta.Beam.instrument/1` applies the same rewrite to modules
that the project does not own, in memory, for one VM. The beams on disk do not
change. A process that an uninstrumented dependency spawns is adopted but never
becomes runnable, and the run ends as if the system were quiet. OTP 28's
`supervisor` requests hibernation after 1 s of idleness on a real timer, so
`:supervisor` must be instrumented even when every child starts without it.

**Mix does not track the transform as a dependency.** Changing `eta_transform`
does not recompile the modules built with it. A test whose system under test is a
transformed module recompiles that module from source in `setup_all`. Without
that step, a test can pass against the previous version of the transform.

## Scheduler

### Process and step

`eta_sched` is a separate process. `sched()` is a handle to it. The scheduler
reads trace events in its own mailbox, and the driver reads the system's
messages in the driver's mailbox. When the scheduler ran in the driver's process,
a catch-all receive for trace events consumed and discarded a `gen_server` reply
addressed to the driver.

A step is:

1. Resume the chosen process.
2. Wait for its `in` trace event. A process blocked in a receive reports
   `waiting` before it has run, so the status is meaningful only after `in`.
3. Wait for an `out` event after which the status is `waiting` or the process is
   dead. An `out` with any other status is a preemption.
4. Suspend the process, and drain the trace with `erlang:trace_delivered/1`.
5. Record where the process blocked.

A step that does not end within the event budget is suspended where it is and
counted in `timeouts`. A run with a non-zero `timeouts` is not replayable.

### Runnability

A process is runnable when its queue is longer than the queue length at which it
last blocked (`blocked_at`). A `receive` blocks only after it has failed to match
every queued message. After any step, the messages that remain are therefore
known not to match, and `blocked_at` is recorded after every step. A process
that consumed 1 message and blocked on the rest is not runnable until a new
message arrives.

`blocked_at` must be the queue length at the moment of the block. A message can
arrive after the block and before the scheduler reads the queue. The common case
is a process that kills another scheduled process and waits for the `DOWN`, which
`supervisor:shutdown/1` does for each child that does not trap exits. The victim
dies at once although it is suspended, and its `EXIT` and `DOWN` arrive in real
time. `queue_at_block/3` subtracts the messages that arrived after the block. It
uses the `'receive'` trace events that follow the blocking `out` event, and a
suspended process still produces those events. When the queue is empty, the
answer is 0 and no further check is made.

The `'receive'` trace event is not a progress signal. It fires when a message
enters the queue, whether or not a receive later matches it. Progress is measured
as the change in queue length, corrected for messages that the process sent to
itself.

`runnable_ids/1` runs at every choice. It reads the map of processes that have not
exited and makes one `process_info(Pid, message_queue_len)` call per process. A
dead process has a queue length of 0, so it needs no separate liveness read.

### Adoption and identity

A process spawned through a rewritten call starts blocked on a token. The
scheduler adopts it from the spawn trace event and then sends the token, so the
process does not run before the scheduler owns it. A process spawned by
untransformed code is adopted through `set_on_spawn` tracing after it has
started, and is counted in `adopted_late`. In `dgen_registry`, gated spawns
reduced late adoptions from 1212 of 1233 processes to 1 of 431, and building OTP
processes reduced them to 0.

Each process has an id. A generated run assigns ids in adoption order. A trace
entry records the ids of the processes it created, and a replay is given those ids
(`pin/2`) instead of counting. Deleting an entry during shrinking therefore does
not rename the processes that later entries refer to.

## Virtual time

`eta_time` is ETS and module functions, not a process. A call to a timer process
would block, and the scheduler treats a block as the end of a step. Each timer
would then cost a scheduling choice. ETS access is safe because only one
scheduled process runs at a time.

The clock advances only when nothing is runnable. It then moves to the next
deadline, or the run injects an operation, as `quiet_p` decides. `busy_steps`
advances the clock after a number of actions without a clock move, for a system
that is always runnable.

Rules that follow from this design:

- **The clock must start before the system.** A timer armed while the clock is
  not running is a real timer, and it stays real until it fires.
- **`eta_time` is not a standalone facility.** Without the scheduler, the clock
  can reach the next deadline before a process has handled the previous timer and
  armed the next one. A loop that advances the clock then stops early.
- **A sleep in the driver stays real.** `timer:sleep/1` in a transformed module is
  a virtual sleep. A client function that polls a deadline with a sleep must stay
  outside the transform. Inside the transform it never returns, because only the
  driver advances the clock.

Timer faults: `drop_p` makes a timer never fire while it stays cancellable and
readable, and `skew_ms` perturbs deadlines at creation, never into the past.

`gen_statem` state time-outs, `gen_statem` generic time-outs and `gen_fsm`
time-outs are armed inside OTP, where
the transform does not reach. `eta_statem` and `eta_fsm` remove the time-out
action from the callback's return value before OTP receives it, and arm a virtual
timer instead.

## Run driver

At each iteration `eta_run` does exactly one of three things: step a runnable
process, inject the next operation, or advance the clock. It then runs the
invariants, every `check_every` actions.

| Option | Purpose |
|---|---|
| `op_p` | Probability of injecting an operation when a process is runnable. |
| `quiet_p` | Probability of advancing the clock instead of injecting when nothing is runnable. A driver that always injects cannot reach a defect that appears only when the system is idle. |
| `settle_steps` | Steps after the last operation. A system with a periodic timer never becomes quiescent, and this phase is the only one in which the invariants run without client traffic. |
| `check_timeout` | Real-time bound on `check/1` and `check_final/2`. |
| `preload` | Applications to load before the run. |

A trace is a list of entries: `{op, Op}`, `{step, Id}` and `{clock, Ms}`, each
with the ids of the processes it created. The clock entry is required. A replay
walks only the recorded entries, so a trace without clock entries replays a timed
system against a clock that does not move.

`audit/1` checks the fields that indicate a run's interleaving was partly decided
by the wall clock: `modules_loaded`, `sched.cold_code`, `sched.adopted_late`,
`sched.timeouts`, `net.unmanaged` and `rand.unmanaged`.

## Shrinking

`eta_shrink` applies delta debugging to the trace. Operations and steps are
entries in one list, so one search removes both.

A candidate has three possible results: the same violation, a clean run, or a
divergence. A divergence means the candidate is not a valid schedule and is not
evidence. A shrinker that counts a divergence as "did not fail" keeps entries
that it could remove. eta avoids divergence: candidates replay in `lenient` mode,
which skips a step that names a process that is not runnable. The shrink then
takes the trace that the replay executed and verifies it with a strict replay.
A result that does not verify is returned with `verified => false`.

"The same failure" is the violation's `property` key, or a caller-supplied
`match` predicate. Without either, any violation counts, and a system with more
than one invariant can shrink one defect into another.

Measured on `eta_2pc` with its planted defect, over 30 failing seeds: every
shrink verified, and the mean trace length went from 43 entries to 7.6.

## Network

### Model

`eta_net` delivers, drops, delays or cuts messages for each ordered pair of
processes. It never reorders messages between one pair, because Erlang
distribution does not. Messages are delivered by the driver between steps.

A failure is more than lost messages. When a connection fails, Erlang delivers
`nodedown` to both ends and fires every monitor across the connection with
`noconnection`. A simulator that only drops messages produces a state that real
distribution cannot produce: both ends still treat the link as up. `eta_net`
delivers the events:

| Feature | Behaviour |
|---|---|
| Per-side signals | `#{signal => nodedown}` sends `{nodedown, B}` to the processes of A and `{nodedown, A}` to the processes of B. |
| Direction | `#{learns => a}` delivers the events to A only. The cut is symmetric in both cases. |
| `noconnection` DOWNs | A monitor between two simulated nodes fires with `noconnection` on a partition or a node kill. |
| Node identity | `node/0,1`, `nodes/0,1`, `monitor_nodes/1,2`, `connect_node/1` and their Elixir forms answer from the topology. A connection is lost on a partition or a kill and made again by `connect_node/1` or by a send. |
| Namespaces | Each simulated node has its own registered names, named ETS tables and `persistent_term` keys (`eta_ns`). `rpc` and `erpc` run on the named node (`eta_rpc`). |

### Located and faultable

These are two properties of a process:

- **Located** decides which processes receive link events and which die with a
  node.
- **Faultable** decides whose messages may be dropped or delayed. A send is
  faulted only when both ends are faultable.

`place/2` makes a process both. `attach/2` makes it located and not faultable.
Children inherit both properties. A process that talks to a durable store needs
`attach/2`: a database commits or fails, it does not lose a request, and a
dropped store request produces a false violation. The alternative, placing every
process and narrowing the policy's `scope` to exclude store traffic, must be kept
correct by hand each time the system adds a message.

### Simulated monitors

A process on another simulated node must see `noconnection` when a node dies. A
monitor that is not part of the topology must see the real exit reason. One VM
cannot produce both with real monitors:

- Only the owner can cancel a monitor, so the driver cannot retire a watcher's
  monitor before a kill.
- A queued `DOWN` cannot be changed, and a second, synthetic `DOWN` for the same
  monitor is a state that Erlang never produces.

`eta_net:monitor/2` therefore records the pair, returns its own reference, and
creates no VM monitor. The target's exit is learned from `eta_sched`'s exit trace
event. The scheduler is the tracer of every scheduled process, so it learns of the
exit in the step that caused it. A DOWN delivered at the end of that step follows
every message the dying process sent during the step, which is the order the VM
produces. A broker process with real monitors is not used, because it is not
scheduled and would deliver at a wall-clock time.

A monitor is simulated only when, at creation, the watcher and the target are on
different simulated nodes. Every other monitor is a real one. A simulated monitor
that misses an exit leaves its watcher blocked with no end, and this rule limits
that risk to the monitors that a partition can sever.

### Killing a node

`kill_node/2` does the following, in this order:

1. It fires `noconnection` at every simulated monitor held from another node on a
   process that is about to die.
2. It retires every monitor with either end on the node.
3. It cancels messages in flight to or from the node.
4. It kills the processes and waits for each to exit.
5. It applies a disk crash to the node's files, when a disk is running.
6. It signals the surviving nodes.

Step 1 must come before step 4. A dead process yields `killed` to every monitor
on it, and the exit signal is asynchronous, so a monitor still registered at the
kill can fire with the real reason. The wait in step 4 is required because
`erlang:exit/2` only posts a signal: without it, the scheduler's next choice
depends on how fast the VM removes the process.

### Determinism rules

- Signals and synthetic DOWNs never draw from the fault generator. Adding an
  event must not change which messages are dropped.
- Every fan-out is sorted by a sequence number stamped when the placement or
  monitor was created. `ets:match/2` row order is not guaranteed.
- The fault generator is seeded by the `seed` option of `eta_net:start/1`. It
  advances only when a decision has more than one possible outcome. A send under
  a perfect policy, a send outside the policy's `scope`, and a send that does not
  cross a faultable link draw nothing. Start-up traffic that runs before a policy
  is set therefore does not offset the fault schedule.

Measured on `eta_net_faults`, seed 4, 30 operations over 3 nodes of 2 processes:

| Measurement | Value |
|---|---|
| Link signals delivered | 28 |
| Synthetic `noconnection` DOWNs | 10 |
| Messages dropped | 7 |
| Messages delayed | 7 |
| Processes killed with their node | 4 of 6 |
| Stray timers, late adoptions, step time-outs | 0 |
| Distinct traces in 10 runs of the seed | 1 |

## Results

| System | Result |
|---|---|
| `eta_2pc`, planted defect, 1 transaction with fixed votes | 52 of 200 seeds violate atomicity. The seed changes only the order in which 3 votes reach the coordinator. |
| `eta_2pc`, correct coordinator | 40 seeds give 40 distinct traces and no violation. |
| `dgen_registry`, reverted partial-batch fix | 11 of 50 seeds violate `same_version_same_replica`, the first at seed 2, after about 0.3 s. |
| `dgen_registry`, no planted defect | 9 of 200 seeds found a defect that nobody had planted: a forwarding follower re-inserted a name that the same batch had removed. The formal model had no unregister action, and the earlier test harness healed the divergence before it checked. |
| Broadway 1.3.1 pipeline, 500 seeds without and 500 with a graceful stop | No Broadway defect. The run found the late-arrival defect in `eta_sched` described under [Runnability](#runnability). |

Lessons from these systems:

- **A property that holds only at rest needs the system's definition of rest.**
  "Nothing runnable" can occur in the middle of an operation, for example while a
  commit waits on a worker. The `dgen_registry` replica invariant is gated on
  "nothing runnable and no client waiting".
- **Every synchronous call to a VM service process is a real-time dependence.**
  Two of the three determinism defects in `dgen_registry` were calls to
  `code_server`. A search of the source for such calls takes less effort than
  tracing for them.
- **A defect that appears only on the first run of a VM looks like a property of
  the seed.** On-demand code loading affected only the first run. The first run
  was always the one that differed, and reversing the order of the seeds moved
  the failure to a different seed.
- **Operations must name things by values that are stable across runs.** A pid or
  a name that embeds a unique integer makes a trace differ at entry 0, which
  looks like a scheduling divergence.

## Verification

- **A test is evidence only after it has failed.** Break the code and confirm
  that the test fails. The run-level determinism test of `eta_net` passed with
  the fan-out sorts removed, because with 6 processes `ets:match/2` returned rows
  in insertion order. Two direct tests now assert the fan-out order.
- **Replay and re-run are different tests.** Re-running a seed exercises
  `run/2`. Replaying a trace exercises `replay/3`. The missing clock entry was
  hidden because `replay/3` had only been tested on a system without timers.
- **Check a seed in fresh VMs.** References and pids differ between VMs, and
  teardown runs in real time, so a run can inherit state from the previous run.
  Compare the traces of one seed from 2 fresh VMs.
- **Assert the property, not the schedule that usually produces it.** A test that
  hard-codes an uncontrolled schedule reports a timing change as a correctness
  failure. Derive the expected values from what the run did, or control the
  schedule.
- **A determinism test repeats a run many times.** `eta_sched_test` runs one seed
  1000 times and requires one trace, in about 0.5 s.

## Limitations

- eta cannot reproduce an interleaving that depends on preemption or yielding. A
  process yields only when it blocks in a receive or exits, so another process
  cannot act between two sends or two ETS writes of one step.
- One run per VM. `eta_time`, `eta_log` and `eta_sched` keep state in named ETS
  tables, and a second concurrent run is refused.
- A transformed module is close to the shipped module but is not the same module.
- Elixir's `Task` and `Agent` raise under a run unless `Eta.Beam.instrument/1` has
  rewritten them.
- `gen_statem` support excludes hibernation and
  event time-outs (`{timeout, Time, Content}` or a bare integer action). Event
  time-outs raise while a clock runs. State time-outs and generic time-outs are on
  the virtual clock.
- `eta_net:call/3` uses a real monitor on the callee, in addition to a simulated
  one. A call outstanding across a partition exits with `{nodedown, Node}`.
- A monitor created before its ends are placed is a real monitor and never fires
  `noconnection`. Place the topology in `init/2`.
- `eta_net` does not emulate distribution. A simulated node is a name in a table
  in one VM. `{global, _}` and `{via, _, _}` server names are refused.
- A sort of references is stable only with one scheduler thread (`+S 1:1`).
- The cost of a choice grows with the number of live processes: one
  `process_info/2` call per live process. On `eta_2pc` with invariants off, the
  cost is 49 µs per action at 104 processes and 97 µs at 3,204.
- A change to the scheduler's handling of trace events can change the schedule
  that a seed produces. A trace recorded with an earlier version may not replay.

## Open problems

### A step can be recorded as blocked with unconsumed messages

A process that drains a preloaded mailbox in a catch-all `receive` was observed to
consume 1 of 6 queued messages and be recorded as blocked at a queue length of 5.
`blocked_at` then excludes it from `runnable_ids/1` until its queue grows past 5.
With message loss, the process can remain excluded, and the schedule diverges.

| Condition | Measurement |
|---|---|
| `drop_p = 0.0`, 40 runs of one seed | 1 schedule |
| Any message loss, 10 runs of one seed | 2 schedules, diverging at the third choice |
| `timeouts` | 0 in all runs |

No audit field reports it. The `gen_server` systems in the test suite receive
operations one at a time and have not shown it. The suspected cause is that
`await_block/3` reads `waiting` at an `out` event before the process has moved
its signal queue into its message queue. That is not confirmed. The late-arrival
change in `queue_at_block/3` handles messages that arrive after the block. These
messages were queued before the step, so that change does not obviously apply.

### Other questions

- Is `erlang:suspend_process/1` safe at scale? It is documented for debuggers.
  Runs with 34 processes (Broadway) and 3,204 registered processes (`eta_2pc`)
  have shown no defect. Supervisors and monitors at hundreds of live processes are
  not verified.
- Does Concuerror's dynamic partial-order reduction cover enough small
  executions to complement eta's sampling of long ones? Concuerror needs the
  same preconditions that eta has: no NIFs, and no distribution.
- How much of OTP needs instrumenting for a typical system? `:supervisor`,
  `Supervisor` and the libraries that spawn processes are needed. A measurement
  across several systems would answer this.
- Replay from a seed on a different machine has not been tested.

## Planned and proposed work

### Incremental runnable tracking

The scheduler reads every live process's queue length at every choice. The
scheduler already receives a `'receive'` trace event for every message that
reaches a scheduled process. A set of runnable processes maintained from those
events would make the cost of a choice independent of the number of live
processes. The events arrive asynchronously, so the design must state at which
point in a step the set is current.

### Per-run state (proposed, not built)

Runs are serial because `eta_time`, `eta_log` and `eta_sched` use named ETS
tables. Self-contained runs would allow parallel runs in one VM.

A context cannot be passed through the transform. A rewritten call in
`handle_call/3` has no argument to carry it, and a timer armed in one callback
fires into a mailbox that has no lexical relationship to the code that armed it.
The context must be ambient:

| Option | Assessment |
|---|---|
| Process dictionary | eta can set it only where eta spawns. A child that `supervisor:start_child` creates inside OTP is reported after it exists, and no process can write another process's dictionary. |
| Registry from pid to run | One global ETS table used as a directory, filled at adoption. It covers every process that `eta_sched` covers. A process that is not in the registry gets the real `erlang` functions. |

The registry is the only option that works. It changes about 60 references to the
named tables across 3 modules, 28 public functions in `eta_time`, 15 in `eta_log`
and 5 in `eta_sched`. `now_ms/0` goes from 1 ETS operation to 2, and it is on the
path of every timer operation.

It is not built, because one OS process per run already isolates runs, and also
isolates crashes and memory. The registry adds `async: true` within one ExUnit
VM. It also multiplies the unverified risk of `suspend_process/1` at scale. A
design with per-run tables behind one global "current run" pointer must be
avoided: it costs most of the rewrite and allows no parallelism.

### Demonstrate a quiet-period defect

eta has rediscovered a known defect, shrunk it and replayed it. It has not
rediscovered a defect that appears only when the system is idle, such as a
resynchronisation that only client traffic triggers. `quiet_p` and `check_final/2`
make such a defect reachable. A planted defect of that kind in a system under
test would demonstrate it.

## Alternatives considered

| Alternative | Assessment |
|---|---|
| Concuerror | Maintained systematic tester for Erlang. Explores the interleavings of small executions exhaustively. Complements eta; not a replacement. |
| PULSE | User-level scheduler with random, replayable schedules. Not maintained. Useful as a design reference. |
| Property-based testing alone | Samples inputs and does not control interleavings. |
| Transformed copies of OTP modules | Rejected: stdlib is sticky, a defect affects the whole VM, and the copies track one OTP release. eta builds equivalent processes instead. |
| Intercepting every message | Not needed for order, because one running process fixes the order. Needed only for faults, which `eta_net` provides for the pairs that a topology declares. |
