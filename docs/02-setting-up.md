# Setting up a project

This page covers the build configuration, the work of removing nondeterminism
from your own system, and how to tell whether any of it worked. For a hands-on
version of the same material, [A Journey Through DST](06-a-journey-through-dst.md)
builds a project from an empty directory.

## AI disclosure

This document is pending a human rewrite. We still expect the content to be mostly
correct.

## The parts

```
  eta_run          the driver: turns a seed into a run
    |
    +-- eta_sched  runs one process at a time, choosing from the seeded RNG
    +-- eta_time   virtual clock; timers fire when the driver says so
    +-- eta_log    what your system did, on the same timeline
    +-- your harness   six callbacks (eta_harness)
```

`eta_transform` is the other piece, a parse transform applied to the modules that
make up the system under test. It rewrites their timer, clock and spawn calls to
point at `eta_time` and `eta_sched` instead of `erlang`, and changes nothing
else. You never name it directly; a module opts in by including one header.

`eta_run` owns the seed. Every choice comes from a single `rand` state seeded
from it: which process to step, whether to inject a client operation or let the
system make progress, and whatever your workload generator draws. At each
iteration the driver does exactly one of 3 things. It steps a runnable process
until it blocks, injects the next generated operation, or advances the clock to
the next timer deadline. Then it checks your invariants against the frozen
system.

## Build configuration

2 decisions, and they're the ones to make before anything else: how a module
opts in, and when that opt-in is switched on.

### Wrap the header in one of your own

Every module that takes part in a simulation includes one header. Don't include
`eta.hrl` directly. Write a wrapper of your own, `include/myapp_eta.hrl`:

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

That's the whole opt-in. Under a simulation build it brings the parse transform
and the `?ETA_LOG` and `?ETA_LABEL` macros. Otherwise it brings nothing at all,
so a module carrying it has no relationship to this library and ships unchanged.

`eta.hrl` is already conditional on the `DST` define and already expands to
nothing without it, so what the wrapper buys you is one thing: the *include
itself* is conditional, so a build without `DST` never goes looking for `eta`.
That is the difference between a dependency your project can build without and
one that has to be findable in every compilation of every environment. With the
wrapper you can scope `eta` to the single profile that runs simulations, and a
release build doesn't have it in the tree at all.

The `-else.` branch is not optional, and it's the reason the wrapper is a file
rather than a line. `?ETA_LABEL` and `?ETA_LOG` are called from the modules you
ship, so they have to expand to something when the real header isn't there.
Match `eta.hrl`'s own definitions, above: `ok` and `0`. Neither one evaluates
its argument, so anything you log must be free of side effects, and a variable
used *only* inside one of these will be reported unused — bind it with a
leading underscore.

### In Elixir: `use Eta`

Elixir doesn't have an include-file mechanism, and Elixir's macros cannot
cleanly override Kernel functions like `send/2`, `spawn/1`, or
`Process.send_after/3`. So instead of a parse transform, `use Eta` provides an
**explicit set of macros** that route timer, spawn, and network calls through
`eta`'s virtualized versions when `:eta` is a compile-time dependency, and
through the Elixir stdlib otherwise. This API is a WIP and is subject to change.

```elixir
defmodule MyServer do
  use Eta
  @behaviour :gen_server

  @eta_observe :all

  def init(_) do
    Eta.label(:my_server)
    _ = Eta.send_after(self(), :tick, 50)
    {:ok, %{count: 0}}
  end

  def handle_cast(:tick, state) do
    Eta.log({:tick, state.count})
    {:noreply, %{state | count: state.count + 1}}
  end
end
```

