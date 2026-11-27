# A worked example: two-phase commit

`eta` contains a two-phase commit implementation as an example system under
test. The source is in `test/support/eta_2pc*.erl`. The protocol is about 190
lines and the harness is about 230 lines. The coordinator contains a planted
defect that only some interleavings expose.

This page describes that example. [A Journey Through DST](06-a-journey-through-dst.md)
builds a system under test from an empty directory instead.

## AI disclosure

This document is pending a human rewrite. We still expect the content to be mostly
correct.

## Protocol

A coordinator makes a group of participants agree on a transaction:

1. The coordinator sends a prepare request to each participant.
2. Each participant votes `yes` or `no`.
3. The coordinator decides `commit` if every vote is `yes`. Otherwise it
   decides `abort`.
4. The coordinator sends the decision to every participant.

The required property is atomicity: no 2 participants reach opposite
conclusions about the same transaction.

The example has 3 participants and 1 coordinator. One client process per
transaction waits for the decision.

## Participants

A participant is a `gen_server` with no timers:

```erlang
handle_cast({prepare, TxId, Coordinator}, St = #{tab := Tab, index := Index}) ->
    case plan(Tab, TxId, Index) of
        stall ->
            {noreply, St};
        Vote ->
            record(Tab, TxId, Index, {prepared, Vote}),
            gen_server:cast(Coordinator, {vote, TxId, Index, Vote}),
            {noreply, St}
    end;
```

The plan of a participant is the vote that the participant gives for a
transaction. The participant does not choose the plan. The driver writes the
plan into a shared ETS table before the transaction starts, and the
participant reads the plan from the table. The workload is therefore part of
the seeded state, and it replays with the seed.

A plan of `stall` means that the participant never votes. When a participant
stalls, only the prepare time-out of the coordinator can resolve the
transaction. The `stall` plan therefore makes the outcome of a run depend on
the virtual clock.

A participant also writes each of its states into the table, not into its
`gen_server` state. The atomicity invariant must read the states while every
participant is suspended. `eta_observe` can also make state readable. The
rule for the choice between an ETS table and `eta_observe` is:

- If the system already keeps the state in a readable place, read the state
  there.
- If the state exists only inside a process, publish it with `eta_observe`.

The example uses the table for 2 reasons:

- The driver must write the plans into the table in any case.
- The states of a participant form a history that grows. `eta_observe`
  publishes a snapshot of the current fields, which does not fit a history.

## Coordinator

The coordinator has one timer call that the transform must rewrite:

```erlang
-include_lib("eta/include/eta.hrl").

-define(VOTE_TIMEOUT, 30000).

handle_call({run_tx, TxId}, From, St) ->
    #{participants := Participants, pending := Pending} = St,
    Self = self(),
    [gen_server:cast(P, {prepare, TxId, Self}) || {_Index, P} <- Participants],
    Timer = erlang:send_after(?VOTE_TIMEOUT, self(), {vote_timeout, TxId}),
    ...
```

In a simulation build the header applies the parse transform, and
`erlang:send_after/3` becomes `eta_time:send_after/3`. In a release build the
header adds nothing, and the call compiles as written.

This module is part of the test suite of `eta`, so it includes `eta.hrl`
directly. A module in another project includes a wrapper header instead, so
that a build without `DST` does not need `eta` on the code path.
[Setting up a project](02-setting-up.md) describes the wrapper header.

The time-out is 30 seconds of virtual time. It consumes no real time. When
every participant has stalled and no process is runnable, the driver advances
the clock to the deadline of the timer, and the run continues.

## Planted defect

The coordinator has a second mode, which the harness config selects. In this
mode the coordinator decides on the first vote that arrives and does not wait
for the other votes:

```erlang
on_vote(TxId, _Index, Vote, _Tx, St = #{mode := first_vote_wins}) ->
    Decision =
        case Vote of
            yes -> commit;
            no  -> abort
        end,
    {noreply, decide(TxId, Decision, St)};
```

The mode gives a correct result in 2 cases:

- A `no` vote arrives first. The transaction aborts, and every participant
  aborts.
- Every vote is `yes`. The transaction commits, and every participant
  commits.

The mode gives a wrong result when a `yes` vote arrives first and a `no` vote
arrives later. The wrong result becomes an atomicity violation because a
participant that voted `no` does not commit, whatever decision it receives:

```erlang
Final =
    case {Decision, plan(Tab, TxId, Index)} of
        {commit, no} -> aborted;
        {commit, _}  -> committed;
        {abort, _}   -> aborted
    end,
```

Without this rule, the coordinator would make a wrong decision and every
participant would follow it. The atomicity invariant would not detect that
defect. The example does not model that class of defect.

