-module(eta_harness).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
The behaviour that a system under test implements for `eta_run` (design:
`docs/design.md`).

A harness is a module that implements this behaviour. The harness is not the
system under test. The system under test is the `gen_server` modules and the
protocol code of the project. The harness does four things:

1. It starts the system.
2. It declares which processes `eta_run` schedules.
3. It drives the system with a workload of operations.
4. It checks the system against invariants.

`eta_run` supplies the seed and owns the scheduler and the clock. `eta_run`
decides when to inject an operation, when to step a process and when to advance
the clock. `eta_run` records a trace that replays the run exactly.

## Callbacks

Six callbacks are required and four are optional.

| Callback | Required | Purpose |
|---|---|---|
| `init/2` | yes | Starts the system. |
| `processes/1` | yes | Returns the pids to schedule. |
| `generate/2` | yes | Returns the next operation. |
| `execute/2` | yes | Issues an operation. |
| `check/1` | yes | Checks the invariants after an action. |
| `terminate/1` | yes | Stops the system. |
| `check_final/2` | no | Checks the invariants that hold only at the end of a run. |
| `settle_done/1` | no | Ends the settle phase before `settle_steps` is spent. |
| `labels/1` | no | Names processes for `eta_log`. |
| `shrink_op/1` | no | Returns smaller operations for `eta_shrink`. |

## Requirements

Every scheduled process is suspended between steps. Three requirements follow.
A harness that breaks one of them can fail without reporting an error.

- `init/2` must return with the system quiescent.
- `execute/2` must not block.
- `check/1`, `check_final/2` and `settle_done/1` must not call a scheduled
  process.

The sections below give the reason for each requirement.

## `init(Seed, Config)`

`init/2` starts the system and returns `{ok, State}`. `Config` is the `config`
option of `eta_run:run/2`.

The system must be quiescent when `init/2` returns. A process that is still
running when `eta_run` registers the processes runs on the real scheduler. The
work of that process is not part of the schedule, so the seed does not reproduce
it.

## `processes(State)`

`processes/1` returns every pid to schedule.

- `eta_run` calls `processes/1` after `init/2` and after each operation. The
  processes that an operation creates are therefore registered.
- `eta_sched` ignores a pid that is already registered. The callback returns the
  full set on every call.
- The order of the list must be the same on every run. `eta_sched` assigns ids in
  registration order, and the trace records ids.

## `generate(State, Rand)`

`generate/2` returns the next operation and the advanced `rand` state.

The callback must draw every random value from the supplied `rand` state. A
workload that draws from another source is not a function of the seed.

## `execute(Op, State)`

`execute/2` issues the operation and returns the new state.

`execute/2` must not block. The driver calls `execute/2` while every scheduled
process is suspended. A synchronous call from the driver to a scheduled process
is not answered, and the call waits until a time-out.

An operation is issued by spawning a process that performs it. Spawn the process
with `eta_run:spawn_op/1`. `eta_run` registers the process through `processes/1`
and schedules it like every other process. The client of the system is part of
the interleaving, so the client runs as a scheduled process.

## `check(State)`

`check/1` checks the invariants and returns `ok` or `{violation, Violation}`.
`eta_run` calls `check/1` every `check_every` actions (default 1), while every
scheduled process is suspended.

`check/1` must not call a scheduled process. Two failures are possible:

- The call blocks. `eta_run` bounds `check/1` by the `check_timeout` option
  (default 5000 ms) and ends the run with `{error, check_blocked}`.
- The call returns a wrong value. A client function that catches its own
  time-out does not reach the bound. For example, a `status/1` that returns
  `undefined` on `exit:_` returns `undefined` for every suspended member. An
  invariant "no member reports that it is the leader" then passes without
  checking anything. No error is reported.

`check/1` must read state out of band. The supported sources are an ETS table,
`persistent_term`, `eta_observe`, or a table that the system keeps for its own
use. For example, an invariant on a registry reads the names table of the
registry directly, as the lookups of the registry do. A function that sends a
message and waits for a reply is not a supported source.

## `check_final(Settled, State)`

`check_final/2` is optional. It checks the invariants that hold only after the
system is no longer driven.

- `eta_run` calls `check_final/2` once, after the last action of a run that ended
  normally.
- `eta_run` does not call `check_final/2` for a run that ended with a violation
  or an error.
- The return value has the same form as the return value of `check/1`. A
  violation ends the run in the same way: `outcome` carries the violation, and
  `terminate/1` still runs.
- The `check_timeout` bound and the requirements of `check/1` apply.

Some properties do not hold at every instant:

- "Exactly one leader per partition" is false for a short time after a partition
  heals.
- "No lock is waited on forever" cannot be decided while requests are still
  injected.

A check of such a property after every action has two possible forms. One form
reports a violation in correct code. The other form is too weak to find a defect.
A threshold does not separate a transient state from a defect, because the two
distributions overlap. `check_final/2` checks the property at the end of the run
instead.

`Settled` states how the run ended:

