# Hazards

This page lists the hazards of running a system under `eta`. Each hazard
states what happens, the cause, and what to do. The hazards are grouped by
the part of a run that they affect.

If a seed has stopped reproducing, read
[Debugging a determinism failure](#debugging-a-determinism-failure) first.

## AI disclosure

This document is pending a human rewrite. We still expect the content to be mostly
correct.

## Debugging a determinism failure

A determinism failure is a seed that produces 2 different runs. Reading the
code is an unreliable way to find the cause. The following techniques produce
evidence instead.

- **Find which runs differ.** Run one seed 5 times and group the identical
  traces. The grouping identifies the kind of cause:

  | Grouping of the 5 runs | Meaning | Likely cause |
  |---|---|---|
  | `[[1], [2,3,4,5]]` | Only run 1 differs | Warm-up or first-touch state |
  | `[[1,3], [2], [4,5]]` | Every run can differ | A random choice on every run |

- **Vary the position of the seed.** If seed 3 fails, run the seeds in
  reverse order. If the failure moves to the seed that now runs first, the
  seed is not the variable. The cause is then the first-run problem described
  in [Code loading hazards](#code-loading-hazards).
- **Snapshot the system at the point of divergence and compare.** Capture the
  state, the mailbox contents, the process status and the timer wheel of both
  runs. The difference can be absent from the state and present in the
  mailboxes. If the mailboxes also match, log the scheduler events against
  the step boundaries: which process was scheduled in, which process was
  scheduled out, and what each process was executing.
- **Remove parts of the run.** Remove the client workload and check whether
  the system is still nondeterministic. Either result narrows the search.
- **Put the evidence in the failure message.** Add
  `inspect(eta_run:summary(Result))` to the assertion message and run the
  test in a loop until it fails. The failure then carries the summary of the
  run. This costs 1 line. It removes the cycle of forming a theory, adding a
  print statement and waiting for the next failure. The technique applies to
  every test, not only to determinism failures.

## Code loading hazards

### A module loaded during a run changes the schedule

**Symptom.** The first run in a fresh VM produces a different trace from
every later run of the same seed. No process is adopted late, the scheduler
does not time out, no warning is logged, and the accounting of the scheduler
is correct.

**Detection.** The `modules_loaded` field of a run result lists the modules
that were loaded while the scheduler controlled the run. The list must be
empty. `eta_run:audit/1` checks the field.

**Cause.** Loading a module on demand is a synchronous call to `code_server`.
The scheduler does not own `code_server`.

1. A scheduled process calls a module that is not yet loaded.
2. The process blocks on `code_server`, which is outside the schedule.
3. The scheduler treats the block as the end of the step.
4. `code_server` runs on the real scheduler and makes the process runnable
   again at a moment that the wall clock determines.
5. Every choice of the scheduler after that moment shifts.

On the second run the module is loaded and the sequence does not occur.

**Remedy.** Use the `preload` option and name the application under test.
`kernel`, `stdlib` and `eta` are always included.

```erlang
eta_run:run(my_harness, #{seed => 1, preload => [my_app]}).
```

Code that drives `eta_sched` directly, without `eta_run`, gets no preloading
and no `modules_loaded` field. Call `eta_run:preload/1` once, before the
first scheduler exists:

```erlang
ok = eta_run:preload([my_app]).
```

Running a seed twice is not a substitute for `preload`. Warming applies to a
code path, not to a VM. A seed that is the first to reach a time-out handler
runs a branch that no earlier seed ran, and loads code that no earlier seed
needed. A warm-up run fixes the seed that was warmed and does not fix the
next seed.

### Cold code can end a run early with outcome ok

**Symptom.** A run ends after very few steps and reports success. The
following result was measured on the two-phase commit example of this
project, with preloading off and a cold module that every client calls:

```
ops: 5, steps: 5, exited: 0, processes: 9, outcome: ok
```

The run took 5 steps for 5 operations. The same workload normally takes
about 100 steps.

**Cause.** To `eta_sched`, a process that waits on `code_server` is a process
blocked in a receive. The process is not runnable. If enough processes call
cold code at the same time, no process is runnable and no timer is pending.
The run then ends in a state that is indistinguishable from quiescence.

`modules_loaded` does not report this case. The loads complete after the run
has finished, so the field is empty when it is read.

**Detection.** The `sched.cold_code` field reports this case. When a run
finds no runnable process and is about to return, the scheduler looks once
for a process that is executing `code_server:call/1`. That function is a send
followed by a one-clause receive, so a process that waits on the code server
is always in that function. Each entry names the process and the stack frame
that called the cold module. The scheduler also logs a warning.

```erlang
#{sched := #{cold_code := [#{id := 3, pid := _, at := {my_client, commit, 2}}]}}
```

`at` is `undefined` when no frame can be named. This happens when the call
into the cold module was a tail call, because no frame of the caller remains
on the stack. The pid still identifies the process.

`audit/1` checks `cold_code`.

**Remedy.** Use `preload`. `cold_code` detects the problem after the fact.
When `cold_code` is not empty, the run is already invalid. The field only
replaces a guess with a report.

### code:ensure_loaded/1 on a missing module calls the code server every time

This hazard is not a warm-up effect. `code:ensure_loaded/1` returns
immediately for a module that is already loaded. For a module that does not
exist, `code:ensure_loaded/1` calls the code server on every call. A common
idiom for optional dependencies has this form:

```erlang
emit_telemetry(Event, Measurements, Metadata) ->
    case code:ensure_loaded(telemetry) of
        {module, telemetry} -> apply(telemetry, execute, [Event, Measurements, Metadata]);
        _ -> ok
    end.
```

When the optional dependency is absent, every event makes a synchronous call
to the code server. Cache the result in `persistent_term`.

### A synchronous call to an OTP service process depends on real time

Under a user-level scheduler, any synchronous call into an OTP service
process is a dependence on real time. The service processes include:

- `code_server`
- the handlers of `logger`
- `global`
- `net_kernel`
- `application_controller`

Search for `code:ensure_loaded`, `code:is_loaded` and `global:` along the
code paths that the system exercises. The search costs much less than the
instrumentation that is needed to find these calls after a failure.

The transform handles `logger`. See the next section.

### Logger calls are recorded by eta_logger

A `logger` call passes the event to a handler. The default
handler, `logger_std_h`, is a process that the scheduler does not own. Under
load, `logger_std_h` switches from asynchronous to synchronous mode. A log
call is then a synchronous call into an OTP service process. The handler runs
on the real scheduler and makes the calling process runnable again at a
moment that the seed does not determine. The load on the log handler then
determines the schedule of a system that logs heavily. The symptom is a seed
that reproduces in most runs and not in all runs.

**What eta does.** The transform rewrites every `logger` level function and
`logger:log/2,3,4` to `eta_logger`.

- While a run is collecting, `eta_logger` records the event into `eta_log`.
- When no run is collecting, `eta_logger` delegates to `logger`.

The log events of the system therefore appear in the output of
`eta_log:analyze/0`, with sequence numbers that are comparable with every
other event of the run.

`eta_logger` does not filter by level and does not run a formatter. The log
of a run is a record of what happened, not an operator console. A filter
applied at record time can discard the line that a later diagnosis needs.

## Scheduler hazards

### A plain spawn runs outside the schedule

A process created by a plain `spawn` is not adopted until the
scheduler detects the process. Until then the process runs on the real
scheduler. One such process is usually harmless. 2 such processes, created by
operations that are injected close together, race to deliver their first
messages.

**Mechanism.** A gated spawn removes the interval. The child starts blocked
on a token that only the scheduler can send. The child is therefore never
alive and unowned.

**Inside a transformed module.** The transform rewrites every local spawn
form:

- `spawn`, `spawn_link`, `spawn_monitor` and `spawn_opt`, on both `erlang`
  and `proc_lib`, qualified or bare.
- `start`, `start_link` and `start_monitor` on `gen_server` and `gen_statem`,
  at both arities. These functions spawn inside OTP, which the transform of a
  module does not reach.

**Inside `execute/2`.** The harness is not transformed. Use
`eta_run:spawn_op/1`, which uses the same mechanism:

```erlang
spawn_op(Fun) ->
    eta_sched:spawn(Fun).
```

**Ordering rule.** There is 1 gating protocol. `eta_sched:register/2`
releases a gated child. The driver calls `eta_sched:register/2` after every
operation with the list that `processes/1` returns. Operations therefore
become runnable in the order in which `processes/1` returns their processes.
No other ordering rule exists.

**Detection.** Check `sched.adopted_late` in the run result. The value must
be 0 or very close to 0.

### A process that does not seed rand gets a seed from the real clock

`rand:uniform/1` draws from a state in the process dictionary.
When a process has never seeded that state, OTP seeds it on first use from
`erlang:system_time/0` and `erlang:unique_integer/1`. The seeding happens
inside the `rand` module, which the transform of a module does not reach. For
example, a system that selects a gossip peer with
`lists:nth(rand:uniform(length(Peers)), Peers)` has a schedule that is not a
function of the seed. The run result does not report the problem:
`adopted_late` is 0, no module is loaded late, and the accounting of the
scheduler is correct. The same seed produces a different trace on every run.

**What eta does.** `eta_transform` rewrites the following calls to
`eta_rand`. `eta_rand` gives each process its own stream, derived from the
seed of the run.

| Call | Behaviour under a run |
|---|---|
| `rand:uniform/0,1`, `uniform_real/0`, `normal/0,2`, `bytes/1` | Draws from the stream of the process |
| `rand:seed/1,2` | An explicit `rand:seed(Alg, Seed)` is honoured, because it was already deterministic |
| `crypto:strong_rand_bytes/1` | The bytes come from the stream of the process. An identifier made of random bytes sorts the same way on every run of a seed. The bytes are not cryptographically strong. |

Only the process-local API is rewritten. `rand:uniform_s/1,2` and the other
`_s` functions take the state as an argument and are already deterministic.

**Limitations.** `eta_rand` does not cover:

- A draw in an untransformed module.
- A draw by a process that the scheduler is not stepping. The run result
  counts these draws as `rand.unmanaged`, and `audit/1` reports the count.
  `net.unmanaged` reports a send from outside the schedule in the same way.

### A call that waits for another process ends the step early

Some functions of the `erlang` module send a request to another process and
wait for its answer. `erlang:process_info/2` of another process is one of
them. If the other process cannot answer at once, the caller waits in a
`receive` inside the Erlang VM (`erts_internal:await_result/1`). The scheduler
then finds the caller scheduled out with the status `waiting`, which is its
test for the end of a step. It ends the step and suspends the caller in the
middle of the call. The caller continues in a later step, after the answer has
arrived as a message.

A process cannot answer at once while it runs, and while it collects garbage.
For a target outside the schedule, the wall clock decides whether that is the
case. The scheduler reports nothing: `timeouts` is 0, and `audit/1` returns
`ok`.

The scheduler checks an `out` event with `erlang:trace_delivered/1` and
continues the step if the caller ran again before the check. See "Steps" in
`eta_sched`. The check finds the answers that arrive before it. It does not
find an answer that arrives later.

Measured on Erlang/OTP 28, with that check. One step of a process that makes
the call, then writes a marker. The step ended before the marker was written in this many
trials:

| Call | Target | Early ends with `+S 1` | Early ends with `+S 4` |
|---|---|---|---|
| `process_info/2` | Outside the schedule, idle, small heap | 0 of 200 | 0 of 200 |
| `process_info/2` | Outside the schedule, idle, heap of 3,000,000 cells | 1 of 200 | 1 of 200 |
| `process_info/2` | Outside the schedule, runs a loop without allocation | 0 of 200 | 1 of 200 |
| `process_info/2` | Outside the schedule, collects 2,000,000 cells in a loop | 198 of 200 | 199 of 200 |
| `process_info/2` | Suspended by the scheduler | 0 of 200 | 0 of 200 |
| `is_process_alive/1` | Suspended by the scheduler | 0 of 200 | 0 of 200 |
| `garbage_collect/1` | Suspended by the scheduler | 62 of 200 | 6 of 200 |
| `garbage_collect/0`, heap of 30,000,000 cells | The process itself | 0 of 5 | 0 of 5 |

The effect on a schedule: 2 scheduled processes each send one message to a
third one, and the first one calls `process_info/2` of a process outside the
schedule before its send. In 200 runs of one seed:

| Target of the call | Distinct schedules | Runs of each schedule |
|---|---|---|
| No call | 1 | 200 |
| Idle | 1 | 200 |
| Collects 2,000,000 cells every 2 ms | 2 | 53 and 147 with `+S 1`, 81 and 119 with `+S 4` |

Garbage collection has no other effect that was found. With one harness of
this repository (`eta_2pc`, 40 seeds), 1,440 runs gave the trace of the plain
run under each of these conditions, with `+S 1` and with `+S 4`:

- A process outside the schedule calls `garbage_collect/1` for every process
  in a loop.
- A process outside the schedule calls `garbage_collect/1` for the driver
  process in a loop.
- A process outside the schedule allocates 40 MB in a loop.
- `fullsweep_after` is 0 for new processes.
- The driver process keeps 12,000,000 list cells alive.

**What eta does.** The transform rewrites `erlang:is_process_alive/1` to
`eta_sched:is_alive/1`, which sends no request. It does not rewrite the other
functions.

**Correction.** A scheduled process must not ask a process outside the
schedule with `process_info/2`. A harness reads state from its own process,
which the scheduler does not step. See
[Invariants must read state without calling a process](#invariants-must-read-state-without-calling-a-process).
`garbage_collect/1` of a scheduled process can divide the step of the caller.
`check_process_code/2` of a scheduled process divided the step in 60 of 60
trials with `+S 1` before the scheduler had the check with
`erlang:trace_delivered/1`. It was not measured with the check.

**Not built.** The scheduler could tell this wait from a `receive` of the
system: the current function of the caller is
`erts_internal:await_result/1`, `erlang:garbage_collect/2` or
`erts_internal:check_process_code/3`. It could then keep the step open until
the answer has arrived, or count the step in `timeouts`.

### A process that dies through a link dies outside the schedule

A VM link between two scheduled processes makes the second one die when the
first one exits, unless the second one traps exits. The second process is
suspended at that time. It dies when the VM next handles its signals, which is
not a step of the scheduler. Its own monitors and links fire after that. A
process that watches it receives its `DOWN` message at a time that the VM
chooses.

Measured on Erlang/OTP 28 with `+S 1`, under `eta_sched`. `P` exits in its
step, and `W` waits for a `DOWN` message. The table has the number of trials
in which `W` was not runnable directly after the step of `P`:

| Case | `W` not runnable, of 200 trials |
|---|---|
| `W` monitors `P` | 0 |
| `W` monitors `P`, and `P` owns an ETS table of 50,000 rows | 0 |
| `W` monitors `Y`, and `Y` is linked to `P` | 200 |
| `W` monitors `Y2`, `Y2` is linked to `Y`, and `Y` is linked to `P` | 200 |

The same without eta: a process kills `X`, waits for the `DOWN` message of
`X`, performs some work, and then reads the queue length of `W`. `W` monitors
the last process of a chain of links that starts at `X`. The table has the
number of trials of 300 in which `W` had no message:

| Chain | No work | 2,000 reductions | 5,000 reductions | 20,000 reductions |
|---|---|---|---|---|
| 1 linked process | 0 | 0 | 0 | 0 |
| 2 linked processes in a row | 300 | 300 | 0 | 0 |
| 4 linked processes in a row | 300 | 300 | 300 | 0 |
| 1 linked process that owns an ETS table of 50,000 rows | 300 | 300 | 300 | 300 |

The result depends on the number of reductions that the reading process
uses. Under a run, that process is the scheduler, so a small change of the
scheduler or of the driver can move the `DOWN` message to the other side of a
choice.

**What eta does.** `eta_net:kill_node/2` waits for the death of every process
of the node, and for the `DOWN` messages of the VM monitors on these
processes. It does not follow VM links from a dying process to a surviving
process. A step in which a process exits waits for nothing after the exit.

**Detection.** None. The run result reports nothing.

**Correction.** Not built. The scheduler could wait, after a step or a kill
with an exit, until every process that has started to exit is no longer in
`erlang:processes/0`, then make every live process handle its signals with
`process_info/2`, and repeat this while new exits appear.

### The order of pids changes after about one million processes

The term order of pids is their creation order only in a young VM. After the
VM has created about as many processes as its process limit, it reuses pid
values, and a new process can have a pid that compares below the pid of an
older process. `erlang:system_info(process_limit)` is 1,048,576 by default.

Measured on Erlang/OTP 28 with `+S 1`: of 2,500,000 processes that were
spawned one after another, the process number 1,048,490 was the first with a
pid below the pid of its predecessor.

A system or a harness that depends on the order of pids then has a schedule
that depends on the number of processes that the VM created before the run.
Examples of such a dependence:

- `lists:sort/1` or `lists:usort/1` on a list of pids, or on tuples that have a
  pid before the field that was meant to decide the order.
- An `ordered_set` table, a `gb_trees` tree or an `orddict` with pids as keys.
- A comparison of two pids to choose a leader or a winner.

The symptom is a determinism test that passes alone and fails late in a long
test run of one VM. The seed that fails changes when tests are added or
removed. No field of `audit/1` reports the problem.

This was found with a harness that listed its replicas with
`lists:sort(ets:match(Tab, {{replica, '_'}, '$1', '$2'}))`, where `'$1'` is a
pid. The list was in the order of the pids. A determinism test with 45 seeds
and 2 kinds of run, 3 runs and 1 replay for each, failed at one of the last 5
seeds in every run of the test. The VM had then created 1,064,936 processes.
The same test with 6 seeds passed.

**Detection.** `sched.pid_reuse` in the run result counts the processes whose
pid compares below the pid of a process that was created earlier in the run.
The value is 0 in a young VM. A value above 0 means that the order of pids is
not the creation order in this run.

**Correction.** Either of the following:

- Do not order by pid. Order by a value that the system assigns, such as a
  name or the number of a replica. A harness can use the ids of
  `eta_sched:ids/1`, which follow the order of registration.
- Start a new VM before the VM has created one million processes. A test
  suite that runs each test in a VM of its own usually stays below the limit.
  A run of about 500 processes reaches the limit after about 2,000 runs.

### Distributed spawns work only between simulated nodes

`spawn(Node, Fun)` and the related forms request a process on another node.

**Caller and target both on simulated nodes.** The spawn is simulated in the
way that `eta_rpc` simulates an `rpc`:

- The child is a gated spawn placed on `Node`. `node()` in the child returns
  `Node`, and the child uses the registered names of `Node`.
- The spawn connects the 2 nodes first.
- A spawn across a cut still returns a pid. The child exits with
  `noconnection` as soon as it runs. A caller that links to or monitors the
  child receives the same exit in a real cluster.

**Any other case.** No correct rewrite exists. Running the child locally
places it on the wrong node. Passing the spawn through places the child
outside the schedule. A spawn from a process that is on no simulated node, or
a spawn to a node that is not in the simulated network, therefore raises while a
run is active:

```erlang
{eta_sched, {no_distribution, {erlang, spawn, 2},
             <<"eta simulates distribution only between simulated nodes; place the caller and the target with eta_net">>}}
```

When no run is in progress, these forms delegate to the original functions. A
module built with the transform therefore works normally outside a
simulation.

The transform rewrites the bare forms as well as the qualified forms, because
all of them are auto-imported. Without the rewrite, a bare
`spawn(Node, M, F, A)` would run ungated and would appear only in
`adopted_late`.

### The scheduler is unverified above a few hundred processes

The scheduler is built on `erlang:suspend_process/1`, which OTP documents as
a function for debuggers.

| Number of processes | Status |
|---|---|
| 3 | Works |
| A few hundred | Works |
| Thousands, with supervisors and monitors | Unverified |

Verify the behaviour before building a simulation of a very large system.

### A VM holds one clock, one log and one scheduler

The clock, the log and the scheduler each keep their state in named ETS
tables. Exactly one of each exists per VM, so runs must be serial. Keep the
tests `async: false`.

Starting a second clock, log or scheduler while a live process holds the
first is refused. The error names the owner:

```erlang
{eta_time, {clock_in_use, <0.312.0>,
            <<"one per VM; keep runs serial (`async: false`) ...">>}}
```

To run simulations in parallel, isolate each simulation in its own VM, not in
its own test process. Run the seeds in separate OS processes. Separate OS
processes also isolate crashes and memory. See
[Per-run state](design.md#per-run-state-proposed-not-built) for the reasons
that per-run state inside one VM is a large change.

## Time hazards

### The wall clock is derived from the seed

`eta_time:system_time/1` and `os:timestamp/0` return a plausible wall-clock
time. `eta_run` starts the clock with a `system_ms` value that is derived
from the seed.

**Reason.** If the wall clock were anchored to the real start time, a system
that seeds `rand` from `os:timestamp/0` would carry the real start time into
its schedule. The claimant of `riak_core` seeds `rand` this way. A run and
its replay would then diverge.

**What to do.** Code that drives `eta_time` directly must pass `system_ms`
itself if the system reads the wall clock in this way.

### The clock must start before the system

A timer that is armed while `eta_time` is inert goes onto the real clock. The
timer stays on the real clock until it fires and is armed again. A timer with
a long period would therefore not become virtual during a run.

`eta_run` starts the clock before the system. This is the reason that the
driver calls `init/2`, and that the test does not call `init/2` beforehand.

### receive ... after is rewritten by default

`eta_transform` rewrites calls, and `after` is a language construct, not a
call. The rewrite is still possible, because `receive Cs after T -> B end` is
an abstract form like any other form. The transform rewrites it into a
receive whose time-out is an ordinary message clause on the virtual clock.

| Case | Behaviour |
|---|---|
| Default | Every `receive ... after` in a transformed module is rewritten |
| `-eta_after(false).` | The module is not rewritten. Use it for a hot receive loop in which the cost of arming and cancelling a timer per receive is measurable. |
| `after 0` | Never rewritten, because it is a mailbox poll and not a wait |

The rewrite is on by default because `after` is the one dependence on real
time that a system can hold without naming a function. If the rewrite
required an attribute, a module without the attribute would wake on the wall
clock and no field would report it.

### gen_statem event time-outs raise

| Time-out action | Behaviour while a clock is running |
|---|---|
| State time-out: `{state_timeout, T, Content}` | On the virtual clock |
| Generic time-out: `{{timeout, Name}, T, Content}` | On the virtual clock |
| Event time-out: `{timeout, T, Content}` or a bare integer action | Raises |
| A time-out of 0 | Left to `gen_statem`. See [Cancellation rules of a state time-out](#cancellation-rules-of-a-state-time-out). |

**State and generic time-outs.** `gen_statem` arms these time-outs with
`erlang:start_timer` inside `gen_statem`, which the transform of a module
does not reach. `eta` removes the action from the action list that the
callback returns, before OTP receives the list, and arms a virtual deadline in
its place. No option enables this, and the callback code does not change. A
generic time-out is kept per name and is delivered as a `{timeout, Name}`
event.

Without this handling, the timer would go into the timer wheel of the VM and
not into the timer wheel of `eta_time`. The timer would not be counted as a
stray timer and no warning would be logged. A machine that waits on a
30-second election period would not proceed in virtual time, and the wall
clock would order the events that follow.

**Event time-outs.** An event time-out cannot be left on the real clock, and
it cannot be virtualised. Every event that a `gen_statem` processes cancels a
running event time-out. Delivering a virtual state time-out or generic
time-out uses one event. In a machine that used both, the deliveries made by
`eta` would cancel the event time-outs of the machine. Use `state_timeout` or
a generic time-out. `state_timeout` fits most uses of an event time-out.

### gen_fsm time-outs are on the virtual clock

`gen_fsm` is deprecated and is still common in older code. The metadata
exchange of `riak_core` is one example.

The time-out of a `gen_fsm` is the `after` of the `receive` in the loop of
`gen_fsm`, which the transform of a module does not reach. `eta` handles it
in the same way as `state_timeout`: `eta` takes the `Timeout` off the return
value of the callback before OTP receives it, and arms a virtual deadline
instead. Delivery needs no extra mechanism. `gen_fsm` already dispatches a
`{timeout, Ref, {'$gen_event', Event}}` message to the state function as
`Event`. `send_event_after/2` of `gen_fsm` produces a message of the same
shape.

`eta` keeps 2 rules of `gen_fsm`:

- **Any message cancels the time-out.** A state change is not required. A
  machine that means "do this unless something arrives first" gets that
  behaviour. A machine that means "do this in 5 seconds regardless" must use
  `send_event_after/2`.
- **A state function that calls another state function directly arms the
  time-out that the inner function returns.** An example is
  `prepare(Ev, S) -> update(start, S)`. The wrapper around the outer function
  receives a return value with no time-out. The wrapper leaves the time-out of
  the inner function armed, because that time-out was not pending when the
  outer call began.

| `gen_fsm` feature | Behaviour |
|---|---|
| `{ok, S, D, Timeout}` from `init/1` | The time-out is read |
| `{reply, R, S, D, Timeout}` | The time-out is read |
| `{next_state, S, D, Timeout}` | The time-out is read |
| `hibernate` | Raises |
| Synchronous events (`sync_send_event` and the related functions) | Raise while a network is running, because the reply is not yet routed through the network |
| `send_event/2` and `send_all_state_event/2` | Routed like casts |

### Cancellation rules of a state time-out

These are the rules of `gen_statem`. They apply with or without `eta`, and
`eta` reproduces them exactly.

- **A state change cancels the time-out.** `keep_state`,
  `keep_state_and_data`, `repeat_state`, `repeat_state_and_data` and
  `{next_state, SameState, _}` do not cancel it. The comparison is `=:=` on
  the state term.
- **A new action replaces the deadline.** A follower that arms its election
  deadline again on every heartbeat depends on both rules: `keep_state` does
  not cancel, and the new action replaces the deadline.
- **`{state_timeout, update, Content}` with no time-out running is not an
  error.** It delivers the event immediately. `gen_statem` documents this as
  deliberate.
- **A time-out that is cancelled after its timer fired produces no event.**
  It does not produce a discarded event either.
- **`{state_timeout, 0, Msg}` is delivered when the event queue is empty.**
  That moment is after any event inserted with `next_event`, after any
  postponed event, and before the next message is taken from the mailbox. The
  time-out can still be cancelled while it waits. A machine can therefore
  express "do this next, unless one of those events changes the state first".

Because of the last rule, `eta` leaves a time-out of 0 with `gen_statem` and
does not virtualise it. A time-out of 0 reads no clock, so it has nothing to
virtualise. No substitute reproduces both its position in the queue and its
cancellation.

`test/support/eta_elect.erl` is a leader election written against these
rules. `test/eta_state_timeout_test.exs` has one test for each rule.

### timer:sleep/1 in an untransformed module hangs the process

**In a transformed module.** A sleep is `receive after T -> ok end` inside
the `timer` module of OTP, which the transform of a module does not reach.
The transform rewrites the call site instead. `timer:sleep/1` becomes
`eta_time:sleep/1`, which arms a virtual deadline. The driver advances the
clock to that deadline like any other deadline. When no clock is running,
`eta_time:sleep/1` is a real sleep. Every other rewrite behaves the same way
without a clock.

**In an untransformed module.** The sleep stays real and the process hangs.
The process is blocked on a time-out, not on a message. `eta_sched` determines
which process is runnable by inspecting mailboxes. The mailbox of the
sleeping process is empty, so `eta_sched` never steps the process. Only the
real clock can end the wait, and the driver does not control the real clock.

**In the driver.** Do not execute a transformed sleep on the process of the
driver. The clock advances only to the deadlines of processes that the
scheduler can step. A sleep on the process of the driver arms a deadline that
the clock never reaches. This is the rule of
[A call from the driver keeps its real time-out](#a-call-from-the-driver-keeps-its-real-time-out).

### A system with periodic timers never becomes quiescent

A system with heartbeats never reaches the state "no process is runnable and
no timer is pending". Without a bounded settle phase, such a run can end only
at the step budget. The step budget is reported as an error, so every run
would be reported as a failure.

The `settle_steps` option bounds the settle phase. The settle phase is also
the only part of a run in which the invariants are checked with no client
traffic.

### A timer can belong to a process that the scheduler does not own

A timer belongs to a process, and the scheduler does not
necessarily own that process. The timer is still in the timer wheel. A driver
that advanced to the earliest deadline would move the clock for a process
that can never take a step. 2 runs of one seed would then differ by an
inserted `{clock, Ms}` entry with no step after it, several hundred entries
into the trace.

**Causes.** A stray timer has 2 ordinary causes:

- A process is killed while it is blocked in a rewritten `receive ... after`.
  The process never reaches the clause head that disarms the timer, so the
  deadline remains after the process has exited.
- A process is spawned before the scheduler exists. Every process that the
  system starts during `init/2` is in this category and is outside the
  schedule.

**What eta does.** `eta` steps over such a deadline and does not advance the
clock to it. A stray timer therefore does not change the schedule. The run
result reports the count as `stray_timers`, and `audit/1` checks it.

**What to do.** A count above 0 means that a process holds a timer and that
the scheduler will never schedule that process. Either return the process
from `processes/1`, so that it becomes part of the run, or do not start the
process in `init/2`.

### Time-outs in an untransformed module are on the real clock

**Untransformed module.** If a client-facing module is deliberately left
untransformed, its `gen_server:call` time-outs are real. Under the scheduler,
a client is suspended between steps, so the wall clock determines when the call
times out. The usual workaround is to configure a time-out that is too long
to fire during a run. The workaround removes the behaviour that the time-out
guards from the behaviour under test.

**Transformed module.** The call time-outs of a transformed module are
virtual whenever a clock is running. A network is not required. With a
scheduler and a clock and with `net => false`, a call does not wait for the
real 5-second `after` inside OTP.

### A call from the driver keeps its real time-out

This is the exception to the previous section. `eta_run` advances the clock
only to a deadline that belongs to a process it can step. `eta_run` steps
over every other deadline as a stray timer. A virtual deadline armed by the
driver would never be reached: the driver would be blocked on a time-out that
only the driver can deliver.

A call made from `execute/2` or `check/1` therefore keeps its real time-out.
The underlying rule is that `execute/2` and `check/1` must not call into a
scheduled process. `eta_harness` documents the reason. A harness that breaks
the rule gets an exit after 5 seconds of real time, not a run that cannot
finish.

### A virtual call time-out means that nothing could make progress

**Meaning.** The clock moves only when no process is runnable. A virtual call
time-out therefore fires exactly when the system reached a state in which no
process could make progress, and the time-out was the earliest deadline. In
production, a time-out usually means that a process was slow. The virtual
time-out is a stronger statement. It detects lost messages and deadlocks
well.

**A slow callee does not exist under a virtual clock.** Computation takes no
virtual time. The race in which a caller gives up and the reply arrives
immediately afterwards is reachable only through a timer or a network delay.
It is not reachable through a slow callee. To find that race, use `skew_ms`
or a lossy network policy. A time-out alone does not find it.

**Time-out values order events.** The clock moves from deadline to deadline.
A time-out value therefore orders the time-out against every heartbeat, lease
and retry in the system. Every default call time-out is 5000 ms, so the
defaults share one deadline and fire in creation order, which is the same on
every run. `skew_ms` breaks the tie. `skew_ms` applies to receive deadlines
and call deadlines as well as to the timers that the system sets.

**`drop_p` does not apply to these deadlines.** This is deliberate. A timer
that the system sets to fire at another process can be lost together with
that process. A deadline that a process arms for itself cannot be lost.
Dropping such a deadline would produce a hang that resembles a finding and is
not one.

## Observability hazards

### Invariants must read state without calling a process

This hazard is described on the
[previous page](04-writing-a-system-under-test.md). It is repeated here
because the failure produces no error.

- **Symptom.** The invariant passes and has checked nothing.
- **Cause.** A client API that catches its own call time-out returns a
  plausible answer for a suspended process. The invariant computes over that
  answer.
- **Detection.** `eta_run` bounds `check/1` and `check_final/2` with the
  `check_timeout` option, which defaults to 5000 ms of real time. When the
  bound is exceeded, the run ends with `{error, check_blocked}`. `eta_run`
  cannot detect the case in which the API returns an answer.
- **Remedy.** Read the state without a call to a scheduled process.

### The duration of a stall identifies its cause

When a call hangs, measure the duration of each stall.

| Duration of the stall | Cause |
|---|---|
| Exactly the time-out, every time | A lost wakeup: a message that never arrived or a watch that never fired |
| Variable | Contention |

Example: some call time-outs against the in-memory backend of this project
were first diagnosed as a retry livelock. The distribution of the durations
showed a different cause. A watch was anchored to the wrong version.

### A deterministic substitute must be compared with the real implementation

An in-memory replacement for a database is a large piece of code that must
behave exactly like the database. If the substitute is wrong, every finding
that it produces is in doubt. A wrong substitute is therefore worse than no
substitute.

Run the same operations against both implementations and compare the results.
Every defect found in the in-memory backend of this project was found this
way. No defect was found by reading the code.

Most of those defects concerned version equality. "Did this key change after
my read version?" and "should this watch fire?" are both questions about a
boundary. A commit that lands exactly on the boundary is the case that is
most often implemented wrongly. The results are a conflict that is not
detected and a watch that never fires.

## Workload and trace hazards

### Operations must be stable across runs

An operation that carries a generated name, a pid or a reference makes the
trace incomparable between runs. The trace also cannot be replayed against a
fresh system. The symptom is a trace difference at a very early index, which
has the same appearance as a scheduling divergence. See also
[Operations must not carry pids](#operations-must-not-carry-pids).

### The trace must record every action of the driver

The driver takes 3 kinds of action, and the trace has an entry type for each:

| Trace entry | Action of the driver |
|---|---|
| `{step, Id}` | Step a process |
| `{op, Op}` | Inject an operation |
| `{clock, Ms}` | Advance the clock |

**Reason for `{clock, Ms}`.** The clock is a function of the timers, and the
timers are a function of the schedule. This does not make the clock entry
redundant, because `replay/3` walks only the entries that it is given.
Without clock entries:

1. A trace from a system with timers is replayed against a clock that never
   moves.
2. No process becomes runnable, and every recorded step is refused.
3. A strict replay fails at entry 0.
4. `eta_shrink` reports "nothing to shrink" for a real failure, because
   `eta_shrink` replays the trace to classify it and receives a clean run.

**Rule for tests of replay.** Two different claims can both be described as
"replay works":

- Running the same seed again reproduces the run. This exercises `run/2`.
- Replaying a recorded trace reproduces the run. This exercises `replay/3`.

Test both claims. Test `replay/3` against a system that has timers.

### A regression test pinned to a seed depends on the generator

A seed identifies a schedule only for one particular
`generate/2`. After a change to the operation mix, every pinned seed tests a
different schedule.

| Assertion of the test | Result after `generate/2` changes |
|---|---|
| Asserts a violation | The test fails, so the change is visible |
| Asserts `ok` | The test passes and no longer tests the original schedule. No error is reported. |

**Remedy.** Pin the trace. `replay/3` never calls `generate/2`. It walks the
entries that it is given, so a saved trace is unaffected by a rewritten
workload.

```erlang
%% once, from a shrink whose `verified` was true
{ok, _Outcome} = eta_run:save_fixture("test/fixtures/atomicity.eta",
                                      my_harness, Trace, Opts),

%% in the test, forever after
#{outcome := {violation, #{property := atomicity}}} =
    eta_run:replay_fixture("test/fixtures/atomicity.eta").
```

`save_fixture/4` replays the trace strictly before it writes the file, and
does not write the file on a divergence. A fixture on disk has therefore been
shown to reproduce. `save_fixture/4` stores the harness and the options with the
trace. The options are as necessary as the trace: a reproduction that needs
`config => #{mode => broken}` does not reproduce when it is replayed without
that option.

**Rule.**

- Pin a seed to test that seeds reproduce.
- Pin a trace to test for the regression of a defect.

**Limitation.** A failing trace cannot be replayed against a fixed
implementation to show that the fix works. The replay does not report `ok`.
The fix changes which messages exist, so the recorded step ids are no longer
runnable, and the replay returns `{error, {diverged, _, _}}`. "The fix works"
is a claim about the whole system. Use a seed sweep to test it.

## Fault injection hazards

### A seeded fault schedule starts where the seed is applied

**Symptom.** A seed reproduces exactly up to the first injected fault and
never after it.

**Cause.** A simulated network draws from its seeded generator once for each
message that the policy applies to. The policy is usually installed after the
cluster is up, so that no member is partitioned before it has synchronised.
The startup traffic of the cluster has then already consumed draws. Startup
runs on the real scheduler, and both the order and the number of its messages
vary. The fault schedule therefore begins at an offset that differs on every
run.

**Remedy.** Any draw from the generator before the run begins offsets the
fault schedule, and no error is reported. Reseed when the run starts. Assert
that the fault schedule is a function of the seed. Do not assume it.

### Inject only faults that a real system can observe

**Reordering within a pair of processes is not a valid fault.** Erlang
guarantees that messages between an ordered pair of processes arrive in send
order. Erlang does not guarantee delivery. Dropping messages is therefore a
faithful model of a failing link. Reordering messages within a pair is not.
Every defect found by injecting such reordering is a false positive.

**A dropped message without a node event is not a valid fault.** Dropping a
message models a link failure. A real link failure also delivers `nodedown`
and `nodeup` to both sides, and systems attach their recovery to those
signals. Dropping messages without delivering the node event injects a
condition that no real network produces: messages are lost while both ends
still consider the link up. An unrecovered state found this way is not a
defect. `eta_net:partition/2` delivers the node event to every process that
subscribed with `net_kernel:monitor_nodes/1`. A system that monitors nodes in
the usual way therefore receives the event without any action by the harness.

**Recovery can repair the divergence under observation.** When the node event
is delivered, recovery may repair the divergence that the run was meant to
observe. In the process registry that was tested with `eta`, a rejoin makes
the leader send a fresh snapshot to the member. A run that asserts a property
during a fault must restrict the loss to a channel whose recovery is
self-contained.

### A second fault reduces the detection rate of the first

Adding a second fault reduces the search efficiency for the first fault.
Operations that time out never complete, and only a completed operation can
violate a safety property.

Measured on a quorum register, with a workload that reproduces a write-back
defect:

| Workload | Seeds that reproduced the defect | First failing seed |
|---|---|---|
| Without the replica-pause fault | 21 of 200 | 6 |
| With the replica-pause fault | 12 of 200 | 53 |

Before the pause rate was retuned, the effect was total. The crashed-writer
fault, which made the defect reachable, did not appear in the event log at
all. Not one crashed-writer operation completed.

The previous section concerns faults that a real system could never observe.
This section concerns the opposite failure, which also reports no error. With
too many faults, the suite passes because no operation that could violate a
property completes.

### A workload is injected at virtual time zero

Read this section before injecting a fault that has a duration.

The virtual clock advances only when no process is runnable. The driver
injects and steps throughout the workload. An entire `max_ops` workload is
therefore typically injected while the clock still reads 0. A fault that
lasts about as long as a run is active either for the whole run or for none
of it.

Such a fault therefore has a bimodal effect. 10 seeds of a 3-replica register
with a 10-second pause gave give-up counts of
`0, 0, 0, 0, 0, 0, 9, 9, 11, 12`. A lower fault rate makes the jammed runs
less frequent. It does not make a jammed run less severe.

## Distribution hazards

### All simulated nodes share one VM

`eta_net` provides the results of `node()` and `nodes()` and the events of
`net_kernel`. Each
simulated node has its own registered names, named ETS tables and
`persistent_term` keys (see `eta_ns`). A system therefore runs under the same
names on every node, as it does on a real cluster.

Three things still exist once per VM:

- **Applications.** `application_controller` is shared, so an application
  cannot be started once per node. Start the top supervisor of the
  application on each node instead. Start the application itself before the
  run only if the system requires it to be running. `eta_app` reports
  whether an application is running, without a call.
- **Processes that the VM started.** A node that looks up a name it has not
  registered finds the process of that name in the VM, if one exists. That
  process runs outside the schedule. If the applications of the system are
  running in the VM, a node can reach them while its own copies are still
  starting, and seeds stop reproducing. `mix test` starts the applications.
  Run with `--no-start`.
- **Code that is not rewritten.** A name passed to a module that the
  transform has not processed is looked up in the namespace of the VM.
  Instrument the dependencies too.

### node(X) in a guard is refused at compile time

| Guard expression | Behaviour |
|---|---|
| `node()` | Accepted. The transform reads the node immediately before the clauses are tried. |
| `node(Pid)` | Refused. The transform rejects the module and reports the line number. |

The pattern of the clause usually binds the pid, so the transform has no
earlier point at which to read the node of the pid. If the guard were left
unchanged, it would read the real node, which is the same for every simulated
node. Move the test into the body:

```elixir
# Refused:
defp exit_local(pid) when node(pid) == node(), do: Process.exit(pid, :kill)

# Fine:
defp exit_local(pid), do: if(node(pid) == node(), do: Process.exit(pid, :kill))
```

### A healed partition does not reconnect nodes

On a real cluster, a healed network leaves the nodes disconnected until some
code connects them. That code is usually a reconnect loop or a library such
as libcluster. `eta_net` behaves the same way. After `heal_partition/2`, a
node is connected again only when one of its processes calls `connect_node/1`
or sends without `noconnect`.

A system that always sends with `noconnect` and has no reconnect loop stays
disconnected. A run that ends in that state reports a divergence that is real
for that system. If the production cluster has a reconnect loop that the
system under test does not have, add one to the harness.

Nodes also start disconnected, for the same reason. Connect the nodes after
the system on each node is up, as the discovery mechanism of a cluster would.
Otherwise peers reach a node before the node is ready to receive from them.

## Shrinking hazards

### Violations need a property key

By default, `eta_shrink` determines whether 2 failures are the same failure as
follows:

- If the violation has a `property` key, the failures are the same when the
  keys are equal.
- If the violation has no `property` key, any violation counts as the same
  failure.

With more than one invariant and no `property` key, `eta_shrink` can shrink
one defect into a different defect. That result is worse than no shrink,
because it appears to be a valid minimal trace. Give every violation a
`property` key.

## Elixir hazards

### Task and Agent raise while a scheduler is active

`Task` and `Agent` spawn and wait inside the Elixir standard library, where
the scheduler cannot gate them:

- A `Task.async/1` child would run outside the schedule.
- A `Task.await/2` is a `receive ... after` in a module that no transform
  processed, so it would wait on the real clock.

The transform rewrites every entry point. While a scheduler is active, the
entry point raises `{eta_sched, {unsupported, {Task, :async, 1}, ...}}`.
Otherwise the entry point calls the original function, so ordinary builds and
tests are unaffected.

Under simulation, use one of the following:

- A plain `spawn/1`, which is gated.
- A `GenServer`.
- Instrumented `Task` and `Agent` modules. See the next section.

### Dependencies must be instrumented

`use Eta` applies only to code that the project can edit. A
system also runs on dependencies: `Registry`, `Supervisor`, `Task`, `:pg` and
`:supervisor` of OTP. A process that one of these modules spawns is adopted
and never released. The mailbox of the process is empty, so the process never
becomes runnable. The run ends with the appearance of a quiescent system and
reports no error.

**Remedy.** `Eta.Beam.instrument/1` rewrites the modules in memory, once per
VM, before the first run:

```elixir
Eta.Beam.instrument([:supervisor, Supervisor, Supervisor.Default, DynamicSupervisor,
                     Registry, Registry.Partition, Registry.Supervisor,
                     Task, Task.Supervisor, Task.Supervised, Enum])
```

No file on disk changes, and the rewrites are inert outside a run. `Enum` is
in the list because `Enum.shuffle/1` and `Enum.random/1` draw from `:rand`
inside the standard library.

**OTP 28.** Instrument `:supervisor` even if every child starts without it.
The sequence without instrumentation is:

1. A supervisor handles a call.
2. The supervisor requests hibernation from `gen_server` after 1 idle second.
3. `gen_server` arms a real timer for the hibernation.
4. When the timer fires, the supervisor becomes runnable at whatever step the
   run has reached.
5. A run that started a child late does not replay.

The instrumented `:supervisor` never requests hibernation.

### Operation bodies must be in a transformed module

A harness is driver code and has no `use Eta`. A function passed to
`eta_run:spawn_op/1` runs as part of the system. If that function is written
in the harness:

- Its `Process.sleep/1` is on the real clock, so the process does not wake
  during a virtual run.
- Its `GenServer.call/2` is not routed.

Put operation bodies in a module that has `use Eta`.

### Operations must not carry pids

A trace records operations, and a replay executes them again. A pid in an
operation is a pid from the original run. The replay then acts on a dead
process and diverges on every seed. Refer to a process by an id that the
harness keeps, and resolve the id in `execute/2`.

The same rule applies to the values that a test compares after a replay. A
value derived from `:erlang.unique_integer/0` differs between a run and its
replay. Compare the `property` of a violation, not the whole detail of the
violation.

### The workload must be spread over virtual time

`eta_run` injects an operation whenever no process is runnable. At the
default `quiet_p`, a whole workload can be injected within the first virtual
second. A partition then heals before any process could detect it, and the
run passes.

1. Raise `quiet_p` until time passes between operations.
2. Count the events that the scenario exists to cause.
3. Assert that each event happened.

A scenario whose failure detector never fired has tested nothing, and no
invariant reports that.

### A seed must be checked in a fresh VM

A strict replay in the same VM is weaker evidence than it
appears. Reference values and pid values differ between VMs. A run can depend
on those values without leaving the schedule. In that case `audit/1` passes
and the replay passes.

**What to do.**

- Run the seed twice, in 2 fresh VMs, and compare the traces.
- Run the seed alone as well. Teardown happens in real time, so a run can
  inherit the pid values and reference values that the previous run left.
- If the system compares references, or keeps references in keys that it
  iterates, start the VM with one scheduler:
  `ELIXIR_ERL_OPTIONS="+S 1:1"`. Each scheduler thread makes references in
  its own sequence. With several scheduler threads, a seed can take either of
  2 paths at random. Setting `schedulers_online` from inside a running VM did
  not fix this when it was tried.

### Killing a supervision tree is not one event

`Process.exit(supervisor, :kill)` propagates through links in
real time, outside any step. The wall clock therefore determines which processes
are alive at the next decision of the scheduler. The run reproduces for most
seeds and diverges on a few.

**Remedy.** Kill the whole tree from `execute/2`, while every process is
suspended, and wait for each `DOWN`.

| Configuration | Method |
|---|---|
| With a network | `eta_net:kill_node/2` |
| Without a network | Walk the links, kill each process, wait for each `DOWN`, and call `eta_time:forget/1` on each pid |

### Standard library functions outside the rewrite tables are outside the transform

This is the general rule behind
[Task and Agent raise while a scheduler is active](#task-and-agent-raise-while-a-scheduler-is-active).
An Elixir standard library function that spawns, sleeps or reads a clock
inside its own implementation is outside the transform, unless the rewrite
tables name the function.

| Function | Status |
|---|---|
| `GenServer`, the clock reads of `System`, the calendar constructors | Named in the rewrite tables |
| `Process.send_after/3` and the related functions | The compiler inlines them into calls that the Erlang rewrite tables cover |

When in doubt, inspect the compiled module. The imports of a beam file list
every module that the module calls:

```elixir
{:ok, {_, [imports: imports]}} = :beam_lib.chunks(~c"path/to.beam", [:imports])
```

If the imports of a transformed module still include `Elixir.Task`, or a
library that wraps `Task`, the module has a channel that the schedule does
not control.

### A stamped beam keeps the old transform after an eta upgrade

`mix compile.eta` stamps every beam file that it rewrites, and skips a
stamped beam file. The skip makes the pass safe to run repeatedly.

An upgrade of `eta` does not make Mix recompile the modules of the project. A
stamped beam file carries the transform of the previous `eta` version until
its source changes. After a change to the `eta` dependency, run
`mix compile --force` in the `:dst` environment.

## Teardown hazards

- **An `on_exit` cleanup races the cleanup of the VM.** An ETS table is owned
  by the process that created it. A cluster that is linked to the test
  process is already dead when `on_exit` runs.
- **Kill client processes before deleting the tables that they write to.** By
  teardown the scheduler has been released, so every process that was
  suspended is running again. A client that reaches its `ets:insert` after
  the table has been deleted crashes with a `badarg`. That crash is unrelated
  to the run.
- **Do not edit source files while background test runs are in progress.**

## Verifying a fix

2 clean runs are not evidence that an intermittent failure is fixed. The
evidence is a test that fails deterministically before the fix and passes
after the fix. If no such test can be produced, the diagnosis is not
finished.

## Next

[A Journey Through DST](06-a-journey-through-dst.md) is a complete
walkthrough. It starts from an empty directory and builds a quorum register
with a planted defect. It ends with a minimized, replayable failure and the
log that explains the failure.
