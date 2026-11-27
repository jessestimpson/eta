# Setting up a project

This page describes how to add `eta` to a project. It covers:

- the build configuration,
- the removal of nondeterminism from the system under test,
- the options of a run,
- the checks that confirm that the configuration is correct.

[A Journey Through DST](06-a-journey-through-dst.md) covers the same material
as a walkthrough that builds a project from an empty directory.

## AI disclosure

This document is pending a human rewrite. We still expect the content to be mostly
correct.

## Components

```
  eta_run          the driver: turns a seed into a run
    |
    +-- eta_sched  runs one process at a time, choosing from the seeded RNG
    +-- eta_time   virtual clock; timers fire when the driver says so
    +-- eta_log    a record of what your system did, on the same timeline
    +-- your harness   six callbacks (eta_harness)
```

`eta_transform` is a parse transform. It is applied to the modules that make
up the system under test. It rewrites the timer, clock and spawn calls of a
module to call `eta_time` and `eta_sched` instead of `erlang`. It changes
nothing else in the module. A module does not name `eta_transform`. A module
opts in by including one header.

`eta_run` is the driver. It owns the seed. Every choice in a run is drawn from
one `rand` state that is seeded from the seed:

- which process to step,
- whether to inject a client operation or to step the system,
- the values that the workload generator draws.

At each iteration the driver takes exactly 1 of 3 actions:

- It steps a runnable process until the process blocks.
- It injects the next generated operation.
- It advances the clock to the next timer deadline.

After the action, the driver checks the invariants of the harness while every
scheduled process is suspended.

## Build configuration

The build configuration has 2 parts:

- the opt-in, which marks a module as part of the system under test,
- the build profile, which turns the opt-in on.

### Wrapper header (Erlang)

Every module that takes part in a run includes one header. Do not include
`eta.hrl` directly. Write a wrapper header in the project,
`include/myapp_eta.hrl`:

```erlang
-ifndef(MYAPP_ETA_HRL).
-define(MYAPP_ETA_HRL, true).

-ifdef(DST).
-include_lib("eta/include/eta.hrl").
-else.
-define(ETA_LABEL(Label), ok).
-define(ETA_LOG(Event), 0).
-endif.

-endif.
```

The modules of the project include the wrapper header:

```erlang
-include("myapp_eta.hrl").
```

The include is the complete opt-in. In a build that defines `DST`, the header
applies the parse transform and defines the `?ETA_LOG` and `?ETA_LABEL`
macros. In any other build the header adds no transform and no call into
`eta`, and the compiled module is unchanged.

The wrapper header exists for the following reason. `eta.hrl` is guarded by
the `DST` define and expands to nothing without it. The `-include_lib` line
must still resolve, so `eta` would have to be on the code path of every
compilation, including the release build. The wrapper header makes the
`-include_lib` line conditional. `eta` can then be a dependency of only the
profile that runs simulations, and the deployed application does not contain
`eta`.

The `-else.` branch is required. Modules that ship call `?ETA_LABEL` and
`?ETA_LOG`, so the macros must expand to a value when `eta.hrl` is not
included. Use the definitions that `eta.hrl` uses without `DST`: `ok` and `0`.
These definitions have 2 consequences:

- Neither macro evaluates its argument. An expression that is logged must
  have no side effects.
- The compiler reports a variable as unused when the variable is used only in
  an argument of one of these macros. Bind such a variable with a leading
  underscore.

### Wrapper module (Elixir)

Elixir has no include mechanism. The wrapper is a module, and macros take the
place of the `-ifdef`:

```elixir
defmodule MyApp.Eta do
  @dst Mix.env() == :dst

  defmacro __using__(opts) do
    if @dst do
      quote do
        use Eta, unquote(opts)
      end
    end
  end

  defmacro label(value) do
    if @dst, do: quote(do: Eta.label(unquote(value))), else: :ok
  end

  defmacro log(event) do
    if @dst, do: quote(do: Eta.log(unquote(event))), else: 0
  end
end
```

The modules of the project contain `use MyApp.Eta` and call
`MyApp.Eta.label/1` and `MyApp.Eta.log/1`. In every environment except `:dst`
the compiled modules contain no reference to `eta`. This is the same result
that the wrapper header gives in Erlang.

Options on the `use` control the optional passes of the transform. The
wrapper module forwards the options to `use Eta`.