A run reaches the defect under 2 conditions:

- The transaction has at least one `no` vote. The generator draws `no` with
  probability 0.20 per participant.
- The scheduler steps a participant that votes `yes` before the participant
  that votes `no`.

## Harness

`eta_harness` has 6 required callbacks, `init/2` through `terminate/1`, and
3 optional callbacks:

| Optional callback | Use in this example |
|---|---|
| `labels/1` | Used. The `labels/1` section below describes it. |
| `check_final/2` | Not used. It holds the invariants that are true only after the driver has stopped injecting operations. [Writing a system under test](04-writing-a-system-under-test.md) describes it. |
| `settle_done/1` | Not used. It ends the settle phase early. The `eta_harness` module documentation describes it. |

### init/2

```erlang
init(Seed, Config) ->
    Tab = ets:new(eta_2pc, [public, set]),
    N = maps:get(participants, Config, 3),
    Mode = maps:get(mode, Config, correct),

    Participants = [...],
    {ok, Coordinator} = eta_2pc_coordinator:start_link(Tab, Participants, Mode),

    {ok, #{tab => Tab, coordinator => Coordinator, participants => Participants,
           clients => [], next_tx => 1, plan => maps:get(plan, Config, random)}}.
```

The table is `public` because 3 kinds of process use it:

- The driver writes the plans.
- The participants write their states.
- The invariant reads every entry.

`init/2` must return when the system is quiescent. A system that is started,
or ready to accept work, is not sufficient: the system must be idle. Any work
that is still in progress when the driver takes control ran on the real
scheduler, outside the schedule. Two-phase commit meets the requirement
without extra code, because `start_link` returns after `init/1` has run. A
cluster needs extra code, which
[Writing a system under test](04-writing-a-system-under-test.md) describes.

### processes/1

```erlang
processes(#{coordinator := C, participants := Ps, clients := Clients}) ->
    [C | [P || {_Index, P} <- Ps]] ++ Clients.
```

The driver calls `processes/1` after every operation, so the scheduler adopts
the processes that an operation creates. The scheduler ignores pids that it
already has. Return the complete list on every call.

The order of the list is part of the contract. `eta_sched` assigns ids in
registration order, and the trace records ids. If the order of the list
differs between runs, the same seed selects different processes. The
resulting difference between traces has the same appearance as a scheduling
defect.

### generate/2

```erlang
generate(#{participants := Participants, next_tx := TxId}, Rand0) ->
    {Plan, Rand} = lists:foldl(
        fun({Index, _Pid}, {Acc, R0}) ->
            {Roll, R1} = rand:uniform_s(R0),
            {[{Index, vote_for(Roll)} | Acc], R1}
        end,
        {[], Rand0},
        Participants
    ),
    {{run_tx, TxId, lists:reverse(Plan)}, Rand}.

vote_for(Roll) when Roll < 0.70 -> yes;
vote_for(Roll) when Roll < 0.90 -> no;
vote_for(_Roll) -> stall.
```

Draw every random value from the `rand` state that `generate/2` receives, and
return the advanced state. A value from any other source breaks replay, and
no error reports it. Examples of other sources are `rand:uniform/1`,
`erlang:unique_integer/0` and the clock.

The generator draws `yes` with probability 0.70, `no` with probability 0.20
and `stall` with probability 0.10. Most transactions therefore commit, and
the defect appears only in a minority of interleavings.

The `plan` config option replaces the random votes with a fixed list. A test
uses the option to make the schedule the only variable. With the same votes
and a different seed, a change of outcome is caused by the interleaving.

### execute/2

```erlang
execute({run_tx, TxId, Plan}, Sut = #{tab := Tab, coordinator := Coordinator}) ->
    [ets:insert(Tab, {{plan, TxId, Index}, Vote}) || {Index, Vote} <- Plan],

    Client = eta_run:spawn_op(fun() ->
        Result = gen_server:call(Coordinator, {run_tx, TxId}, infinity),
        ets:insert(Tab, {{client, TxId}, Result})
    end),

    Sut#{clients := [Client | maps:get(clients, Sut)], next_tx := TxId + 1}.
```

`execute/2` must not block. Every process that the scheduler owns is
suspended while the driver runs, so a synchronous call from the driver to
one of them is never answered. `execute/2` therefore spawns a process that
performs the operation. The client process is part of the concurrent system.
The next `processes/1` call returns it, and the scheduler interleaves it with
the other processes.

`execute/2` spawns through `eta_run:spawn_op/1`, not `spawn/1`, for the
following reason:

1. The driver is not traced. A process that the driver creates with
   `spawn/1` is not adopted until the driver registers it.
2. Until registration, the new process runs on the real scheduler.
3. Two clients that are created by operations injected close together both
   send to the coordinator. The wall clock decides the order in which the 2
   messages arrive.

`spawn_op/1` starts the process blocked until registration is complete.

The call uses a time-out of `infinity`. A client in a run must not wait on
the real clock.

### check/1

```erlang
check(#{tab := Tab, next_tx := Next}) ->
    first_violation(lists:seq(1, Next - 1), Tab, eta_2pc_participant:decisions(Tab)).

first_violation([TxId | Rest], Tab, Decisions) ->
    case lists:usort(maps:get(TxId, Decisions, [])) of
        Mixed when length(Mixed) > 1 ->
            {violation, #{property => atomicity,
                          detail => <<"participants disagreed about a transaction">>,
                          tx => TxId,
                          decision => coordinator_decision(Tab, TxId),
                          participants => [...]}};
        _ ->
            first_violation(Rest, Tab, Decisions)
    end.
```

`check/1` sends no message and waits for nothing.
`eta_2pc_participant:decisions/1` is one `ets:tab2list` call that groups the
decisions of the participants by transaction. The rest of `check/1` is list
operations. The invariant runs after every action, so it reads the table
once per check, not once per transaction.

An invariant that calls a suspended process has one of 2 results:

- The call does not return. `eta_run` reports `check_blocked` after
  `check_timeout`.
- The called API catches its own time-out and returns a plausible value. The
  invariant then passes without checking anything.

Give the violation a `property` key. `eta_shrink` uses the key to
distinguish the original failure from a different failure. Without the key,
when a harness has more than one invariant, the shrinker can reduce a trace
for one defect into a trace for another defect and report the result as a
successful reduction.

### labels/1

`labels/1` is optional.

```erlang
labels(#{coordinator := C, participants := Ps, clients := Clients}) ->
    maps:from_list(
        [{C, coordinator}] ++
            [{Pid, {participant, Index}} || {Index, Pid} <- Ps] ++
            [{Pid, {client, N}} || {N, Pid} <- lists:enumerate(lists:reverse(Clients))]
    ).
```

Without a label, `eta_log` prints a step of a process as `p3`. With a label,
it prints `participant-2`. A label is an ordinary term. `eta_log` renders
`{participant, 2}` as `participant-2`.

The coordinator and the participants call `?ETA_LABEL` in `init/1`, and a
label that a process sets for itself takes precedence over `labels/1`. The
example needs `labels/1` for the clients. A client is an anonymous fun that
is passed to `eta_run:spawn_op/1`, so no module exists in which the client
could call `?ETA_LABEL`. Only the harness has the information that a client
belongs to transaction 3.

Use `labels/1` for a process that cannot label itself:

- an anonymous fun,
- a process of a library that the project does not own,
- a process of a module that deliberately does not include the header.

The driver calls `labels/1` once, after the run, with the complete state.
The scheduler assigns ids as processes register, so the mapping from pid to
id is complete only after the run.

### terminate/1

```erlang
terminate(Sut = #{coordinator := C, participants := Ps, tab := Tab}) ->
    [exit(Client, kill) || Client <- maps:get(clients, Sut)],
    [stop(P) || {_Index, P} <- Ps],
    stop(C),
    catch ets:delete(Tab),
    ok.
```

`terminate/1` kills the clients first, and it uses `exit/2` with `kill`, not
a request to stop. When `terminate/1` runs, the driver has already released
the scheduler, so every suspended process runs again. A client that reaches
its `ets:insert` call after the table is deleted would crash with a `badarg`
error that is unrelated to the run.

## Example

The following call runs the correct mode over 40 seeds:

```erlang
eta_run:sweep(eta_2pc, lists:seq(1, 40), #{max_ops => 25, max_steps => 20000}).
```

The call returns `#{outcome => ok, runs => 40}`.

The following call turns the defect on:

```erlang
eta_run:run(eta_2pc, #{seed => 1, max_ops => 25, max_steps => 20000,
                       config => #{mode => first_vote_wins}}).
```

Seed 1 fails after 19 steps:

```erlang
#{outcome := {violation, #{property := atomicity,
                           tx := 5,
                           decision := commit,
                           detail := <<"participants disagreed about a transaction">>,
                           participants := [{1, aborted}, {2, {prepared, yes}}, {3, committed}]}},
  steps := 19,
  ops := 7}
```

The result shows the following:

- Participant 1 voted `no` and did not commit.
- Participant 3 committed.
- The coordinator decided `commit` on the `yes` vote of participant 2.
  Participant 2 is still at `{prepared, yes}` because the decision has not
  reached it.