Each macro checks at compile time whether `:eta` is available
(`Code.ensure_loaded?(:eta_time)`), and expands to either the `:eta_*` call or
the stdlib equivalent. There is no runtime overhead. The same source compiles
under both a DST build (where `:eta` is a dependency) and a release build
(where it isn't), with no deprecation warnings and no parse transform.

`Eta.label/1` and `Eta.log/1` are the Elixir equivalents of `?ETA_LABEL` and
`?ETA_LOG`. They expand to `:eta_log.label/1` and `:eta_log.log/1` under a DST
build, and to `:ok` and `0` otherwise.

**The available macros:**

| Macro | DST build | Release build |
|---|---|---|
| `Eta.send_after(dest, msg, ms)` | `:eta_time.send_after(ms, dest, msg)` | `Process.send_after(dest, msg, ms)` |
| `Eta.cancel_timer(ref)` | `:eta_time.cancel_timer(ref)` | `Process.cancel_timer(ref)` |
| `Eta.monotonic_time()` | `:eta_time.monotonic_time()` | `:erlang.monotonic_time()` |
| `Eta.spawn(fun)` | `:eta_sched.spawn(fun)` | `Kernel.spawn(fun)` |
| `Eta.spawn_link(fun)` | `:eta_sched.spawn_link(fun)` | `Kernel.spawn_link(fun)` |
| `Eta.spawn_monitor(fun)` | `:eta_sched.spawn_monitor(fun)` | `Kernel.spawn_monitor(fun)` |
| `Eta.send(dest, msg)` | `:eta_net.send(dest, msg)` | `Kernel.send(dest, msg)` |
| `Eta.cast(server, msg)` | `:eta_net.cast(server, msg)` | `GenServer.cast(server, msg)` |
| `Eta.call(server, req, timeout \\ 5000)` | `:eta_net.call(server, req, timeout)` | `GenServer.call(server, req, timeout)` |
| `Eta.reply(from, reply)` | `:eta_net.reply(from, reply)` | `GenServer.reply(from, reply)` |
| `Eta.monitor(pid)` | `:eta_net.monitor(:process, pid)` | `Process.monitor(pid)` |
| `Eta.demonitor(ref)` | `:eta_net.demonitor(ref)` | `Process.demonitor(ref)` |
| `Eta.start_link(mod, args, opts \\ [])` | `:eta_sched.start_link(mod, args, opts)` | `GenServer.start_link(mod, args, opts)` |
| `Eta.start(mod, args, opts \\ [])` | `:eta_sched.start(mod, args, opts)` | `GenServer.start(mod, args, opts)` |
| `Eta.label(value)` | `:eta_log.label(value)` | `:ok` |
| `Eta.log(value)` | `:eta_log.log(value)` | `0` |

**Use `@behaviour :gen_server` instead of `use GenServer`.** `use GenServer`
generates default callback clauses; `Eta`'s `@before_compile` callback wraps
the clauses you write, and defaults you didn't write are clutter. Declaring
the behaviour directly gives the wrapper a clean set of clauses to work with:

```elixir
defmodule MyServer do
  use Eta
  @behaviour :gen_server

  def init(_), do: {:ok, %{}}
  def handle_call(_, _, s), do: {:reply, :ok, s}
  def handle_cast(_, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}
  def terminate(_, _), do: :ok
  def code_change(_, s, _), do: {:ok, s}
end
```

**`@before_compile` wraps your callbacks.** When `@eta_observe` is set,
`use Eta` installs a `@before_compile` callback that rewrites each
`gen_server` callback body to publish its returned state to the process
dictionary (where `:eta_observe.read/1` finds it), and to route `handle_call/3`
replies through `:eta_net.reply/2`. This is the Elixir equivalent of the
observe and reply-routing passes in `eta_transform`, done at the Elixir AST
level via `Module.get_definition/2` rather than at the Erlang AST level.

**`receive ... after` is not virtualized.** The parse transform rewrites this
language construct; a macro cannot. A `receive ... after` timeout runs on the
real clock. Use `Eta.send_after/3` to send a message to yourself and match on
it in a plain `receive` instead.

**`gen_statem` state timeouts are not virtualized.** The parse transform
intercepts `{state_timeout, ...}` actions before OTP sees them; a macro
cannot. Erlang modules using `gen_statem` should continue to use the parse
transform via `eta.hrl`.

For a project that wants the same source to compile with and without `eta`,
the macros already handle it: each one checks `Code.ensure_loaded?(:eta_time)`
at compile time. So you can `use Eta` unconditionally, and `:eta` only needs to
be a dependency in your DST build's `mix.exs`.

```elixir
defp deps do
  [{:eta, "~> 0.1", only: :dst, runtime: false}]
end
```

In a DST build, the macros expand to `:eta_*` calls. In a release build, they
expand to stdlib calls, and `:eta` is not a dependency.

### Run simulations from their own build profile

**In Mix, a `dst` environment and a `mix dst` to enter it.** In `project/0`:

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

  # `mix test` refuses to run in an environment that isn't :test unless MIX_ENV
  # says so explicitly. `preferred_envs` above has already put us in :dst;
  # this states it in the environment too, which is both true and what that
  # check is asking for.
  defp dst(args) do
    System.put_env("MIX_ENV", "dst")
    Mix.Task.run("test", args)
  end
```

`dst/` needs its own `test_helper.exs`, the same one `mix new` put in `test/`.

**Elixir modules that `use Eta` need Erlang compiled first.** `lib/eta.ex`
calls `Code.ensure_loaded?(:eta_time)` at macro expansion time to decide
whether `:eta` is available, so the Erlang transform modules must be on the
code path before any Elixir module that `use Eta` is compiled. Add a compile
alias to enforce the order:

```elixir
defp aliases do
  [
    compile: ["compile.erlang", "compile.elixir", "compile.app"],
    dst: &dst/1
  ]
end
```

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

There is no bare `rebar3 dst`. An entry point that switches profile would have
to be `{alias, [{dst, [{as, "dst eunit"}]}]}`, and rebar3 refuses `as` inside an
alias — *"Namespace 'as' is forbidden"* — including via `do`. Wrap it in a
`Makefile` target if you want a short spelling. `REBAR_PROFILE=dst rebar3 eunit`
is the other native one; setting that variable from `rebar.config.script` does
not work, because profiles are resolved before the script is consulted.

### Why this shape

**The define is a contract, not a convention.** Forget it and the header
silently contributes nothing: no transform, so your timers stay on the real
clock, and no logging. This library made exactly that mistake in its own build,
and its example module went untransformed for a while without anything
complaining. Put the define in before anything else, and put it in exactly one
profile so there's one place to check.

**A dedicated profile, not the whole test environment.** An earlier version of
this page recommended the opposite, and the argument for it is real: `eta_time`
falls back to the real `erlang` functions whenever no virtual clock is running,
so a transformed module behaves outside a simulation exactly as it did before,
and compiling your ordinary suite with the transform on demonstrates that
continuously. We now think the separation is worth more:

- Only one simulation can run per VM, since `eta_time` and `eta_log` keep state
  in named ETS tables. Simulation tests have to be `async: false`. Keeping them
  in their own entry point means that constraint never reaches the suite you
  run all day.
- Your ordinary tests then exercise the modules you actually ship. A
  transformed module is close to the shipped one, but it isn't it.
- `eta` stays out of every build but this one, which is what the header
  wrapper was for.
- Toggling a define or editing a parse transform doesn't reliably recompile the
  modules that depend on it ([page 5](05-gotchas.md)). Two environments means
  two build directories, so the 2 builds can't hand each other a stale module.

**Guard per module, not per application.** You won't want the transform
everywhere, for reasons in "the transform boundary" below.

## Find the nondeterminism you can't schedule

Before any of the framework matters, take an inventory of everything your system
touches that the scheduler doesn't own. Ports, NIFs, sockets, timers inside
dependencies, and anything that talks to a service over a network.

For `dgen_registry` that was the database. Its transactions expire on the *real*
clock, so a process suspended mid-transaction dies with `tooslow`: the scheduler
freezes the process and the database gives up on it. Our only option was to
build a substitute that could meet the determinism requirements, a pure-Erlang
in-memory implementation of the same backend behaviour.

That is the expensive part of adopting DST, and it's work only you can do.
Estimate it before you commit.

## The transform boundary

Not every module should be transformed, and where you draw the line is a design
decision you'll live with.

Transform the modules that *are* the system, the ones whose timers, spawns and
clock reads belong under the schedule's control. For the registry that's 6
modules: the member, elector and connector processes, plus the generic server,
queue and transaction machinery underneath them.

Leave client-facing modules alone if they hold polling loops. The registry's
public API module has a function that waits for the local node to become ready
by polling with `timer:sleep/1`. Under a frozen clock that loop never
terminates, so the module stays outside the boundary on purpose.

That costs you something. An untransformed client's `gen_server:call` timeout is
on the real clock, so when it fires is decided by wall clock rather than by the
schedule. Our workaround is to configure it high enough that it can't fire
during a run, which means the behaviour it guards isn't exercised at all. That's
an acknowledged gap, not a solved problem. Write it down somewhere, or somebody
will "fix" the boundary by transforming one more module and spend a day on the
resulting hang.

## Qualify your time calls

The transform rewrites qualified calls, and only qualified calls:

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
| `erlang:spawn/1,3`, `spawn_link`, `proc_lib` equivalents | `eta_sched:*` |
| `gen_server:start/3,4`, `start_link/3,4`, `start_monitor/3,4` | `eta_sched:*` |
| the same six on `gen_statem` | `eta_sched:statem_*` |

In Elixir, these rewrites are **explicit** rather than automatic. The `Eta.*`
macros (table above) expand to the `:eta_*` calls when `:eta` is a
compile-time dependency, and to the stdlib calls otherwise. A bare
`Process.send_after/3` or `GenServer.cast/2` in an Elixir module is **not**
rewritten — write `Eta.send_after/3` or `Eta.cast/2` instead. The trade-off
is clarity: every virtualized call is visible at the call site, and the same
source compiles with and without `:eta` as a dependency.

A bare `monotonic_time()` is left alone, and has to be. None of these functions
are auto-imported, so an unqualified call names something your own module
defines, and rewriting it would break the module. Code that wants to be
simulated has to qualify its time calls, which is the prevailing style anyway.

`timer:sleep/1` isn't rewritten either, deliberately, and a process that sleeps
under simulation hangs forever. [Page 5](05-gotchas.md) has why.

The spawn rewrites matter more than they look. A child spawned with a plain
`erlang:spawn` runs briefly on the real scheduler before anything suspends it.
`eta_sched:spawn/1` starts it blocked on a token instead, so there's no window
at all.

## Make your state readable

Invariants run against a system in which every process is suspended, so an
invariant can't call into one. [Writing a system under test](04-writing-a-system-under-test.md)
makes the full argument. The setup step is a second attribute on the modules
whose state the invariants need:

```erlang
-include("myapp_eta.hrl").
-eta_observe({state, [leader, epoch, applied_version]}).
```

The transform republishes those fields into the process dictionary on every
`gen_server` or `gen_statem` callback return, and `eta_observe:read/1` reads them back from
outside. That works while the process is suspended, in a couple of microseconds,
whatever the mailbox depth:

```erlang
#{leader := L, epoch := E} = eta_observe:read(my_server).
```

Publishing on every return is what makes staleness impossible. There's no
assignment site anybody can forget.

The attribute takes 2 forms and neither of them guesses. `{RecordName, Fields}`
publishes those fields as a map, and naming the record is what lets a field that
doesn't exist be a compile error rather than a silently wrong offset. `all`
publishes whatever the callback returned, whatever its shape, which is usually
the wrong trade since `read/1` copies what was published and runs after every
step.

It's an ordinary module attribute the compiler ignores, so it's inert without
the transform.

## A first run

With a system under test written, which is the [next page](03-two-phase-commit.md),
a run is one call:

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

3 of those deserve more.

**`preload` is the one to set on your first run.** Loading a module on demand is
a synchronous call into `code_server`, which the scheduler doesn't own, so a
scheduled process that reaches cold code blocks on something outside the
schedule. Name your own application. The failure it prevents is on
[page 5](05-gotchas.md), and it's worse than it sounds.

**`settle_steps` is what lets a system with periodic timers finish.** A
heartbeat means "nothing runnable and nothing pending" never happens, so without
a bounded settle phase every run ends by exhausting the step budget and gets
reported as an error. It isn't dead time either: it's the only part of a run
where the invariants are checked with no client traffic at all.

**`quiet_p` is the probability of letting the clock advance rather than
injecting work when nothing is runnable.** The obvious driver always injects
there, which puts a whole class of defect out of reach, because the system is
never left alone with only its own timers for company. It's less a tuning knob
than the thing that makes those bugs reachable at all.

## Checking that any of this works

3 measurements, in order of how much they tell you.

**The run's own accounting.**

```erlang
ok = eta_run:audit(eta_run:run(my_harness, Opts)).
```

Several fields in a result mean "part of this interleaving was decided by wall
clock rather than by the schedule", and a run with any of them set is one whose
seed won't reproduce. `audit/1` checks them, and keeps checking them as more get
added:

- `modules_loaded` - code loaded mid-run, so a scheduled process called into
  `code_server`. Fix with `preload`.
- `sched.cold_code` - a process still *waiting* on `code_server` when the run
  ended, so what looked like quiescence wasn't. Same fix, and each entry names
  the line that reached the cold module.
- `sched.adopted_late` - processes that ran before the scheduler owned them.
  Fix by spawning through `eta_run:spawn_op/1`.
- `sched.timeouts` - steps that ended without the process reaching a receive, so
  it was suspended wherever it happened to be.
- `stray_timers` - timers held by a process the scheduler doesn't own, or that
  has died. See [page 5](05-gotchas.md).

It answers `{suspect, Reasons}` rather than an error, because the run happened
and its violation, if any, is real. What you can't do is trust the seed to give
it back. Assert on it next to your invariants.



**That a seed reproduces itself.** This is the single most valuable assertion in
the whole setup.

```erlang
Traces = [maps:get(trace, eta_run:run(my_harness, Opts#{seed => 3})) || _ <- lists:seq(1, 5)],
1 = length(lists:usort(Traces)).
```

Run it early, on several seeds, and again whenever you touch anything. When it
fails, pay attention to *which* runs differ rather than how many distinct traces
came out. A grouping of `[[1], [2,3,4,5]]` means something very specific and
very fixable, as [page 5](05-gotchas.md) explains.

**That a recorded trace replays.**

```erlang
Original = eta_run:run(my_harness, Opts),
Replayed = eta_run:replay(my_harness, maps:get(trace, Original), Opts),
0 = maps:get(skipped, Replayed).
```

That's a different claim from the second one. It exercises `replay/3` rather
than `run/2`, and conflating the 2 let a real bug live in this framework for
months. Test both.

## Reading a result

Don't print one whole. A 20-operation run produces a few hundred trace entries,
so a shell renders the schedule and elides the fields you wanted underneath it.

```erlang
#{outcome := ok, steps := 97, trace_length := 213} =
    eta_run:summary(eta_run:run(my_harness, Opts)).
```

The trace is for later, once you have a failure worth shrinking, and even then
it isn't what you read. `{step, 8}` records which process the scheduler chose
and says nothing about what that process did. `eta_log` records what your
*system* did on the same timeline, with your processes named. That's the thing
to read, and [page 3](03-two-phase-commit.md) shows one.

## Next

[A worked example](03-two-phase-commit.md) is a complete system under test,
small enough to read in one sitting, with a bug planted in it.