| Elixir option | Erlang attribute |
|---|---|
| `use MyApp.Eta, net: false` | `-eta_net(false).` |
| `use MyApp.Eta, observe: :all` | `-eta_observe(all).` |

A misspelled option is a compile error at the `use` line.

The transform runs after compilation in Elixir, not during compilation,
because Elixir deprecated the `parse_transform` hook of the compiler.
`mix compile.eta` does the following for each module that opts in:

1. It reads the abstract format of the module from the beam file. Dialyzer
   uses the same protocol.
2. It runs `eta_transform` on the abstract format. `eta_transform` is not
   modified for Elixir.
3. It writes the transformed beam file.

Add the compiler to the `:dst` environment only:

```elixir
  compilers: Mix.compilers() ++ if(Mix.env() == :dst, do: [:eta], else: [])
```

This line and the `only: :dst` dependency are the complete configuration.

The transform matches Elixir code through the same tables that match Erlang
code:

- Elixir inlines `send/2`, `spawn/1` and similar functions to the `:erlang`
  calls that the tables match.
- Elixir inlines `Process.send_after/3` up to Elixir 1.19. From Elixir 1.20
  `Process.send_after/3` has its own table entry.
- `receive do ... after` is put on the virtual clock in the same way as in
  Erlang.
- The `'Elixir.*'` table entries cover the calls that Elixir does not inline:
  `GenServer`, the clock reads, and `DateTime.utc_now/0` and related
  functions.
- `Task` and `Agent` raise an error that names the function when they are
  called during a run. The Elixir section of the `eta_transform` module
  documentation describes the boundary.

The rewrite requires `debug_info` in the compiled beam files. `debug_info` is
the Mix default. When a beam file has no `debug_info`, `mix compile.eta`
fails and names the module. The failure prevents a module that uses the real
clock from taking part in a run.

### Build profile

Run simulations from a dedicated build profile.

In Mix, define a `dst` environment and a `mix dst` alias that enters it. In
`project/0`:

```elixir
      erlc_paths: erlc_paths(Mix.env()),
      erlc_options: erlc_options(Mix.env()),
      test_paths: test_paths(Mix.env()),
      aliases: aliases(),
```

and:

```elixir
  def cli do
    [preferred_envs: [dst: :dst]]
  end

  defp deps do
    [{:eta, "~> 0.1", only: :dst, runtime: false}]
  end

  # The harness and the simulation suite live in dst/, so the ordinary
  # environments never compile a module that calls into a dependency they
  # don't have.
  defp erlc_paths(:dst), do: ["src", "dst"]
  defp erlc_paths(_), do: ["src"]

  defp erlc_options(:dst), do: [:debug_info, {:d, :DST}]
  defp erlc_options(_), do: [:debug_info]

  # `mix dst` runs dst/, `mix test` runs test/. Neither sees the other.
  defp test_paths(:dst), do: ["dst"]
  defp test_paths(_), do: ["test"]

  defp aliases do
    [dst: &dst/1]
  end

  # `mix test` refuses to run in an environment that isn't :test unless
  # MIX_ENV says so explicitly. `preferred_envs` above has already put us in
  # :dst; this states it in the environment too.
  defp dst(args) do
    System.put_env("MIX_ENV", "dst")
    Mix.Task.run("test", args)
  end
```

The `dst/` directory needs a `test_helper.exs` file. Use the same file that
`mix new` created in `test/`.

In rebar3, define a `dst` profile. Enter it with `rebar3 as dst eunit`.

```erlang
{profiles,
 [{dst, [{deps, [{eta, {git, "https://github.com/jessestimpson/eta.git",
                        {branch, "main"}}}]},
         {erl_opts, [{d, 'DST'}]},
         {extra_src_dirs, ["dst"]},
         %% So that `rebar3 as dst eunit` needs no `--module`.
         {eunit_tests, [{module, myapp_dst_tests}]},
         %% `eta` is named again because the suite calls straight into
         %% `eta_run`, and `plt_extra_apps` is what decides whether those
         %% calls resolve or come back as unknown functions.
         {dialyzer, [{plt_extra_apps, [eunit, eta]}]}
        ]}
 ]}.
```

rebar3 has no equivalent of a bare `rebar3 dst` command:

- rebar3 rejects `as` inside an alias, including through `do`, with the error
  "Namespace 'as' is forbidden".
- Setting `REBAR_PROFILE=dst` from `rebar.config.script` has no effect,
  because rebar3 resolves profiles before it consults the script.