- The run stopped after 7 of its 25 operations, because `eta_run` ends a run
  on the first violation.

## Shrinking

The trace is the list of every action of the driver, in order. An entry is
`{step, Id}`, `{op, Op}` or `{clock, Ms}`. The trace of this failure has 26
entries, because the failure occurred early in the run. The first trace of a
failure in a larger system has thousands of entries.

```erlang
#{outcome := {violation, _}, trace := Trace} =
    eta_run:run(eta_2pc, Opts),

#{trace := Minimal, original := 26, shrunk := 7, verified := true} =
    eta_shrink:shrink(eta_2pc, Trace, Opts).
```

The shrinker reduces the 26 entries to 7 entries in 74 candidate replays:

```erlang
[{op,   {run_tx, 5, [{1, no}, {2, yes}, {3, stall}]}, [8]},
 {step, 8},
 {step, 0},
 {step, 2},
 {step, 0},
 {step, 3},
 {step, 1}]
```

The shrinker removed 6 of the 7 operations, including the 4 operations that
ran before this one. The `[8]` on the operation is the id of the client
process that the operation spawned. The trace records the id so that the
deletion of another operation cannot renumber the process.
[Shrinking hazards](05-gotchas.md#shrinking-hazards) has more detail.

A trace does not explain a failure. `{step, 3}` records which process the
scheduler chose. It does not record what the process did. Reading a trace
requires reconstructing the state of every mailbox by hand. Shrinking makes
the trace short. `eta_log` describes what happened in it.

### Event log

`eta_run` writes its actions into the same log that the system under test
writes to. To get one timeline, replay the shrunk trace and print the log:

```erlang
eta_run:replay(eta_2pc, Minimal, Opts),
eta_log:analyze().
```

```
    1  $eta           {op,{run_tx,5,[{1,no},{2,yes},{3,stall}]}}
    2  client-1       {step,8}
    3  coordinator    {step,0}
    4  coordinator    {prepare_sent,5}
    5  participant-2  {step,2}
    6  participant-2  {voted,5,yes}
    7  coordinator    {step,0}
    8  coordinator    {decided,5,commit}
    9  participant-3  {step,3}
   10  participant-3  {stalling,5}
   11  participant-3  {decided,5,commit,committed}
   12  participant-1  {step,1}
   13  participant-1  {voted,5,no}
   14  participant-1  {decided,5,commit,aborted}
```

| Line | Event |
|---|---|
| 6 | Participant 2 votes `yes`. |
| 8 | The defect: the coordinator decides `commit` after one vote. |
| 13 | Participant 1 votes `no` after the decision. |
| 14 | Participant 1 does not commit. This makes the disagreement visible. |

The events come from `?ETA_LOG` calls in the participant and the
coordinator, about one call per protocol decision.
`eta_log:analyze(#{until => N})` stops the output at sequence number `N`.
Use it to omit the events after the end of the run. Those events come from
teardown, when the scheduler releases the processes.

### Shrinker behaviour

Two properties of the shrinker affect how to read a result.

**A candidate replay has 3 possible results.**

| Result | Meaning |
|---|---|
| The same violation | The removal was safe. |
| A clean run | The removed entries were necessary. |
| A divergence | The candidate is not a valid schedule. The result is evidence of nothing. |

A shrinker that treated a divergence as a clean run would revert removals
that were safe, and its results would be larger than necessary.

**The shrinker records the result again before it verifies the result.** The
shrinker replays a candidate in lenient mode, which skips a step whose
process is not runnable. A candidate that survives is therefore not an exact record of a run.
`shrink/3` ends by replaying, in strict mode, the trace that the surviving
run executed. If the strict replay does not reproduce the violation,
`shrink/3` returns `verified => false` and the original trace.

## Limitations

- The example injects no faults: no message loss, no crashes and no
  partitions. It exercises scheduling only. Fault injection has its own
  reproducibility hazard, which [Hazards](05-gotchas.md)
  describes.
- The shrinker deletes whole entries of this example. It does not simplify an
  entry, because `eta_2pc` does not export the optional callback `shrink_op/1`
  of `eta_harness`. The shrunk transaction still has 3 participants, because
  the generator produced that operation. With `shrink_op/1`, the shrinker also
  tries smaller operations. See "Shrinking the content of an operation" in
  `eta_shrink`.
- The shrinker cannot remove the entries that the system needs to reach the
  violation. The surviving operation is such an entry.

## Next

[Writing a system under test](04-writing-a-system-under-test.md) describes
the callbacks and practices that a larger system needs.
