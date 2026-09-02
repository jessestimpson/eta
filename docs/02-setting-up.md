# Setting up a project

This page covers the build configuration, the work of removing nondeterminism
from your own system, and how to tell whether any of it is working. If you'd
rather learn by doing, [A Journey Through DST](06-a-journey-through-dst.md)
builds a project from an empty directory and covers the same material along
the way.

## AI disclosure

This document is pending a human rewrite. We still expect the content to be mostly
correct.

## The parts

```
  eta_run          the driver: turns a seed into a run
    |
    +-- eta_sched  runs one process at a time, choosing from the seeded RNG
    +-- eta_time   virtual clock; timers fire when the driver says so
    +-- eta_log    a record of what your system did, on the same timeline
    +-- your harness   six callbacks (eta_harness)
```

`eta_transform` is the other piece: a parse transform applied to the modules
that make up the system under test. It rewrites their timer, clock, and spawn
calls to point at `eta_time` and `eta_sched` instead of `erlang`, and changes
nothing else. You never name it directly. A module opts in by including one
header.

`eta_run` owns the seed. Every choice comes from a single `rand` state seeded
from it: which process to step, whether to inject a client operation or let
the system make progress, and whatever your workload generator draws. At each
iteration the driver does exactly 1 of 3 things: step a runnable process until
it blocks, inject the next generated operation, or advance the clock to the
next timer deadline. Then it checks your invariants against the frozen system.

## Build configuration

There are 2 decisions to make before anything else: how a module opts in, and
when that opt-in is switched on.

### Wrap the header in one of your own

Every module that takes part in a simulation includes one header. Don't
include `eta.hrl` directly. Write a wrapper of your own,
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

and your modules include that:

```erlang
-include("myapp_eta.hrl").
```

That's the whole opt-in. Under a simulation build the header brings in the
parse transform and the `?ETA_LOG` and `?ETA_LABEL` macros. In any other
build it brings nothing at all, and the module ships unchanged.

Why the wrapper? `eta.hrl` is already guarded by the `DST` define and expands
to nothing without it, but the `-include_lib` line still has to resolve. That
would mean `eta` has to be findable in every compilation, including your
release build. The wrapper makes the include itself conditional, so you can
scope `eta` to the single profile that runs simulations and keep it out of
your deployed app entirely.

Don't skip the `-else.` branch. `?ETA_LABEL` and `?ETA_LOG` are called from
modules you ship, so they have to expand to something when the real header
isn't there. Match `eta.hrl`'s own definitions: `ok` and `0`. Neither macro
evaluates its argument in this form, so anything you log must be free of side
effects, and a variable used only inside one of these will be reported as
unused. Bind it with a leading underscore.

### Run simulations from their own build profile

**In Mix, a `dst` environment and a `mix dst` alias to enter it.** In
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

`dst/` needs its own `test_helper.exs`, the same one `mix new` put in `test/`.

**In rebar3, a `dst` profile, entered as `rebar3 as dst eunit`.**

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

There is no bare `rebar3 dst` equivalent. rebar3 refuses `as` inside an alias
("Namespace 'as' is forbidden"), including via `do`, and setting
`REBAR_PROFILE=dst` from `rebar.config.script` doesn't work because profiles
are resolved before the script is consulted. `REBAR_PROFILE=dst rebar3 eunit`
does work from the command line, or wrap `rebar3 as dst eunit` in a
`Makefile` target if you want a short spelling.

### Why this shape

**Don't forget the `DST` define.** Without it, the header silently contributes
nothing: no transform, so your timers stay on the real clock, and no logging.
We made exactly this mistake in `eta`'s own build, and an example module went
untransformed for a while without anything complaining. Put the define in
before anything else, and put it in exactly one profile so there's one place
to check.

**Why a dedicated profile instead of the test environment?** There's a real
argument for reusing `:test`: `eta_time` falls back to the real `erlang`
functions whenever no virtual clock is running, so a transformed module
behaves normally outside a simulation, and compiling your ordinary suite with
the transform on demonstrates that continuously. We think the separation is
worth more:

