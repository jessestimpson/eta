# Writing a system under test

The two-phase commit example is small, and each of its harness callbacks is
short. For a larger system, the harness is the smaller part of the work of
adopting DST. The larger part is:

- making the state of the system observable,
- writing invariants that are correct.

The examples on this page come from a process registry that was tested with
`eta`. Several nodes each hold a replica of a `name -> pid` map. One elected
leader applies every change.

## AI disclosure

This document is pending a human rewrite. We still expect the content to be mostly
correct.

## Harness contract

```erlang
-callback init(Seed :: integer(), Config :: map()) -> {ok, state()}.
-callback processes(state()) -> [pid()].
-callback generate(state(), rand:state()) -> {op(), rand:state()}.
-callback execute(op(), state()) -> state().
-callback check(state()) -> ok | {violation, violation()}.
-callback terminate(state()) -> ok.

%% optional
-callback labels(state()) -> #{pid() => term()}.
-callback check_final(settled(), state()) -> ok | {violation, violation()}.
-callback settle_done(state()) -> boolean().
```

`state()` is any term. A map is conventional.

A harness is not the system under test. The system under test is the
`gen_server` modules and the protocol code of the project. The harness is an
adapter that does 4 things:

- It starts the system.
- It declares which processes to schedule.
- It drives the system with a workload.
- It checks the system against invariants.

The modules that ship include the `eta.hrl` wrapper header (in Elixir,
`use Eta`) and use `?ETA_LOG`. For these modules it matters that the macros
emit nothing in a release build.

A harness does not ship. It is compiled only under the simulation profile. A
harness can include the header, but it does not need the transform:

- The harness runs in the driver process, not under the scheduler, so the
  calls of the harness are never rewritten.
- The harness can call `eta_log:label/1`, `eta_log:log/1` and
  `eta_run:spawn_op/1` directly, in Erlang and in Elixir.

## init/2

`init/2` must return a system that is idle. Any work that is still in
progress when the driver takes control ran on the real scheduler. The effects
of that work occur at a point in the schedule that the seed did not
determine.

Idle is a stronger condition than ready:

- Ready means that the system can accept work. The startup helper of a
  cluster typically waits until every node reports that it is ready: a
  leader is elected and the initial sync is complete. That condition is
  correct for a client.
- Idle means that the system is doing no work.

A member can be ready while an unanswered call is still in its mailbox. In
the registry, about 1 start in 5 returned a member in that state.

When `init/2` returns a system that is not idle, the wall clock decides the
first steps of the run. The defect is hard to diagnose from state. The
leader, the epoch, the applied version and the complete timer wheel can be
identical between 2 runs that later diverge. The difference is in the
mailboxes and in the process status, so the check must read those:

```elixir
defp await_quiescent(cluster, attempts) do
  busy =
    for pid <- processes_to_check(cluster),
        {:status, st} = Process.info(pid, :status),
        {:message_queue_len, n} = Process.info(pid, :message_queue_len),
        st != :waiting or n > 0,
        do: pid

  if busy == [] do
    :ok
  else
    Process.sleep(1)
    await_quiescent(cluster, attempts - 1)
  end
end
```

This function polls on the real clock. Polling on the real clock is correct
in `init/2`, because `init/2` runs before the scheduler exists. No other part
of a run may depend on the wall clock.

Check every process that holds messages for the system, not only the
supervision tree of the system. For example, a simulated network process
that holds an undelivered startup cast is not idle. The set of processes
that have a message waiting when the scheduler takes control is the initial
state of the run.

## processes/1

The scheduler assigns ids in registration order, and the trace records ids.
The order of the list that `processes/1` returns is therefore part of the
contract. Two runs that register processes in different orders cannot be
compared. Their traces differ from an early entry, and the difference has
the same appearance as a scheduling divergence.

```elixir
def processes(%{cluster: cluster, clients: clients}) do
  tree =
    for m <- Enum.sort_by(Map.values(cluster.members), & &1.index),
        {_id, pid, _type, _mods} <- Supervisor.which_children(m.sup),
        is_pid(pid),
        do: pid

  [cluster.net | tree] ++ Enum.filter(clients, &Process.alive?/1)
end
```