- `REBAR_PROFILE=dst rebar3 eunit` works from the command line.
- A `Makefile` target that runs `rebar3 as dst eunit` gives a short command.

### Rationale

**The `DST` define.** Without the define, the header adds nothing to the
module. The module has no transform, so the timers of the module stay on the
real clock, and the module logs nothing. The build reports no error in this
case. Add the define first. Set the define in exactly one profile, so that
one place determines whether it is set.

**A dedicated profile instead of the test environment.** The `:test`
environment could hold the simulations. `eta_time` calls the real `erlang`
functions when no virtual clock is running, so a transformed module behaves
normally outside a run. An ordinary test suite that is compiled with the
transform would exercise that behaviour on every test run. A dedicated
profile is recommended for 3 reasons:

- Only one run can be active per VM, because `eta_time` and `eta_log` keep
  state in named ETS tables. Simulation tests must be `async: false`. A
  separate entry point keeps that constraint out of the ordinary test suite.
- The ordinary tests exercise the modules that ship. A transformed module is
  not the same module as the shipped module.
- `eta` is a dependency of the simulation build only. The wrapper header
  exists to make that possible.

**The opt-in is per module, not per application.** Some modules of an
application should not be transformed. See
[Transform boundary](#transform-boundary).

## Nondeterminism outside the scheduler

Before the first run, list everything that the system under test uses and
that the scheduler does not control:

- ports,
- NIFs,
- sockets,
- timers inside dependencies,
- any call to a service over a network.

For
[`dgen_registry`](https://github.com/foundationdb-beam/dgen/blob/main/src/dgen_registry.erl)
the item was the database. A database transaction expires on the real clock.
A process that the scheduler suspends during a transaction therefore fails
with `tooslow`. The remedy was a substitute that meets the determinism
requirements: a pure-Erlang in-memory implementation of the same backend
behaviour.

Each item on the list needs a deterministic substitute, and the project must
supply it. This work is the largest cost of adopting DST. Estimate the work
before committing to DST.

## Transform boundary

Do not transform every module. The choice of which modules to transform is a
design decision.

- Transform the modules that implement the system under test. The timers,
  spawns and clock reads of these modules must be under the control of the
  schedule.
- Do not transform the modules of a client-facing interface. The harness
  drives these modules, and they can contain time-outs that must stay on the
  real clock.

## Qualified calls

Write time calls with the module name, for example
`erlang:monotonic_time()`. Do not rely on an `-import`. The transform rewrites
only qualified calls, with one group of exceptions: `spawn/1,3`,
`spawn_link/1,3` and `monitor/2` are auto-imported BIFs, and the transform
rewrites a bare call to one of them when the module does not define a
function with the same name and arity.

The following table lists the time, random and spawn rewrites. The
`eta_transform` module documentation lists every rewrite.

| Original call | Replacement |
|---|---|
| `erlang:send_after/3,4` | `eta_time:send_after/3,4` |
| `erlang:start_timer/3,4` | `eta_time:start_timer/3,4` |
| `erlang:cancel_timer/1,2` | `eta_time:cancel_timer/1,2` |
| `erlang:read_timer/1` | `eta_time:read_timer/1` |
| `erlang:monotonic_time/0,1` | `eta_time:monotonic_time/0,1` |
| `erlang:system_time/0,1` | `eta_time:system_time/0,1` |
| `erlang:timestamp/0` | `eta_time:timestamp/0` |
| `os:system_time/0,1`, `os:timestamp/0` | `eta_time:*` |
| `timer:sleep/1` | `eta_time:sleep/1` |
| `calendar:universal_time/0` | `eta_time:universal_time/0` |
| `rand:uniform/0,1`, `uniform_real/0`, `normal/0,2`, `bytes/1`, `seed/1,2` | `eta_rand:*` |
| `crypto:strong_rand_bytes/1` | `eta_rand:strong_rand_bytes/1` |
| `erlang:spawn/1,3`, `spawn_link`, `proc_lib` equivalents | `eta_sched:*` |
| `gen_server:start/3,4`, `start_link/3,4`, `start_monitor/3,4` | `eta_sched:*` |
| the same six on `gen_statem` | `eta_sched:statem_*` |
| `gen_fsm:start/3,4`, `start_link/3,4` | `eta_sched:fsm_*` |
| `gen_fsm:send_event_after/2`, `start_timer/2`, `cancel_timer/1` | `eta_fsm:*` |

The spawn rewrites are required for determinism. A child that is created by
a plain `erlang:spawn` runs on the real scheduler until `eta_sched` suspends
it. `eta_sched:spawn/1` starts the child blocked on a token, so the child
does not run before the scheduler owns it.

An Elixir module needs no change. The Elixir compiler resolves every call and
inlines the `Process`, `Kernel` and `System` wrappers to the `:erlang` forms.

## State observation

An invariant runs while every scheduled process is suspended. An invariant
therefore cannot call a process.
[Writing a system under test](04-writing-a-system-under-test.md) gives the
full explanation. To make state readable, add a second attribute to each
module whose state the invariants need:

```erlang
-include("myapp_eta.hrl").
-eta_observe({state, [leader, epoch, applied_version]}).
```

The transform publishes the named fields into the process dictionary on
every `gen_server` or `gen_statem` callback return. `eta_observe:read/1`
reads the published fields from another process:

```erlang
#{leader := L, epoch := E} = eta_observe:read(my_server).
```

`eta_observe:read/1` has the following properties:

- It works while the process is suspended.
- It takes a couple of microseconds, independent of the mailbox depth.
- It never returns stale fields, because the transform publishes the fields
  on every callback return. No code in the module has to publish them.

The attribute has 2 forms:

| Form | Published value |
|---|---|
| `{RecordName, Fields}` | The named fields, as a map. A field that the record does not define is a compile error. |
| `all` | The state that the callback returned, in any shape. |

Prefer the `{RecordName, Fields}` form. `read/1` copies the published value,
and the driver calls the invariants after every step.

`-eta_observe` is an ordinary module attribute. The compiler ignores it, so
it has no effect without the transform.

## Example

A run is one call. It needs a harness, which
[A worked example: two-phase commit](03-two-phase-commit.md) describes.

```erlang
#{outcome := Outcome, trace := Trace, steps := Steps} =
    eta_run:run(my_harness, #{seed => 7, max_ops => 25, max_steps => 20000}).
```

## Options

The table lists the most commonly used options of `eta_run:run/2`. The
`eta_run` module documentation lists every option.

| Option | Default | Meaning |
|---|---|---|
| `seed` | 0 | Determines every choice of the run |
| `config` | `#{}` | Passed to `init/2` of the harness |
| `max_ops` | 50 | Number of client operations to inject before the settle phase |
| `max_steps` | 10000 | Upper bound on the sum of steps and clock advances |
| `settle_steps` | 2000 | Number of further actions after the last operation is injected |
| `op_p` | 0.3 | Probability of injecting an operation instead of stepping, when both are possible |
| `quiet_p` | 0.3 | Probability of advancing the clock instead of injecting an operation, when nothing is runnable |
| `check_every` | 1 | Run the invariants every N actions |
| `check_timeout` | 5000 | Milliseconds of real time an invariant may take before the run reports `check_blocked` |
| `preload` | `[]` | Applications to load before the run starts. Name the application under test. |
| `preempt` | 0.0 | Probability that a preemption point yields. See [Hazards](05-gotchas.md), "The code of one callback is atomic in a run". |
| `log` | `true` | Collect an `eta_log` record of the run |

Three options need an explanation.

**`preload`.** Set `preload` on the first run, and name the application under
test. Loading a module on demand is a synchronous call to `code_server`. The
scheduler does not control `code_server`. A scheduled process that calls a
module that is not yet loaded therefore blocks on a process outside the
schedule. [Hazards](05-gotchas.md) describes the failure.

**`settle_steps`.** A system with a periodic timer, such as a heartbeat,
never reaches a state with nothing runnable and no pending timer. Without a
bounded settle phase, every run of such a system would end when `max_steps`
is exhausted, and the result would be an error. With `settle_steps`, the run
ends normally after the settle phase. The settle phase is also the only part
of a run in which the invariants are checked with no client operations in
progress.

**`quiet_p`.** `quiet_p` is the probability that the driver advances the
clock instead of injecting an operation when nothing is runnable. If the
driver always injected an operation in that situation, the system would
never run with only its own timers active. Defects that occur only in that
situation would not be reachable.

## Verification

Add the following 3 checks to the simulation suite.

### Audit of a run

```erlang
ok = eta_run:audit(eta_run:run(my_harness, Opts)).
```

`eta_run:audit/1` checks the fields of a result that show that part of the
run was not determined by the seed.

| Field | Meaning | Remedy |
|---|---|---|
| `modules_loaded` | Code was loaded during the run, so a scheduled process called `code_server`. | Set `preload`. |
| `sched.cold_code` | A process was still waiting on `code_server` when the run ended, so the run was not quiescent when it appeared to be. Each entry names the line that called the module that was not loaded. | Set `preload`. |
| `sched.adopted_late` | Processes ran before the scheduler owned them. | Spawn through `eta_run:spawn_op/1`. |
| `sched.timeouts` | Steps ended before the process reached a `receive`, so the process was suspended at an arbitrary point. | See `eta_sched`. |
| `sched.pid_reuse` | The VM reuses pid values, so the order of pids is not the creation order. `audit/1` does not check this field. It matters only for a system or a harness that depends on the order of pids. | See [Hazards](05-gotchas.md). |
| `stray_timers` | Timers were held by a process that the scheduler does not own, or by a process that has died. | See [Hazards](05-gotchas.md). |
| `net.unmanaged` | A process other than the process being stepped sent a message. | See `eta_net`. |
| `rand.unmanaged` | A process other than the process being stepped drew from `rand`. | See `eta_rand`. |

`eta_run:audit/1` returns `ok` or `{suspect, Reasons}`. It does not return
an error, because the run completed and a violation that the run found is
real. A suspect run is a run that the seed might not reproduce. Assert the
audit result next to the invariants.

### Seed reproduction

Check that a seed produces the same trace on every run. This check is the
most important assertion in the setup.

```erlang
Traces = [maps:get(trace, eta_run:run(my_harness, Opts#{seed => 3})) || _ <- lists:seq(1, 5)],
1 = length(lists:usort(Traces)).
```

Run the check early, on several seeds. Run it again after every change to
the harness or the build configuration. When the check fails, note which
runs differ, not only the number of distinct traces. For example, a grouping
of `[[1], [2,3,4,5]]` has a specific cause and a specific fix, which
[Hazards](05-gotchas.md) describes.

### Trace replay

Check that a recorded trace replays.

```erlang
Original = eta_run:run(my_harness, Opts),
Replayed = eta_run:replay(my_harness, maps:get(trace, Original), Opts),
0 = maps:get(skipped, Replayed).
```

This check is different from the seed reproduction check. It exercises
`replay/3`, and the seed reproduction check exercises `run/2`.

### Sweep of seeds

One seed is one schedule. To test a system, run many seeds with
`eta_run:sweep/3`:

```erlang
#{outcome := ok, runs := 200} =
    eta_run:sweep(my_harness, lists:seq(1, 200), Opts#{audit => true}).
```

`sweep/3` calls `eta_run:run/2` for each seed and stops at the first run that
does not pass.

| Run | Result of `sweep/3` |
|---|---|
| Every run passes | `outcome` is `ok`, and `runs` is the number of seeds. |
| A run violates an invariant | `outcome` is the violation, `seed` is the seed of the run, and `shrunk` is the result of `eta_shrink:shrink/3` on the trace of the run. |
| A run passes its invariants and is suspect, with `audit => true` | `outcome` is `{error, {suspect, Reasons}}`, and `seed` is the seed of the run. |
| A run ends with an error | `outcome` is the error, and `seed` is the seed of the run. |

Set `audit => true` in a test, so that one assertion on `outcome` covers the
invariants and the audit of every run.

Use a loop over `eta_run:run/2` instead when the test needs the result of
every run, for example to count the seeds that fail.

## Results

Do not print a complete result. The two-phase commit example produces a
trace of 123 entries from a run of 25 operations. A shell prints the trace
and truncates the fields after it. Use `eta_run:summary/1`, which replaces
the trace with its length:

```erlang
#{outcome := ok, steps := 96, trace_length := 123} =
    eta_run:summary(eta_run:run(eta_2pc, #{seed => 7, max_ops => 25, max_steps => 20000})).
```

The trace is the input to shrinking and replay. It is not a description of
the failure. An entry such as `{step, 8}` records which process the scheduler
chose. It does not record what the process did. `eta_log` records the events
of the system under test on the same timeline, with process names. Read the
`eta_log` output to understand a failure.
[A worked example: two-phase commit](03-two-phase-commit.md) shows one.

## Next

[A worked example: two-phase commit](03-two-phase-commit.md) is a complete
system under test of about 190 lines, with a planted defect.
