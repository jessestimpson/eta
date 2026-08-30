<img src="assets/eta.svg" alt="" width="112" align="right">

# eta

Deterministic simulation testing for the BEAM.

(Said like the Greek letter η, **AY-tuh** or **EE-tuh**.)

When your project's tests run, `eta` transforms your code via an Erlang
`parse_transform` so that it can be driven by a special deterministic scheduler
and a virtual clock. You define a meaningful workload to exercise your system,
and `eta` will help you inject faults to reach interesting behavior. When
pathology is found, `eta` gives you a perfectly reproducible trace to debug.
This all happens at test time; the code that gets deployed to prod is untouched.

## What it does

- **Serializes scheduling.** `eta_sched` suspends every process it owns and
  resumes exactly one at a time, letting it run until it blocks. The next
  process to run is decided by the seed.
- **Virtualizes time.** `eta_time` is a clock that only moves when the driver
  moves it, which it does when nothing is runnable, jumping straight to the
  next deadline. A 30 second timeout costs nothing.
- **Records and replays.** `eta_run` records every decision it made, and
  `replay/3` follows that trace back exactly.
- **Shrinks failures.** `eta_shrink` delta-debugs a failing trace down to the
  decisions that matter, then verifies the result still reproduces.
- **Explains failures.** A trace says which process ran, not what it did.
  `eta_log` records both on one timeline, with your processes named, so a
  counterexample reads as a story instead of a column of integers.
- **Reads frozen state.** `eta_observe` gets a suspended process's state out
  without asking it anything, which is the only way an invariant can inspect a
  system the scheduler has stopped.
- **Injects network faults.** `eta_net` can be configured to automatically inject
  faults in message delivery on simulated Erlang nodes, and to deliver the
  events a real link or node failure produces: `nodedown`/`nodeup` signals,
  `noconnection` DOWNs for every monitor held across the break, and node death as
  a single operation.

## Getting Started

A system under test provides some **strictly deterministic** callbacks (see `eta_harness`), and a run is one
call, with a seed. In this example the seed is `7`:

```erlang
#{outcome := Outcome, trace := Trace} =
    eta_run:run(my_harness, #{seed => 7, max_ops => 25, max_steps => 20000, preload => [my_app]}).
```

When a run fails, shrink it:

```erlang
#{trace := Minimal, verified := true} =
    eta_shrink:shrink(my_harness, Trace, #{seed => 7, max_ops => 25, preload => [my_app]}).
```

The seed produces the same trace each time, and the shrink reduces the size of that trace.

Elixir is supported, and the code stays idiomatic — no renamed call sites, no
facade. Elixir compiles to the same abstract format the parse transform
rewrites, so a Mix compiler (`mix compile.eta`) applies the very same
transform to each opted-in module after compilation. A module opts in with
`use Eta`, via a wrapper of your own that keeps `eta` out of every other
build:

```elixir
defmodule MyServer do
  use MyApp.Eta   # your wrapper: `use Eta` in the :dst build, nothing anywhere else
  use GenServer

  @eta_observe :all

  def init(_) do
    _ = Process.send_after(self(), :tick, 50)   # rewritten to the virtual clock
    {:ok, %{count: 0}}
  end

  def handle_info(:tick, state) do
    _ = Process.send_after(self(), :tick, 50)
    {:noreply, %{state | count: state.count + 1}}
  end
end
```

See [Setting up a project](docs/02-setting-up.md) for the Elixir build
configuration.

`eta` includes some simple distributed systems in order to illustrate DST:

1. A [two-phase commit implementation](test/support/eta_2pc.erl), which is used in `eta`'s own tests.
2. An [ABD Qurom Register](docs/06-a-journey-through-dst.md), that is written as an end-to-end walkthrough.
3. A [leader election by heartbeat lease](test/support/eta_elect.erl), for which correctness relies heavily on the clock, unlike the first two examples.

## Documentation

1. [What DST is](docs/01-what-dst-is.md). Discusses the kinds of bugs we're
   looking for, how the technique works, and how your project implementation
   needs to change to use it.
2. [Setting up a project](docs/02-setting-up.md). Includes build configuration,
   some first steps to remove nondeterminism, and getting the system running
   for the first time.
3. [A worked example](docs/03-two-phase-commit.md). A simple two-phase commit
   implementation, with an included bug for demonstration.
4. [Writing a system under test](docs/04-writing-a-system-under-test.md). The
   behaviour callbacks and the practices around them.
5. [Gotchas and footguns](docs/05-gotchas.md). Nondeterminism can leak in from
   many sources. This page details some common pain points.
6. [A journey through DST](docs/06-a-journey-through-dst.md). The whole thing
   end to end: an empty directory becomes a quorum register with a
   planted bug, and the bug becomes a minimized, replayable failure that
   explains itself.

[docs/design.md](docs/design.md) is still a work in progress. Eventually, it will
be the internal specification for the `eta` project itself.

## Installation

We suggest setting up a separate build profile called `dst`.

```elixir
def deps do
  [{:eta, "~> 0.1", only: :dst}]
end
```

and in rebar3, a `dst` profile can run as `rebar3 as dst eunit`.

Your modules don't include `eta.hrl` directly. They include a wrapper of your
own, `include/myapp_eta.hrl`, which is what keeps `eta` out of every other
build:

```erlang
-ifdef(DST).
-include_lib("eta/include/eta.hrl").
-else.
-define(ETA_LABEL(Label), ok).
-define(ETA_LOG(Event), 0).
-endif.
```

[Setting up a project](docs/02-setting-up.md) has the whole configuration for
both build tools, and the reasons for the design choices.

## Status

Early and under development.

### Known gaps, roughly by size

- **Elixir's `Task` and `Agent` are not simulated.** Both spawn and wait
  inside the Elixir standard library, where the scheduler cannot gate them,
  so under a run their entry points raise by name rather than quietly running
  outside the schedule. `GenServer`, `:gen_statem`, timers, clock reads
  (`DateTime.utc_now/0` included), `receive ... after`, spawns and monitors
  are all covered; see the Elixir section of `eta_transform`'s docs for the
  boundary.
- **One simulation per VM.** `eta_time` and `eta_log` keep state in named ETS
  tables, so runs must be serial. Keep the tests `async: false`. This is one of
  the reasons we suggest running simulations from their own build profile, so
  the constraint stays off your ordinary suite.

## AI full disclosure

 - This software is developed with strong assistance from LLMs and with humans 
   leading the ideas, testing, and debugging. We say this openly because it shaped
   how the project was built. If you are not happy with AI-developed code, this
   software is not for you. This disclosure was adopted from [antirez/ds4](https://github.com/antirez/ds4).
 - We strive to write and edit the documentation for human consumption. LLM-speak
   will eventually be rooted out in favor of imperfect human writing. Documentation
   generated wholly by LLMs must be annotated as such.

## Etymology

The name is short for [**étalon**](https://en.wikipedia.org/wiki/Standard_(metrology)).
You may also think of it as the **E**rlang **T**race [**A**ugur](https://en.wikipedia.org/wiki/Augur).

---

The eta in the logo is outlined from [STIX](https://www.stixfonts.org) General
Italic, used under the SIL Open Font License.