The `Enum.sort_by(..., & &1.index)` call is required. The keys of the
`members` map are member names, and each name contains a unique integer.
Iterating the map directly orders the members by atom, and the atoms differ
between runs.

Omit a process that can never take a step. The registry workload registers
names against dummy processes that block forever. Scheduling those processes
would add choices that cannot affect the run.

## generate/2

The trace records each operation, and a replay can execute the operation
against a newly started system. The operation must have the same meaning in
both systems. A value that is generated at run time does not:

```elixir
# Wrong: member names embed a unique integer, so on the next run this names a
# different process, or none at all.
{:register, :sim_2210_m3, :worker_1}

# Right: name the member by index and resolve it when the operation executes.
{:register, 3, :worker_1}
```

The same rule applies to:

- pids,
- refs,
- generated atoms,
- any order that comes from a map keyed on one of these.

If an operation must name a process, put the position of the process in the
operation and resolve the position in `execute/2`.

## execute/2

[A worked example: two-phase commit](03-two-phase-commit.md) describes
`execute/2`. In summary:

- Every process that the scheduler owns is suspended while the driver runs,
  so a synchronous call from the driver to one of them is never answered.
- `execute/2` therefore spawns a process that performs the operation.
- `execute/2` spawns through `eta_run:spawn_op/1`, so that the new process
  does not run before the scheduler owns it.

## check/1

An invariant runs while every scheduled process is suspended. A call that
sends a message to a scheduled process and waits for the reply is never
answered.

An invariant that makes such a call fails in one of 2 ways:

- The call does not return. `eta_run` bounds `check/1` by `check_timeout`
  and reports `check_blocked`.
- The call returns a default value, and the invariant passes without
  checking anything. `eta_run` cannot detect this case.

The second case occurs with a status function of the following common form:

```erlang
status(Name) ->
    try gen_server:call(Name, status, 500) of
        S -> S
    catch
        exit:_ -> undefined
    end.
```

During a run, every call to `status/1` returns `undefined`, because the
called process is suspended. Consider an invariant that uses `status/1`: "no
2 members are leader at the same epoch". The invariant computes over an
empty set and passes. The test suite passes, and the invariant checks
nothing.

An invariant must therefore read state without a call to a process. The 2
methods are:

- **Read the state where the system already keeps it.** Use this method if
  the state is already in a readable place. The members of the registry keep
  their replicas in ETS, because the replication protocol needs them there.
  The invariant that compares replicas is one `ets:tab2list` call per
  member.
- **Publish the state with `eta_observe`.** Use this method if the state
  exists only inside a process. `-eta_observe({state, [leader, epoch]})`
  makes the transform publish those fields into the process dictionary on
  every callback return. `eta_observe:read/1` reads the fields from another
  process.

`eta_observe:read/1` has the following properties:

- It works on a suspended process.
- It takes a couple of microseconds, independent of the mailbox depth.
- It never returns stale fields, because the transform publishes the fields
  on every callback return. No code in the module has to publish them.

Name the record and the fields. Do not use `-eta_observe(all)`, for 2
reasons:

- `read/1` copies the published value, and the driver calls the invariants
  after every step.
- With named fields, a misspelled field is a compile error, not a read of
  the wrong field.

## Property tiers

A property that is checked at the wrong time gives one of 2 results: a false
violation, or a test suite that passes without checking the property.
Properties belong to 3 tiers. A typical system has properties in each tier.

| Tier | When to check | Callback |
|---|---|---|
| Always true | After every action | `check/1` |
| True at rest | When the system is at rest | `check/1`, guarded by a rest condition |
| True after convergence | After the faults are healed and the system agrees | `check_final/2` |

### Always true

Assert the property after every action. In the registry, 2 members may both
be leader only under different epochs. This is a safety property of the
fencing token. It holds at every instant.

### True at rest

A property of this tier needs a definition of rest. The registry example is:
2 members that report the same version hold the same map. The property does
not hold continuously, and the reason is not a defect. A member writes
optimistically, ahead of the replicated stream. While an operation is in
progress, a member can therefore correctly hold content that differs from
the content of its peers at the same version.