| `Settled` | Meaning |
|---|---|
| `quiescent` | No process was runnable and no timer could make a process runnable. The system has stopped. |
| `settle_budget` | `settle_steps` actions were spent after the last operation was injected. The system was not driven during those actions. The system can still be running. |
| `settle_done` | `settle_done/1` returned `true` before `settle_steps` was spent. The guarantee is the same as for `settle_budget`, after fewer actions. |

A system with a periodic timer, such as a heartbeat, never reaches `quiescent`.
`settle_budget` is the strongest result that such a system gives.

`quiescent` proves that the system has stopped. `settle_budget` and
`settle_done` show only that the system ran without new operations. The harness
must state which value each property requires. A check that requires
`quiescent` returns `ok` for the other two values.

## `terminate(State)`

`terminate/1` stops the system. `eta_run` calls `terminate/1` at the end of every
run, including a run that ended with a violation. `eta_run` resumes every
scheduled process before the call, so `terminate/1` can call the system.

## `settle_done(State)`

`settle_done/1` is optional. After the last operation is injected, `eta_run`
calls `settle_done/1` before every action. A return of `true` ends the run with
`Settled` equal to `settle_done`. `eta_run` does not call `settle_done/1` during
a replay.

The callback is for a system that never becomes quiescent. Without the callback,
the settle phase of such a system spends all of `settle_steps` on every run.
`settle_steps` must then cover the slowest recovery, and every run pays that
cost.

A harness can answer from a record that the last operation writes when it
finishes. An example is a reader that waits for the cluster to catch up and then
records the result in a table of the harness.

`settle_done/1` has two constraints:

- It must read only the tables of the harness. It must not call the system.
- It must be cheap, because `eta_run` calls it once per action.

## `labels(State)`

`labels/1` is optional. It returns a `#{pid() => Name}` map. `eta_log:analyze/0`
uses the names when it renders a run. A step of an unnamed process reads `p7`. A
step of a named process reads `participant-2`.

`?ETA_LABEL(Name)` in the process itself is the preferred way to name a process.
A process that labels itself is named in one place, so the step lines and the
events of the process show the same name. A name that a process gave itself
takes precedence over the name from `labels/1`.

`labels/1` is for a process that cannot label itself:

- a process from a library that the project does not own;
- a process of a module that does not include `eta.hrl`.

For example, the clients of the `eta_2pc` test harness are anonymous funs passed
to `eta_run:spawn_op/1`. Only the harness knows what each client is.

`eta_run` calls `labels/1` once, after the run, with the whole state. A harness
already holds its processes in lists and maps, so one comprehension builds the
map. A callback that took one pid at a time would require reverse lookups that
the harness does not otherwise need.

The map can name a subset of the processes. A process that is absent from the
map is shown by its id. A crash in `labels/1`, or a return value that is not a
map, gives no names.

A name is any term. `eta_log` renders a name as follows:

| Name | Rendered as |
|---|---|
| an atom | the text of the atom |
| a binary or a printable string | the text |
| `{Kind, N}` with an atom and an integer | `kind-n` |
| any other term | the `~p` format of the term |

## `shrink_op(Op)`

`shrink_op/1` is optional. It returns the operations that `eta_shrink:shrink/3`
tries in place of `Op`, in the order to try them. Without the callback,
`eta_shrink` removes operations and does not change an operation.

- Return operations that are smaller than `Op` by a measure that has a least
  value. Examples are a smaller integer, a shorter list and an earlier key.
  `eta_shrink` calls `shrink_op/1` again on an operation that it keeps. A
  callback that returns `Op`, or an operation that leads back to `Op`, makes
  `eta_shrink` spend its `max_tests` budget without a result.
- Return `[]` for an operation that has no smaller operation.
- Return the most reduced operation first. `eta_shrink` keeps the first
  operation that gives the same violation, and each operation that it tries
  costs one replay. A common order is the least value, then the half, then the
  value minus 1.
- The callback receives the operation only, not the state of the harness. A
  replay calls `execute/2` with the operation, so `execute/2` must accept every
  operation that `shrink_op/1` returns.

```erlang
shrink_op({put, Key, Size}) ->
    [{put, 1, Size} || Key > 1] ++
        [{put, Key, S} || S <- [1, Size div 2, Size - 1], S >= 1, S < Size].
```

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export_type([state/0, op/0, violation/0, settled/0]).

-type state() :: term().
-type op() :: term().
-type violation() :: term().

%% How a run reached its end, and how much a `check_final/2` may read into it.
%% `quiescent' is proof the system stopped; `settle_budget' is only that it was
%% left alone for `settle_steps'. See the module doc.
-type settled() :: quiescent | settle_budget | settle_done.

-callback init(Seed :: integer(), Config :: map()) -> {ok, state()}.
-callback processes(state()) -> [pid()].
-callback generate(state(), rand:state()) -> {op(), rand:state()}.
-callback execute(op(), state()) -> state().
-callback check(state()) -> ok | {violation, violation()}.
-callback terminate(state()) -> ok.
-callback labels(state()) -> #{pid() => term()}.
-callback check_final(settled(), state()) -> ok | {violation, violation()}.
-callback settle_done(state()) -> boolean().
-callback shrink_op(op()) -> [op()].

-optional_callbacks([labels/1, check_final/2, settle_done/1, shrink_op/1]).