- Only one simulation can run per VM, because `eta_time` and `eta_log` keep
  state in named ETS tables. Simulation tests have to be `async: false`.
  Keeping them in their own entry point means that constraint never reaches
  the suite you run all day.
- Your ordinary tests exercise the modules you actually ship. A transformed
  module is close to the shipped one, but it isn't the same module.
- `eta` stays out of every build except the simulation one, which is what the
  wrapper header was for.

**Guard per module, not per application.** You won't want the transform
everywhere. See "the transform boundary" below.

## Find the nondeterminism you can't schedule

Before any of the framework matters, take an inventory of everything your
system touches that the scheduler doesn't own: ports, NIFs, sockets, timers
inside dependencies, and anything that talks to a service over a network.

For [`dgen_registry`](https://github.com/foundationdb-beam/dgen/blob/main/src/dgen_registry.erl) that was the database. Its transactions expire on the
*real* clock, so a process suspended mid-transaction dies with `tooslow`: the
scheduler freezes the process and the database gives up on it. Our only
option was to build a substitute that could meet the determinism
requirements, a pure-Erlang in-memory implementation of the same backend
behaviour.

This is the expensive part of adopting DST, and it's work only you can do.
Estimate it before you commit.

## The transform boundary

Not every module should be transformed, and where you draw the line is a
design decision you'll live with. Transform the modules that *are* the
system, the ones whose timers, spawns, and clock reads belong under the
schedule's control.

Your system is likely to have a client-facing interface. It is best practice to
avoid transforming such modules, as they will be driven by the harness, and
may include real-clock timeouts, for example.

## Qualify your module calls

Qualify your calls with the module name itself; don't rely on imports. The
parse transform will only rewrite fully module-qualified calling conventions:

| From | To |
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
| `rand:uniform/0,1`, `uniform_real/0`, `normal/0,2`, `seed/1,2` | `eta_rand:*` |
| `erlang:spawn/1,3`, `spawn_link`, `proc_lib` equivalents | `eta_sched:*` |
| `gen_server:start/3,4`, `start_link/3,4`, `start_monitor/3,4` | `eta_sched:*` |
| the same six on `gen_statem` | `eta_sched:statem_*` |

The spawn rewrites matter more than they look. A child spawned with a plain
`erlang:spawn` runs briefly on the real scheduler before anything suspends
it. `eta_sched:spawn/1` starts it blocked on a token instead, so there's no
window at all.

## Make your state readable

Invariants run against a system in which every process is suspended, so an
invariant can't call into one.
[Writing a system under test](04-writing-a-system-under-test.md) makes the
full argument. The setup step is a second attribute on the modules whose
state the invariants need:

```erlang
-include("myapp_eta.hrl").
-eta_observe({state, [leader, epoch, applied_version]}).
```

The transform republishes those fields into the process dictionary on every
`gen_server` or `gen_statem` callback return, and `eta_observe:read/1` reads
them back from outside. That works while the process is suspended, in a
couple of microseconds, whatever the mailbox depth:

```erlang
#{leader := L, epoch := E} = eta_observe:read(my_server).
```

Because the fields are republished on every return, they can never be stale.
There's no assignment site anybody can forget.

The attribute takes 2 forms. `{RecordName, Fields}` publishes those fields as
a map, and naming the record means a field that doesn't exist is a compile
error rather than a silently wrong offset. `all` publishes whatever the
callback returned, whatever its shape. Prefer the first form: `read/1` copies
what was published, and it runs after every step.

It's an ordinary module attribute the compiler ignores, so it's inert without
the transform.

## A first run

With a system under test written, which is the
[next page](03-two-phase-commit.md), a run is one call:

```erlang
#{outcome := Outcome, trace := Trace, steps := Steps} =
    eta_run:run(my_harness, #{seed => 7, max_ops => 25, max_steps => 20000}).
```

The options you're likely to touch:

| Option | Default | Meaning |
|---|---|---|
| `seed` | 0 | Fixes the whole run |
| `config` | `#{}` | Passed through to your `init/2` |
| `max_ops` | 50 | Client operations to inject before letting the system settle |
| `max_steps` | 10000 | Safety bound on steps and clock advances together |
| `settle_steps` | 2000 | How much longer to run once the operations are done |
| `op_p` | 0.3 | Chance of injecting rather than stepping, when both are possible |
| `quiet_p` | 0.3 | Chance of letting time pass rather than injecting, when nothing is runnable |
| `check_every` | 1 | Run the invariants every N actions |
| `preload` | `[]` | Applications to load before the run starts. **Name yours.** |
| `log` | `true` | Collect a `eta_log` record of the run |

**Set `preload` on your very first run.** Loading a module on demand is a
synchronous call into `code_server`, which the scheduler doesn't own, so a
scheduled process that reaches cold code blocks on something outside the
schedule. Name your own application. The failure it prevents is on
[page 5](05-gotchas.md), and it's worse than it sounds.

**`settle_steps` is what lets a system with periodic timers finish.** With a
heartbeat, "nothing runnable and nothing pending" never happens, so without a
bounded settle phase every run ends by exhausting the step budget and gets
reported as an error. The settle phase is also useful in its own right: it's
the only part of a run where the invariants are checked with no client
traffic at all.

**`quiet_p` is the chance of letting the clock advance instead of injecting
work when nothing is runnable.** A driver that always injects there would put
a whole class of defect out of reach, because the system would never be left
alone with only its own timers. This option is what makes those bugs
reachable at all.

## Verifying your system is well-configured

**Assert the run's own accounting.**

```erlang
ok = eta_run:audit(eta_run:run(my_harness, Opts)).
```

`eta_run:audit/1` asserts a handful of measurements, and it is useful to
run it in your test suite.

- `modules_loaded` - code loaded mid-run, so a scheduled process called into
  `code_server`. Fix with `preload`.
- `sched.cold_code` - a process still *waiting* on `code_server` when the run
  ended, so what looked like quiescence wasn't. Same fix, and each entry
  names the line that reached the cold module.
- `sched.adopted_late` - processes that ran before the scheduler owned them.
  Fix by spawning through `eta_run:spawn_op/1`.
- `sched.timeouts` - steps that ended without the process reaching a receive,
  so it was suspended wherever it happened to be.
- `stray_timers` - timers held by a process the scheduler doesn't own, or
  that has died. See [page 5](05-gotchas.md).

It answers `{suspect, Reasons}` rather than an error, because the run did
happen and its violation, if any, is real. What you can't do is trust the
seed to give it back. Assert on it next to your invariants.

**Check if a seed reproduces itself.** This is the single most valuable assertion
in the whole setup.

```erlang
Traces = [maps:get(trace, eta_run:run(my_harness, Opts#{seed => 3})) || _ <- lists:seq(1, 5)],
1 = length(lists:usort(Traces)).
```

Run it early, on several seeds, and again whenever you touch anything. When
it fails, pay attention to *which* runs differ rather than how many distinct
traces came out. A grouping of `[[1], [2,3,4,5]]` means something very
specific and very fixable, as [page 5](05-gotchas.md) explains.

**Confirm that a recorded trace replays.**

```erlang
Original = eta_run:run(my_harness, Opts),
Replayed = eta_run:replay(my_harness, maps:get(trace, Original), Opts),
0 = maps:get(skipped, Replayed).
```

This is a different claim from the second one. It exercises `replay/3` rather
than `run/2`.

## Reading a result

Don't print one whole. Even the small two-phase commit example produces a
123-entry trace from a 25-operation run, so a shell renders the schedule and
elides the fields you wanted underneath it.

```erlang
#{outcome := ok, steps := 96, trace_length := 123} =
    eta_run:summary(eta_run:run(eta_2pc, #{seed => 7, max_ops => 25, max_steps => 20000})).
```

The trace is for later, once you have a failure worth shrinking, and even
then it isn't what you read. `{step, 8}` records which process the scheduler
chose and says nothing about what that process did. `eta_log` records what
your *system* did on the same timeline, with your processes named. That's the
thing to read, and [page 3](03-two-phase-commit.md) shows one.

## Next

[A worked example](03-two-phase-commit.md) is a complete system under test,
small enough to read in one sitting, with a bug planted in it.