The scheduler has the information that determines whether the system is at
rest:

```elixir
def quiescent?(%{clients: clients}) do
  case :eta_sched.current() do
    :undefined -> false
    sched -> :eta_sched.runnable(sched) == [] and not Enum.any?(clients, &Process.alive?/1)
  end
end
```

Both parts of the condition are necessary. "Nothing is runnable" is not
sufficient, because a system can have no runnable process in the middle of
an operation. For example, a commit that waits on a worker leaves every
other process idle while the write that the commit will confirm is still
speculative.

The rule is: a property that holds only at rest needs a definition of rest
that the system supplies. "No process is runnable" is not that definition.

### True after convergence

To check a property of this tier:

1. Heal every injected fault.
2. Drain the network.
3. Wait for agreement.
4. Assert the property.

Some properties require this procedure. The procedure can also remove the
condition that the test is meant to observe. In the registry, convergence
has the following effects:

1. Every member receives a `nodeup` message.
2. Each member announces itself again.
3. The leader sends a new snapshot to each member that announced itself.
4. The snapshot repairs the inconsistency that the test investigates.

A permanent divergence that the system does not detect is therefore visible
only between the time the system becomes idle and the time a repair occurs.
A property of the "true at rest" tier observes that interval.

### check_final/2

`check_final/2` is the callback for properties that are not true at every
instant. It is an optional callback. The driver calls it once, after the
last action of a run that ended normally. The driver does not call it for a
run that ended on a violation or on a budget error.

The first argument states how the run ended:

| Value | Meaning |
|---|---|
| `quiescent` | Nothing was runnable and no timer could make a process runnable. The system has stopped. |
| `settle_budget` | The system ran for `settle_steps` with no operations injected. The system can still have active timers. |
| `settle_done` | `settle_done/1` returned `true` before `settle_steps` ran out. The claim is the same as for `settle_budget`. |

A system with a heartbeat never reaches `quiescent`. For such a system,
`settle_budget` and `settle_done` are the strongest claims available.

## Verification

### Count the checks

An invariant that is guarded by a rest condition is never evaluated if the
run never reaches that condition. The run reports `ok` in both cases. Count
the evaluations and assert the count in a test:

```elixir
defp check_quiescent(cluster) do
  bump(:quiescent_checks)
  Invariants.check_quiescent(cluster)
end
```

The driver runs each `check/1` call in a new process, and `check/1` cannot
return a changed state. The counter therefore cannot be part of the harness
state. Use a public ETS table or a counter ref.

The same rule applies to workloads. A test that asserts that a batch is
applied atomically must also assert that a batch of more than one operation
occurred. Otherwise, after a change in batching behaviour, the test can pass
without checking atomicity.

### Assert the property, not the schedule

Two rules apply to a test that fails intermittently.

**Do not weaken a failing test before proving that the race is permitted.**
A test in the registry project failed intermittently. One possible change
was to make the assertion wait for the expected value. That change would
have been wrong. Both operations used the same durable queue, and FIFO order
guarantees that the read observes the earlier write. The failure was a
defect in the storage layer. The change would have hidden the defect.

**Fix a test that asserts the schedule instead of the property.** Another
test changed 150 registrations at once and asserted that a sampler observed
only 0 or 150 of them. The assertion depended on a batch boundary that the
test does not control. When the leader split the work into a batch of 1 and
a batch of 149, each batch was applied whole, and the test reported
thousands of torn reads. The test now derives the permitted counts at run
time from the batches that the follower received. The assertion holds under
any split, and it still rejects a torn read.

The criterion is whether the system guarantees the asserted condition, or
only produces it in most runs.

### Check that a test can fail

Two runs without a failure are not evidence that an intermittent defect is
fixed. The evidence is a test that fails deterministically before the fix
and passes after the fix.

A stronger method is to introduce a defect deliberately and confirm that the
test detects it. The acceptance criteria of `eta` use this method: a known
defect is planted behind a compile flag, and the framework must find the
defect from a cold start.

## Next

[Hazards](05-gotchas.md).
