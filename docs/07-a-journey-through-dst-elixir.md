# A Journey Through DST, in Elixir

This page guides you through the `eta` features. We start from scratch and build
an [ABD Quorum Register](https://scholar.google.com/citations?view_op=view_citation&hl=en&user=eoMK92MAAAAJ&citation_for_view=eoMK92MAAAAJ:d1gkVwhDpl0C) in Elixir. `eta` requires you to build
your distributed system-under-test in a specific manner, to avoid leaking
nondeterminism. This walkthrough explains those requirements through an actual
implementation.

This document is the Elixir twin of [A Journey Through DST](06-a-journey-through-dst.md),
which builds the same system in Erlang. The prose is kept in lockstep between the
two; only the code and the captured outputs differ. If you change one document,
account for the change in the other.

An **ABD Quorum Register** is a simple distributed system that shares a single value,
replicated across 3 nodes. The value is meant to stay correct while clients read
and write concurrently. It's designed for message-passing systems, like the BEAM,
and so its implementation is fairly simple. It also features a counter-intuitive
step that leads to an inconsistency bug when omitted, making it a good example
for demonstrating DST's bug-finding capabilities.

We recommend you have read [What DST Is](01-what-dst-is.md) to establish a baseline
for the technique.

## What ABD is

We'll start 3 processes, each one is labeled as a "replica", and they all participate
in message passing to each other. Each process holds a `{timestamp, value}` tuple in
its state. For a quorum to be achieved, 2 of the 3 must agree on the tuple contents.

The system provides the following API:

- **Write(V)**: ask a quorum (a set of processes) for their timestamps, take the
  highest, then write `{highest + 1, v}` to a quorum (not necessarily the same
  process set).
- **Read()**: ask a quorum, take the pair with the highest timestamp, **write
  that pair back to a quorum**, then return the value.

The write-back in the read path is the counter-intuitive part. It may look
redundant: you're writing back a value you just read a couple nanoseconds ago.
But it turns out to be critical to the consistency of the system, and we'll
demonstrate exactly that over the course of this document.

## Step 1: create the project

We'll put the project beside your `eta` checkout so the dependency can be a
plain relative path. This time the whole system is ordinary Elixir — the
register, the harness, and the tests.

```bash
mix new abd
```

## Step 2: build configuration

Clear the Elixir scaffolding and make the directories we need:

```bash
cd abd
rm -rf lib test/abd_test.exs
mkdir -p lib/abd dst
cp test/test_helper.exs dst/
```

Simulations get their own build environment, `dst`, and we'll put all our
eta test files in the `dst/` directory.
`test/` stays untouched for ordinary tests.

Then edit `mix.exs`. In `project/0`, add these keys:

```elixir
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env()),
      compilers: Mix.compilers() ++ if(Mix.env() == :dst, do: [:eta], else: []),
      aliases: aliases(),
```

Replace the commented-out examples in `deps/0` with:

```elixir
      {:eta, path: "../eta", only: :dst}
      # --- or ---
      {:eta, git: "https://github.com/jessestimpson/eta.git", only: :dst}
```

Add a `cli/0` next to `project/0`:

```elixir
  def cli do
    [preferred_envs: [dst: :dst]]
  end
```

and the private functions at the bottom:

```elixir
  # The ABD register itself is ordinary Elixir in lib/. The eta harness lives in
  # dst/ and only exists for the dst env
  defp elixirc_paths(:dst), do: ["lib", "dst"]
  defp elixirc_paths(_), do: ["lib"]

  # `mix dst` runs dst/, `mix test` runs test/.
  defp test_paths(:dst), do: ["dst"]
  defp test_paths(_), do: ["test"]

  defp aliases do
    [dst: &dst/1]
  end

  defp dst(args) do
    System.put_env("MIX_ENV", "dst")
    Mix.Task.run("test", args)
  end
end
```

Now the wrapper module that our own modules will use, `lib/abd/eta.ex`:

```elixir
defmodule Abd.Eta do
  @dst Mix.env() == :dst

  defmacro __using__(opts) do
    if @dst do
      quote do
        use Eta, unquote(opts)
      end
    else
      quote do
        Module.register_attribute(__MODULE__, :eta_observe, persist: true)
        Module.register_attribute(__MODULE__, :eta_net, persist: true)
        Module.register_attribute(__MODULE__, :eta_after, persist: true)
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

Then:

```bash
mix deps.get && MIX_ENV=dst mix compile
```

If the compile fails, double-check your configuration.

### Project configuration details

**The wrapper module is what makes `only: :dst` possible.** It is the Elixir
counterpart of the Erlang walkthrough's `abd_eta.hrl`: your modules say
`use Abd.Eta`, and every build except `:dst` compiles them with no relationship
to `eta` at all. The non-dst branch still registers the eta attributes, so an
`@eta_observe` you add later is a persisted attribute in every build rather
than an "unused attribute" warning in the ones without `eta`.

**The `:eta` entry in `compilers` is the transform.** Elixir has no
`parse_transform` hook, so `mix compile.eta` runs after the `:elixir` compiler
and applies `eta_transform` to each opted-in module's compiled beam. It is
gated on the env for the same reason the dependency is: in any other
environment the task does not exist. When it runs, the compile output says so:

```
Transformed 1 module(s) with eta_transform
```

**A `dst` environment, not the test env.** `mix test` and
`mix dst` are kept separate from each other: ordinary
tests exercise the modules you actually ship, and the simulation suite stays out
of their way. [Setting up a project](02-setting-up.md) has the full argument.

## Step 3: the replica GenServer

`lib/abd/replica.ex`:

```elixir
defmodule Abd.Replica do
  use Abd.Eta
  use GenServer

  defstruct index: nil, ts: {0, 0}, val: nil

  def start_link(index) do
    GenServer.start_link(__MODULE__, index)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  # Asynchronous on purpose. A client sends to all three replicas and takes the
  # first two answers, so which two those are has to be a scheduling decision.
  def read(pid, ref, from) do
    GenServer.cast(pid, {:read, ref, from})
  end

  def write(pid, ref, from, ts, val) do
    GenServer.cast(pid, {:write, ref, from, ts, val})
  end

  # For poking at a replica by hand. Never call this from check/1: under the
  # scheduler the replica is suspended and the call can never be answered.
  def get(pid) do
    GenServer.call(pid, :get)
  end

  def init(index) do
    {:ok, %__MODULE__{index: index}}
  end

  def handle_call(:get, _from, st) do
    {:reply, {st.ts, st.val}, st}
  end

  def handle_cast({:read, ref, from}, st) do
    send(from, {:read_ack, ref, st.index, st.ts, st.val})
    {:noreply, st}
  end

  def handle_cast({:write, ref, from, ts, val}, st) do
    st = store(ts, val, st)
    send(from, {:write_ack, ref, st.index})
    {:noreply, st}
  end

  # Standard ABD: keep whichever pair carries the higher timestamp. Timestamps
  # are {seq, writer_id} so two writers that pick the same seq still order.
  defp store(ts, val, st) when ts > st.ts, do: %{st | ts: ts, val: val}
  defp store(_ts, _val, st), do: st
end
```

Let's try it out in the `iex` shell:

```bash
MIX_ENV=dst iex -S mix
```

```elixir
{:ok, p} = Abd.Replica.start_link(1)
Abd.Replica.get(p)
Abd.Replica.write(p, make_ref(), self(), {1, 7}, :hello)
flush()
Abd.Replica.get(p)
```

RESULT: `{{0, 0}, nil}`, a `write_ack`, then `{{1, 7}, :hello}`.

### 3 things worth calling out

**Casts, not `GenServer.call`.** ABD is based on fully non-blocking message
passing. Blocking calls would collect answers in a fixed order. Casts let
a client take the first set that arrive, which makes the quorum set a scheduling
choice, which would typically be a source of nondeterminism.

**Timestamps are `{seq, writer_id}`, not integers.** 2 concurrent writers can
read the same maximum and both pick `seq + 1`. Including another identifier
gets us a total order. This is an ABD implementation detail that you are free
to ignore for the purposes of the demo.

**`get/1` is a trap, and we'll see why later.** `get/1` is useful for poking
at a replica in `iex`. When we write `check/1`, you'll notice we don't use it.
This is because the process will be suspended during the check and unable to
respond to any incoming requests. `check/1` must read shared memory rather than
do message passing.

### The `use Abd.Eta` line

Technically you can leave this out at this step, but if you do, remember to add it
back in later, where it will be needed.

## Step 4: the client

`lib/abd/client.ex`:

```elixir
defmodule Abd.Client do
  use Abd.Eta

  @quorum 2

  # Read phase to find the highest timestamp, then write one past it.
  def write(replicas, writer_id, value) do
    {{seq, _}, _} = query_phase(replicas)
    ts = {seq + 1, writer_id}
    :ok = write_phase(replicas, ts, value)
    ts
  end

  # Read phase, then write back what we found before returning it.
  def read(replicas) do
    {ts, val} = query_phase(replicas)
    :ok = write_phase(replicas, ts, val)
    {ts, val}
  end

  # Ask everyone, keep the best answer from the first quorum to reply. Which
  # replicas those are is decided by the schedule, which is the point.
  defp query_phase(replicas) do
    ref = make_ref()
    for pid <- replicas, do: Abd.Replica.read(pid, ref, self())
    collect_reads(ref, @quorum, {{0, 0}, nil})
  end

  defp collect_reads(_ref, 0, best), do: best

  defp collect_reads(ref, n, best) do
    receive do
      {:read_ack, ^ref, _index, ts, val} ->
        collect_reads(ref, n - 1, best(best, {ts, val}))
    end
  end

  defp best({best_ts, _}, {ts, val}) when ts > best_ts, do: {ts, val}
  defp best(best, _candidate), do: best

  defp write_phase(replicas, ts, val) do
    ref = make_ref()
    for pid <- replicas, do: Abd.Replica.write(pid, ref, self(), ts, val)
    collect_writes(ref, @quorum)
  end

  defp collect_writes(_ref, 0), do: :ok

  defp collect_writes(ref, n) do
    receive do
      {:write_ack, ^ref, _index} -> collect_writes(ref, n - 1)
    end
  end
end
```

Drive the whole protocol:

```elixir
reps = Enum.map(1..3, fn i -> {:ok, p} = Abd.Replica.start_link(i); p end)
Abd.Client.read(reps)
Abd.Client.write(reps, 1, :v1)
Abd.Client.read(reps)
Abd.Client.write(reps, 2, :v2)
Abd.Client.read(reps)
```

RESULT: `{{0, 0}, nil}`, `{1, 1}`, `{{1, 1}, :v1}`, `{2, 2}`,
`{{2, 2}, :v2}`.

### What to notice

**The `eta` project is still not really involved.** We've defined the distributed
system with normal Elixir code, and we'll only need to tweak it to make it compatible
with `eta`. The code that you ship to production is the same code that is under test.

**`Abd.Client` does not start a process.** It runs inside whatever
process calls it, which right now is your `iex` shell. In a moment the harness
will spawn a process per operation and run these same functions there. Keeping
the 2 things separate is what lets a client be a schedulable participant in the
concurrency without the protocol knowing anything about it.

**`make_ref()` is nondeterministic, but not harmful to the test.** Refs differ between
runs, and unseeded identity is a genuine source of nondeterminism. It's
harmless in this case because the value of the ref never decides anything. It only matches a
client's own replies. Refs and pids break replay when their values
influence *control flow*, which would be very atypical for conventional Elixir.

**Some messages can get stuck in the mailbox.** A quorum is 2, so after `collect_reads`
returns there's still a `read_ack` sitting in the mailbox, and the next phase's
`receive` scans straight past it on a different ref. That's what real ABD code
looks like, and it exercises the trickiest part of `eta_sched`: a process
blocked in a selective receive *with a non-empty mailbox*. `eta` can handle this
just fine. Your actual code will probably want to flush these out, but we
skip that here.

**And the read does a write-back.** Right now it looks redundant, but it's not.
We'll delete it later and observe the result.

## Step 5: the harness

Everything so far has been the actual ABD register. Next is the harness: a
behaviour implementation that `eta_run` will exercise. This module could just
as well be Erlang, if you want. It runs in the driver process, so it never
needs the transform at all.

`dst/abd_harness.ex`:

```elixir
defmodule Abd.Harness do
  @behaviour :eta_harness

  # ---------------------------------------------------------------------------
  # Setup and teardown
  # ---------------------------------------------------------------------------

  @impl true
  def init(_seed, config) do
    tab = :ets.new(:abd, [:public, :ordered_set])
    n = Map.get(config, :replicas, 3)

    replicas =
      for i <- 1..n do
        {:ok, p} = Abd.Replica.start_link(i)
        p
      end

    {:ok, %{tab: tab, replicas: replicas, clients: [], next_op: 1}}
  end

  @impl true
  def terminate(%{tab: tab, replicas: replicas, clients: clients}) do
    for c <- clients, do: Process.exit(c, :kill)
    for p <- replicas, do: Abd.Replica.stop(p)

    try do
      :ets.delete(tab)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # What to schedule
  # ---------------------------------------------------------------------------

  @impl true
  def processes(%{replicas: replicas, clients: clients}) do
    replicas ++ for c <- Enum.reverse(clients), Process.alive?(c), do: c
  end

  # ---------------------------------------------------------------------------
  # The workload
  # ---------------------------------------------------------------------------

  @impl true
  def generate(%{next_op: n}, rand0) do
    {roll, rand} = :rand.uniform_s(rand0)

    if roll < 0.4 do
      {{:write, n, {:v, n}}, rand}
    else
      {{:read, n}, rand}
    end
  end

  @impl true
  def execute(op, %{tab: tab, replicas: replicas, clients: clients} = sut) do
    n = op_number(op)
    client = :eta_run.spawn_op(fn -> run_op(op, tab, replicas) end)
    %{sut | clients: [client | clients], next_op: n + 1}
  end

  defp op_number({:write, n, _value}), do: n
  defp op_number({:read, n}), do: n

  # Both phases are stamped with :eta_log.log/1, which records the event and
  # returns the sequence number it filed it under. Only one process runs at a
  # time, so those numbers are a faithful total order of events - and they point
  # straight back into the log we learn to read in step 11.
  defp run_op({:write, n, value}, tab, replicas) do
    start = :eta_log.log(:started)
    ts = Abd.Client.write(replicas, n, value)
    :ets.insert(tab, {{:write, n}, start, :eta_log.log({:finished, ts}), ts, value})
  end

  defp run_op({:read, n}, tab, replicas) do
    start = :eta_log.log(:started)
    {ts, val} = Abd.Client.read(replicas)
    :ets.insert(tab, {{:read, n}, start, :eta_log.log({:finished, ts}), ts, val})
  end

  # ---------------------------------------------------------------------------
  # The invariant
  # ---------------------------------------------------------------------------

  # Regularity: if one read finished before another started, the later read may
  # not report an older timestamp than the earlier one.
  @impl true
  def check(%{tab: tab}) do
    reads = for {{:read, _}, s, f, ts, _} <- :ets.tab2list(tab), do: {s, f, ts}
    inversion(Enum.sort(reads))
  end

  defp inversion(reads) do
    case for a <- reads, b <- reads, sequential?(a, b), backwards?(a, b), do: {a, b} do
      [] ->
        :ok

      [{a, b} | _] ->
        {:violation,
         %{
           property: :no_new_old_inversion,
           detail: "a later read reported an older value",
           earlier: a,
           later: b
         }}
    end
  end

  defp sequential?({_start_a, finish_a, _ts_a}, {start_b, _finish_b, _ts_b}),
    do: finish_a < start_b

  defp backwards?({_start_a, _finish_a, ts_a}, {_start_b, _finish_b, ts_b}), do: ts_b < ts_a
end
```

Compile:

```bash
MIX_ENV=dst mix compile
```

RESULT: compiles clean.

### `init/2` hands over an idle system

`start_link` returns once `init/1` has run, and a fresh replica has an empty
mailbox, so this system is quiescent - the replicas are at a steady-state. It's
important to maintain this property, because `eta_run` will suspend all processes.
If it suspends a busy process, then the actual moment in time of that suspend action
is nondeterministic. Make sure the system's processes are idle.

The ets table is `ordered_set`, which is a determinism decision, because `set`
does not specify a term order in the API contract.

### `processes/1` and `Enum.reverse`

`eta_sched` assigns ids in registration order, and the trace records ids, so
the order this callback returns is part of the contract. We prepend new clients
to the list because that's cheap, which means the list itself is in reverse
chronological order, so we reverse it here to hand them over oldest first.

### `generate/2` draws from the state it's handed

40% writes, 60% reads, drawn from the `rand` state `eta_run` passes in and
returning the advanced state. Drawing from anywhere else, `:rand.uniform/1` or
the clock or `:erlang.unique_integer/0`, breaks replay silently. Again, we're
always on the lookout for nondeterminism leaks.

#### Why generating and executing are separate

`eta` will help us both run new seeds and replay old ones. The replay will avoid
calling generate, but must still call execute.

### `execute/2` spawns using a special `eta` function

Every process is suspended, and `eta_sched` is the only entity allowed to
progress the system. A special `:eta_run.spawn_op/1` function must be used. It
prevents the newly spawned process from executing any real code. The pid is
handed over to `eta_run` and `eta_sched` to progress.

### `check/1` is for defining the rules

Our invariant is known as "regularity", sometimes called *no new-old inversion*:

> Once a read has returned a value, no read that starts later may return an older one.

Our `check/1` confirms that the system's timestamps make sense in the context of this
invariant. Every operation gets a start and finish stamp from `:eta_log.log/1`.
Since only one process is ever running at a time, its sequence number reliably
represents the total order of operations. We'll make additional use of `eta_log` later.

As mentioned earlier, we can't call `Abd.Replica.get/1`. We can't do any message
passing to the system under test. Currently, we're reading from a client-driven
ets table. The last step of this guide will explain how to probe the
hidden state of your system.

## Step 6: the first run

Everything is in place. We're ready to do our first deterministic run.

```bash
MIX_ENV=dst iex -S mix
```

```elixir
opts = %{seed: 1, max_ops: 20, max_steps: 20_000, preload: [:abd]}
result = :eta_run.run(Abd.Harness, opts)
:eta_run.summary(result)
:eta_run.audit(result)
```

TODO - explain opts, especially `seed` and `max_ops`.

The `preload` option is required, and we'll explain why coming up.

RESULT:

```elixir
%{
  outcome: :ok,
  seed: 1,
  ops: 20,
  steps: 103,
  clock_ms: 0,
  skipped: 0,
  stray_timers: 0,
  modules_loaded: [],
  net: %{},
  sched: %{
    processes: 23,
    exited: 20,
    adopted_late: 0,
    timeouts: 0,
    steps: 103,
    cold_code: [],
    unpinned: 0
  },
  trace_length: 124
}
```

and `:ok` from `audit/1`.

`summary/1` reduces the rendered size of `result` so that you can read it on
the `iex` shell. The `trace` entries can get quite long, so we simply
report the length of the trace in the summary. We'll make the trace easier to
read later.

**`steps` is the number of scheduler steps taken by `eta_sched`** If you see
20 steps for 20 operations, and nothing `exited`, check `modules_loaded`. A
module being lazily loaded during runtime can break determinism. We'll handle
this in step 7. It will always be something to look out for during all your runs.

Otherwise, let's inspect the other fields a little more closely.

**`outcome`** is `:ok`, `{:violation, detail}`, or `{:error, reason}`. We expect
`:ok`. If it's anything else, go back and check your code. At this point we
should have a fully functional and safe ABD register.

**`ops`** should be 20. If it's lower the run ended early, which indicates a bug.

**`clock_ms`** is 0, because our system has no timers at all. Nothing ever
armed one, so the virtual clock never had a reason to move. Later, we'll add
in virtual time via `eta_time`.

**`modules_loaded`** must be empty, and **`sched.adopted_late`** and
**`sched.timeouts`** must be 0. These are the properties that `audit/1` looks for.
`:ok` is what we want here.

`adopted_late` counts processes that ran before the
scheduler owned them, and every one of them is a piece of the interleaving
decided by wall clock rather than by the seed (nondeterminism). A nonzero count
here means the seed won't reproduce.

### Make it a permanent test

Create `dst/abd_test.exs`:

```elixir
defmodule AbdTest do
  use ExUnit.Case, async: false

  @opts %{max_ops: 20, max_steps: 20_000, preload: [:abd]}

  test "the register satisfies regularity" do
    for seed <- 1..40 do
      %{outcome: outcome, sched: sched} =
        :eta_run.run(Abd.Harness, Map.put(@opts, :seed, seed))

      assert outcome == :ok, "seed #{seed}: #{inspect(outcome)}"
      assert sched.adopted_late == 0, "seed #{seed} adopted #{sched.adopted_late} late"
    end
  end
end
```

```bash
mix dst
```

RESULT: green.

Reminder: `mix dst` the custom entry point we defined above.

is the entry point we wired up in step 2. It compiles the `dst` env and runs
`dst/`; plain `mix test` compiles without `eta` and runs `test/`,
so the suite that exercises the shipped modules and the suite that simulates
them never share a build or a VM.

`async: false` is required. `eta_time` keeps its state in named ETS tables,
so exactly one virtual clock exists per node, and 2 simulations running
concurrently will corrupt each other. Every test that drives `eta_run` has to
be serial.

Asserting on `adopted_late` in the same loop is a habit worth forming. It costs
one line and it turns a silent loss of determinism into a failing test.

## Step 7: Confirm that a seed is reliable

The entire goal of this endeavor is to define a single RNG seed that can drive
our system the same way every time. If we don't get that, then we've failed,
so it's worth spending some time to confirm.

There is one failure mode in particular that we should call out: the `code_server`.

Start a **fresh** `iex` shell and make this the first thing you run. The first run in a
new VM is a special case and we want it in the sample.

This experiment will group traces that match each other. Notice that we're giving the
same seed on each of 5 runs. We hope to end up with identical traces each time.
Notice also that `preload` is gone.

```elixir
traces = for _ <- 1..5, do: :eta_run.run(Abd.Harness, %{seed: 1, max_ops: 20, max_steps: 20_000}).trace

length(Enum.uniq(traces))

traces
|> Enum.with_index(1)
|> Enum.group_by(fn {t, _i} -> t end, fn {_t, i} -> i end)
|> Map.values()
```

RESULT: `2` and `[[2, 3, 4, 5], [1]]`.

If this is the first thing you run in an `iex` shell, you will see that there are 2 unique traces,
instead of 1.

The grouping shows us that run #1 is the odd-man-out. Runs #2-#5 all match each other. This is
the clue - something is different about that first run on the VM. Hint: it's the `code_server`.

Here are some potential outputs and what they might mean.

| Grouping | Meaning |
|---|---|
| `[[1, 2, 3, 4, 5]]` | Clean. |
| `[[1], [2, 3, 4, 5]]` | The **first run** is special. Warm-up or first-touch state. Usually means something is lazily-loaded. |
| `[[1, 3], [2], [4, 5]]` | A coin flip on every run. A live leak in the system. Something to debug. |

### Diagnosing the `code_server` problem

Modules are loaded lazily, by a single `code_server` process on the node. `eta_sched`
has scheduled a process to run. That process reaches a module the system hasn't loaded yet,
and sends a message to the `code_server` process, which isn't tracked by `eta_sched`.
Our process waits on a reply, which `eta_sched` picks up as a yield, and an opportunity
for something else to be scheduled. On future runs, this specific yield doesn't exist,
so we end up with a different trace.

**`modules_loaded` tell you when this happens.** Start a *fresh* `iex` again.

```bash
MIX_ENV=dst iex -S mix
```

```elixir
:eta_run.run(Abd.Harness, %{seed: 1, max_ops: 20, max_steps: 20_000}).modules_loaded
```

RESULT: `[Abd.Client]`.

This should show you the modules that were loaded during the run. This is an
indicator of nondeterminism, not because the system is nondeterministic, but because
it changes `eta_sched`'s scheduling choices.

### The fix

Put the `preload` option back (which is what step 6 and our test file already do):

```elixir
opts = %{seed: 1, max_ops: 20, max_steps: 20_000, preload: [:abd]}
```

`preload` loads every module of the named applications before the run starts. It
also always loads the modules of `kernel`, `stdlib` and `eta`. If your code has
other modules, you will have to add them here.

**Prewarming is not good enough** A prewarming run will only execute a subset of
codepaths. Some other seed may enter a path with a new module call. Only you know
the full set of modules that's relevant to preload.

Now go back to the 5-trace grouping at the top of this step and run it again, on
yet another fresh VM.

RESULT: `1` and `[[1, 2, 3, 4, 5]]`.

### Add this assertion to our tests

Add to `dst/abd_test.exs`:

```elixir
test "a seed names an execution" do
  for seed <- [1, 7, 13] do
    traces =
      for _ <- 1..5 do
        :eta_run.run(Abd.Harness, Map.put(@opts, :seed, seed)).trace
      end

    assert length(Enum.uniq(traces)) == 1, "seed #{seed} produced divergent traces"
  end
end
```

Provide enough input seeds to have a high likelihood of covering all codepaths. This
test will start failing if you add code that calls a new module that is not preloaded.

## Step 8: fault injection

Before we purposefully introduce a bug, the workload needs to be able to express the
failure that makes the bug visible.

For example, your network can experience a failure
that causes one of the ABD writers to crash. Right now our system can't
express this failure mode, because the network is always reliable. Forcing the matter
is called fault injection. Defining the system faults is mostly your responsibility. `eta` gives
you the entrypoint for making those faults deterministic. We also provide `eta_net`,
which can help to inject message-passing faults between simulated nodes. For our
exercise, we'll build the fault injection utility ourselves.

### What our reliable network looks like in code

A client sends to all 3 replicas inside a **single scheduler step**:

```elixir
for pid <- replicas, do: Abd.Replica.write(pid, ref, self(), ts, val)
```

All replicas will always get every write. Perfectly reliable network, and not realistic!

### The crashed writer

Fault injection is itself a deep topic. For this walkthrough, we'll model it as a
new operation on the client.

Add to `lib/abd/client.ex`:

```elixir
  # A writer that died partway through its write phase, having reached only
  # some of the replicas. It collects no acks and never completes, which is
  # what a crashed writer leaves behind: a value durable at fewer replicas
  # than a quorum. Nothing in the protocol will clean this up.
  def partial_write(replicas, writer_id, value, targets) do
    {{seq, _}, _} = query_phase(replicas)
    ts = {seq + 1, writer_id}
    ref = make_ref()
    for i <- targets, do: Abd.Replica.write(Enum.at(replicas, i - 1), ref, self(), ts, value)
    ts
  end
```

In `dst/abd_harness.ex`, `generate/2` becomes:

```elixir
  @impl true
  def generate(%{next_op: n, replicas: replicas}, rand0) do
    {roll, rand1} = :rand.uniform_s(rand0)

    cond do
      roll < 0.15 ->
        {target, rand2} = :rand.uniform_s(length(replicas), rand1)
        {{:partial_write, n, {:v, n}, [target]}, rand2}

      roll < 0.40 ->
        {{:write, n, {:v, n}}, rand1}

      true ->
        {{:read, n}, rand1}
    end
  end
```

`op_number/1` gains a clause:

```elixir
  defp op_number({:partial_write, n, _value, _targets}), do: n
```

and `run_op/3` gains one:

```elixir
  defp run_op({:partial_write, n, value, targets}, tab, replicas) do
    start = :eta_log.log(:started)
    ts = Abd.Client.partial_write(replicas, n, value, targets)
    :ets.insert(tab, {{:partial_write, n}, start, :eta_log.log({:finished, ts}), ts, value})
  end
```

Put it alongside the `write` and `read` clauses you already have. The row it
writes is only for the record: `check/1` matches on `{{:read, _}, ...}` and never
looks at it.

The target replica is selected in `generate/2`, using the seed, and carried
in the operation, so that it is part of the recorded trace.

### All tests are still green

RESULT: still green over 40 seeds.

Even with network faults, a properly implemented ABD register still works.
That's the power of correct distributed systems, and not a function of
`eta`. We've increased our confidence that we've properly implemented the
ABD Quorum Register. Next, we'll introduce a bug on purpose and discover
it via `eta`.

## Step 9: delete the write-back

Remember that odd-looking write on the read path earlier? Let's pretend someone came
along and deleted that, thinking it was superfluous. You could just delete the line
of code, but for demo purposes, we'll make the bug a configurable property of our
app.

Let's introduce `mode` to define the buggy behavior. We'll use some inline comments
to guide your eye to the critical changes. In `lib/abd/client.ex`:

```elixir
  def read(replicas) do
    read(replicas, :correct)
  end

  def read(replicas, mode) do
    {ts, val} = query_phase(replicas)

    # `mode: :no_writeback` introduces a bug
    case mode do
      :correct -> :ok = write_phase(replicas, ts, val)
      :no_writeback -> :ok
    end

    {ts, val}
  end
```

The rest of the changes are to thread `mode` from `config` down to the call.
Three edits in `dst/abd_harness.ex`.

`init/2`'s returned map gains a `mode` key:

```elixir
    # <- store the mode
    {:ok,
     %{
       tab: tab,
       replicas: replicas,
       clients: [],
       next_op: 1,
       mode: Map.get(config, :mode, :correct)
     }}
```

`execute/2` pattern-matches it and plumbs it into `run_op`.

```elixir
  @impl true
  def execute(op, %{tab: tab, replicas: replicas, clients: clients, mode: mode} = sut) do
    n = op_number(op)

    # mode passed into run_op
    client = :eta_run.spawn_op(fn -> run_op(op, tab, replicas, mode) end)

    %{sut | clients: [client | clients], next_op: n + 1}
  end
```

All three `run_op` clauses gain a fourth argument; only the read clause uses it:

```elixir
  defp run_op({:write, n, value}, tab, replicas, _mode) do
    start = :eta_log.log(:started)
    ts = Abd.Client.write(replicas, n, value)
    :ets.insert(tab, {{:write, n}, start, :eta_log.log({:finished, ts}), ts, value})
  end

  defp run_op({:partial_write, n, value, targets}, tab, replicas, _mode) do
    start = :eta_log.log(:started)
    ts = Abd.Client.partial_write(replicas, n, value, targets)
    :ets.insert(tab, {{:partial_write, n}, start, :eta_log.log({:finished, ts}), ts, value})
  end

  # mode passed to the client
  defp run_op({:read, n}, tab, replicas, mode) do
    start = :eta_log.log(:started)
    {ts, val} = Abd.Client.read(replicas, mode)
    :ets.insert(tab, {{:read, n}, start, :eta_log.log({:finished, ts}), ts, val})
  end
```

Start a new `iex`, and let's conduct a search:

```elixir
opts = %{max_ops: 20, max_steps: 20_000, preload: [:abd], config: %{mode: :no_writeback}}

{micros, results} =
  :timer.tc(fn ->
    for seed <- 1..200 do
      {seed, :eta_run.run(Abd.Harness, Map.put(opts, :seed, seed)).outcome}
    end
  end)
```

RESULT: **200 seeds in ~1.1 sec**, **21 of 200 fail.** The first failure
is **seed 6**, which means it only took about 30 msec to find the bug.

A 10% hit rate: It's frequent enough that the search feels instant,
and rare enough that it would be annoying to pinpoint by hand. That's why
we think DST is useful.

The violation:

```elixir
{:violation, %{
  property: :no_new_old_inversion,
  detail: "a later read reported an older value",
  earlier: {29, 39, {1, 1}},
  later: {43, 48, {0, 0}}
}}
```

Those tuples are `{start, finish, timestamp}`. `start` and `finish` are `eta_log`
sequence numbers - they point back to items of the log to aid in debugging, which
we'll learn to render in step 11. The timestamps show the ordering violation: the
read that finished first reported `{1, 1}`, and the read that started after it
reported the older `{0, 0}`.

## Step 10: We have the trace of the bug, now let's print it out

The trace can potentially be very long. One advantage of having a replayable
system is that we can conduct a search to find the shortest possible trace
that reproduces the same violation. That's what `eta_shrink` is for.

(Note: global minimization is not guaranteed)

```elixir
opts6 = Map.put(opts, :seed, 6)
result = :eta_run.run(Abd.Harness, opts6)
shrunk = :eta_shrink.shrink(Abd.Harness, result.trace, opts6)
:eta_run.summary(shrunk)
```

**Use the same options.** `opts6` has `config: %{mode: :no_writeback}`,
and the shrinker starts a fresh system for every candidate.

RESULT: `original: 35, shrunk: 15, tests: 302, verified: true`, in 385 ms.

`verified: true` tells you that the search was successful. During the search, a
candidate is only a recipe, replayed in lenient mode where some steps get skipped.
`verified: true` means `eta_shrink` took what that run actually
executed and replayed it again strictly, and it still failed. `false` means the
search found something smaller that doesn't reproduce, and you get the original
back.

## Step 11: make the failure readable

Here is the shrunk trace (`IO.inspect(shrunk.trace, charlists: :as_lists)` —
the third element some entries carry is the ids of the processes they created):

```elixir
[
  {:op, {:partial_write, 1, {:v, 1}, [2]}, [3]},
  {:step, 3},
  {:step, 1},
  {:op, {:read, 6}, [8]},
  {:step, 2},
  {:step, 3},
  {:step, 8},
  {:step, 1},
  {:op, {:read, 7}, [9]},
  {:step, 2},
  {:step, 8},
  {:step, 9},
  {:step, 2},
  {:step, 0},
  {:step, 9}
]
```

If that means nothing to you, that's the correct reaction.

Remember that we're still working with replayable `eta_sched` actions. Even in
this minimized state, the shrunk trace is an artifact of the `eta` library,
and it tells you little about the specifics of the ABD Register. Let's bridge
that gap.

### Using `eta_log`

`eta_log` uses a global table. Its API is modeled after `fprof` and other built-in
Erlang analysis tools. Don't execute these yet; we need to instrument the ABD
code first.

```elixir
:eta_run.run(Abd.Harness, opts)   # 1. collect  (automatic)
:eta_log.profile()                # 2. correlate
:eta_log.analyze()                # 3. present
```

### What you add to your system

We'll use `Abd.Eta.label/1` and `Abd.Eta.log/1` in our system code. Both of these
macros expand to no-ops when the build is not `:dst`. In production code, this
instrumentation simply does not exist.

**`lib/abd/replica.ex`.** Label the process in `init/1`:

```elixir
  def init(index) do
    # <-
    :ok = Abd.Eta.label({:replica, index})
    {:ok, %__MODULE__{index: index}}
  end
```

and log what it does (with `Abd.Eta.log/1`), in the `handle_cast` clauses:

```elixir
  def handle_cast({:read, ref, from}, st) do
    # <-
    _ = Abd.Eta.log({:answered_read, st.ts})
    send(from, {:read_ack, ref, st.index, st.ts, st.val})
    {:noreply, st}
  end

  def handle_cast({:write, ref, from, ts, val}, st) do
    st = store(ts, val, st)
    # <-
    _ = Abd.Eta.log({:applied_write, ts, st.ts == ts})
    send(from, {:write_ack, ref, st.index})
    {:noreply, st}
  end
```

The boolean on `applied_write` is whether the write actually took. A replica
that already holds a higher timestamp ignores it, and knowing which is which
will help us troubleshoot.

**`lib/abd/client.ex`**, instrument where the protocol decides something, still
using `Abd.Eta.log/1`. In `query_phase/1`, surrounding the collection:

```elixir
  defp query_phase(replicas) do
    ref = make_ref()
    # <-
    _ = Abd.Eta.log(:query_sent)
    for pid <- replicas, do: Abd.Replica.read(pid, ref, self())
    best = collect_reads(ref, @quorum, {{0, 0}, nil})
    # <-
    _ = Abd.Eta.log({:quorum_max, elem(best, 0)})
    best
  end
```

in `write_phase/3`, before the sends:

```elixir
    _ = Abd.Eta.log({:write_sent, ts, length(replicas)})
```

in `partial_write/4`, after the sends:

```elixir
    _ = Abd.Eta.log({:crashed_after_writing, ts, targets})
```

and in `read/2`'s `:no_writeback` branch, which is the one that names the bug:

```elixir
      :no_writeback -> _ = Abd.Eta.log({:returned_without_writeback, ts})
```

For instrumentation to be useful, the developer must have some knowledge or expertise about
the distributed system being implemented, ABD in this case. `eta` can't do that for you.
Choosing the right instrumentation is important because it means the trace will be readable.
Luckily, since traces are replayable, the instrumentation can be decided upon post-fact.
You will be able to hone your instrumentation over time using real bugs to define the narrative.
And you will be the expert of the system that you're writing.

### What you add to your harness

`dst/abd_harness.ex` never ships, and only ever compiles in the `dst` env, so
it can go either way: `use Abd.Eta` and use the macros, or call
`eta_log` directly. Here we choose to call it directly.

First, one function that decides what every client is called. Each one calls it
on itself, which we wire up in a moment:

```elixir
  defp label_for({:write, n, _value}), do: {:writer, n}
  defp label_for({:partial_write, n, _value, _targets}), do: {:crasher, n}
  defp label_for({:read, n}), do: {:reader, n}
```

There is an optional `labels/1` callback on `eta_harness`, but we don't need it here
because each process names itself.

### Wire up the label

Your harness has been stamping operations from `:eta_log.log/1` since step 5, so
the clock is covered. What's missing is the name. Replace `run_op` with the following:

```elixir
  defp run_op(op, tab, replicas, mode) do
    :ok = :eta_log.label(label_for(op))
    start = :eta_log.log(:started)
    run_op(op, tab, replicas, mode, start)
  end

  defp run_op({:write, n, value}, tab, replicas, _mode, start) do
    ts = Abd.Client.write(replicas, n, value)
    :ets.insert(tab, {{:write, n}, start, :eta_log.log({:finished, ts}), ts, value})
  end

  defp run_op({:partial_write, n, value, targets}, tab, replicas, _mode, start) do
    ts = Abd.Client.partial_write(replicas, n, value, targets)
    :ets.insert(tab, {{:partial_write, n}, start, :eta_log.log({:finished, ts}), ts, value})
  end

  defp run_op({:read, n}, tab, replicas, mode, start) do
    {ts, val} = Abd.Client.read(replicas, mode)
    :ets.insert(tab, {{:read, n}, start, :eta_log.log({:finished, ts}), ts, val})
  end
```

It can be helpful to confirm that the log does not influence trace replayability:

```elixir
a = :eta_run.run(Abd.Harness, Map.put(opts, :seed, 6)).trace
b = :eta_run.run(Abd.Harness, Map.put(opts, :seed, 6) |> Map.put(:log, false)).trace
a == b
```

`log: false` suppresses the *events*, but still allows the sequence numbers.

**Observability that changes the trace is not worth it**, because every
failure you then investigate is a different failure from the one you set out to
investigate.

### Read the failure

Three files have changed since step 10, so start a **fresh shell** and rebuild
`shrunk` from scratch.

```bash
MIX_ENV=dst iex -S mix
```

```elixir
opts = %{max_ops: 20, max_steps: 20_000, preload: [:abd], config: %{mode: :no_writeback}}
opts6 = Map.put(opts, :seed, 6)

result = :eta_run.run(Abd.Harness, opts6)
shrunk = :eta_shrink.shrink(Abd.Harness, result.trace, opts6)
:eta_run.summary(shrunk)
```

Use whichever seed your own step 9 sweep turned up; 6 was ours.

**Don't skip this: replay the shrunk trace** Collection resets at the
start of every run, and `shrink/3` just did several hundred of them. Make
sure the system can collect the log events you care about.

```elixir
:eta_run.replay(Abd.Harness, shrunk.trace, opts6)

{:violation, %{later: {_start, finish, _ts}}} = shrunk.outcome
:eta_log.analyze(%{until: finish})
```

RESULT:

```
    1  $eta           {op,{partial_write,1,{v,1},[2]}}
    2  crasher-1      {step,3}
    3  crasher-1      started
    4  crasher-1      query_sent
    5  replica-2      {step,1}
    6  replica-2      {answered_read,{0,0}}
    7  $eta           {op,{read,6}}
    8  replica-3      {step,2}
    9  replica-3      {answered_read,{0,0}}
   10  crasher-1      {step,3}
   11  crasher-1      {quorum_max,{0,0}}
   12  crasher-1      {crashed_after_writing,{1,1},[2]}
   13  crasher-1      {finished,{1,1}}
   14  reader-6       {step,8}
   15  reader-6       started
   16  reader-6       query_sent
   17  replica-2      {step,1}
   18  replica-2      {applied_write,{1,1},true}
   19  replica-2      {answered_read,{1,1}}
   20  $eta           {op,{read,7}}
   21  replica-3      {step,2}
   22  replica-3      {answered_read,{0,0}}
   23  reader-6       {step,8}
   24  reader-6       {quorum_max,{1,1}}
   25  reader-6       {returned_without_writeback,{1,1}}
   26  reader-6       {finished,{1,1}}
   27  reader-7       {step,9}
   28  reader-7       started
   29  reader-7       query_sent
   30  replica-3      {step,2}
   31  replica-3      {answered_read,{0,0}}
   32  replica-1      {step,0}
   33  replica-1      {answered_read,{0,0}}
   34  replica-1      {answered_read,{0,0}}
   35  replica-1      {answered_read,{0,0}}
   36  reader-7       {step,9}
   37  reader-7       {quorum_max,{0,0}}
   38  reader-7       {returned_without_writeback,{0,0}}
   39  reader-7       {finished,{0,0}}
```

(The events are your Elixir terms rendered by an Erlang formatter, which is why
`{:v, 1}` prints as `{v,1}`.)

### How to read 39 lines

Don't! The violation tells you which ones matter.

```
earlier: {15, 26, {1, 1}}
later:   {28, 39, {0, 0}}
```

Those are **line numbers**. Read 15 to 26 for how the earlier read saw `{1,1}`,
28 to 39 for how the later one missed it, and the `crashed_after_writing` line
above them for why there was anything to miss. Everything else is context you
can skip until you need it.

Still, to make sense of this rendering, you will need to have knowledge and
understanding of the ABD system itself. Don't be alarmed if the trace remains
confusing even at this stage. When you write your system, you will be the expert,
and as the expert you will be able to parse this information.

`:eta_log.analyze(%{until: finish, driver: false})` drops the `$eta` lines
entirely if you want only what the system did.

### What it says

Line 12 is a writer that reached exactly 1 replica and died. Line 25 is a reader
that saw that value and returned it without making it durable. Line 38 is the
next reader, which didn't see it at all. Line 26 precedes line 28, so those 2
reads are sequential, and the register went backwards.

The counterintuitive part, and the reason this bug survives code review:
reader-6's quorum was `{replica-2, replica-3}` and reader-7's was
`{replica-3, replica-1}`. **They do intersect, at replica-3.** Quorum intersection worked exactly as advertised. But it didn't help, because `{1,1}` only ever existed at 1 replica.

Reader-6 got lucky enough to observe a value that was never durable, and by
returning it, published something the system could no longer produce. **The
write-back is the action that converts "I observed this" into "this is durable at a quorum"
before the value escapes to a caller.** With it, reader-6 writes `{1,1}` to 2 replicas
before returning, and reader-7's quorum of 2 cannot miss it.

One other item to note. There are entries in this trace that are a result of
old messages in the process mailboxes that eventually get picked up. They
exist because we were lazy about maintaining a clean mailbox in the implementation.

## (Optional) Step 12: confirm the bug and the patch in formal assertions

Optional step. This illustrates how the same seed can experience different codepaths
using different configuration options. Because we made the buggy behavior a configurable
mode, we can test the same seed under two different codepaths. One asserts the violation,
and one asserts system health.

```elixir
  @buggy %{max_ops: 20, max_steps: 20_000, preload: [:abd], config: %{mode: :no_writeback}}

  test "seed 6 reproduces the inversion without the write-back" do
    assert {:violation, %{property: :no_new_old_inversion}} =
             :eta_run.run(Abd.Harness, Map.put(@buggy, :seed, 6)).outcome
  end

  test "the write-back fixes seed 6" do
    correct = Map.put(@buggy, :config, %{mode: :correct})
    assert :ok = :eta_run.run(Abd.Harness, Map.put(correct, :seed, 6)).outcome
  end
```


## Step 13: a virtual clock

Every run so far has reported `clock_ms: 0`. The system has no timers, so
`eta_time` has never done anything and the transform we engaged on `Abd.Replica`
back at step 3 has never rewritten a timer. However, time is a very typical
component of distributed systems, and usually shows up as timeouts.

`eta_transform` rewrites `receive ... after` language constructs and
`Process.send_after/3`. Both become deterministic with `eta_time`'s virtual clock.

### Another fault injection - a replica that dies

Here's another fault injection site. This time, we'll allow the replica to become
busy, preventing timely responses. This fault simulates high network latency.

In `lib/abd/replica.ex`, add a `paused` field to the struct and a `pause/2` cast
next to `read/3` and `write/5`:

```elixir
  defstruct index: nil, ts: {0, 0}, val: nil, paused: false
```

```elixir
  def pause(pid, ms) do
    GenServer.cast(pid, {:pause, ms})
  end
```

Then 3 clauses **above** the existing `handle_cast`s:

```elixir
  def handle_cast({:pause, ms}, st) do
    _ = Abd.Eta.log({:paused, ms})
    _ = Process.send_after(self(), :resume, ms)
    {:noreply, %{st | paused: true}}
  end

  # An unreachable replica. The request arrives and is simply never answered,
  # which is what a caller sees from a node that has gone away.
  def handle_cast({:read, _ref, _from}, %{paused: true} = st) do
    {:noreply, st}
  end

  def handle_cast({:write, _ref, _from, _ts, _val}, %{paused: true} = st) do
    {:noreply, st}
  end
```

and a `handle_info` clause to bring it back:

```elixir
  def handle_info(:resume, st) do
    _ = Abd.Eta.log(:resumed)
    {:noreply, %{st | paused: false}}
  end
```

That `Process.send_after/3` is the first line in the project the transform
actually rewrites. If it feels nondeterministic to you, you're right, it should!
The reason it's ok is that the beam rewrite replaces things at compile time
(in the `:dst` build). That rewrite replaces the wall clock with a virtual one,
and removes the nondeterminism.

### Defining a timeout in the client

Add near the top of `lib/abd/client.ex`:

```elixir
  @phase_timeout 5000
```

and give both collection loops an `after` clause. The read side:

```elixir
  defp collect_reads(_ref, 0, best), do: best

  defp collect_reads(ref, n, best) do
    receive do
      {:read_ack, ^ref, _index, ts, val} ->
        collect_reads(ref, n - 1, best(best, {ts, val}))
    after
      @phase_timeout ->
        _ = Abd.Eta.log(:gave_up_waiting_for_read_quorum)
        throw({:abd_timeout, ref})
    end
  end
```

and `collect_writes/2`:

```elixir
  defp collect_writes(_ref, 0), do: :ok

  defp collect_writes(ref, n) do
    receive do
      {:write_ack, ^ref, _index} -> collect_writes(ref, n - 1)
    after
      @phase_timeout ->
        _ = Abd.Eta.log(:gave_up_waiting_for_write_quorum)
        throw({:abd_timeout, ref})
    end
  end
```

Here we're exercising `eta_transform`'s rewrite of the `receive ... after`
construct instead of a `Process.send_after/3` call.

**The timeout is a client failure, so we throw.** A client
that returns a value backed by 1 replica instead of 2 has broken the quorum
property, and you'd have introduced a second bug while demonstrating the first.
That's why this throws rather than returning the partial result.

### The harness injects the new faults

3 changes in `dst/abd_harness.ex`. We'll add a new pause operation to
`generate/2` and the other thresholds are increased to make room. Note: changing
the generated workload like this means that a given seed, like the one from earlier,
is unlikely to replay in the same way, because different operations will be selected
from the RNG.

```elixir
  @impl true
  def generate(%{next_op: n, replicas: replicas}, rand0) do
    {roll, rand1} = :rand.uniform_s(rand0)

    cond do
      roll < 0.04 ->
        {target, rand2} = :rand.uniform_s(length(replicas), rand1)
        {{:pause, n, target, 10_000}, rand2}

      roll < 0.25 ->
        {target, rand2} = :rand.uniform_s(length(replicas), rand1)
        {{:partial_write, n, {:v, n}, [target]}, rand2}

      roll < 0.45 ->
        {{:write, n, {:v, n}}, rand1}

      true ->
        {{:read, n}, rand1}
    end
  end
```

We've tuned our pause fault-injection to a 4% occurrence rate. Tuning fault injections
to avoid crippling the system entirely will be a unique exercise for each system.

`op_number/1` and `label_for/1` each gain a clause:

```elixir
  defp op_number({:pause, n, _index, _ms}), do: n
```

```elixir
  defp label_for({:pause, n, _index, _ms}), do: {:pauser, n}
```

And `run_op/5` gains a clause for the new operation:

```elixir
  defp run_op({:pause, _n, index, ms}, _tab, replicas, _mode, _start) do
    _ = :eta_log.log({:pausing, index, ms})
    Abd.Replica.pause(Enum.at(replicas, index - 1), ms)
  end
```

### Timeout failures need to be detected

The other 3 `run_op/5` clauses must catch the timeout and record the failure:

```elixir
  defp run_op({:write, n, value}, tab, replicas, _mode, start) do
    try do
      Abd.Client.write(replicas, n, value)
    catch
      {:abd_timeout, _} ->
        :ets.insert(tab, {{:gave_up, :write, n}, start, :eta_log.log(:gave_up)})
    else
      ts -> :ets.insert(tab, {{:write, n}, start, :eta_log.log({:finished, ts}), ts, value})
    end
  end

  defp run_op({:partial_write, n, value, targets}, tab, replicas, _mode, start) do
    try do
      Abd.Client.partial_write(replicas, n, value, targets)
    catch
      {:abd_timeout, _} ->
        :ets.insert(tab, {{:gave_up, :partial_write, n}, start, :eta_log.log(:gave_up)})
    else
      ts ->
        :ets.insert(tab, {{:partial_write, n}, start, :eta_log.log({:finished, ts}), ts, value})
    end
  end

  defp run_op({:read, n}, tab, replicas, mode, start) do
    try do
      Abd.Client.read(replicas, mode)
    catch
      {:abd_timeout, _} ->
        :ets.insert(tab, {{:gave_up, :read, n}, start, :eta_log.log(:gave_up)})
    else
      {ts, val} -> :ets.insert(tab, {{:read, n}, start, :eta_log.log({:finished, ts}), ts, val})
    end
  end
```

`check/1` does not need a change, because the invariant code uses a pattern match on
the read tuples.

### Run it

```elixir
opts = %{max_ops: 20, max_steps: 20_000, preload: [:abd], config: %{mode: :correct}}

for seed <- 1..40 do
  r = :eta_run.run(Abd.Harness, Map.put(opts, :seed, seed))
  {seed, r.outcome, r.clock_ms}
end
```

RESULT: every outcome `:ok`. `clock_ms` reads **10000 on 23 of the 40 seeds and
0 on the other 17.**

Outcomes should all be `:ok`. Pausing doesn't break the cluster, it only makes things
run more slowly (in production) and causes some clients to give up.

Notice that `clock_ms` is nonzero now; the virtual clock is engaged. Nothing in the
system actually had to wait around for 10 seconds. We simulated it in a fraction of
the time. The magnitude of the speed up can vary, but it's common for DST systems
to be able to test days worth of wall clock in a matter of hours of real time.

Feel free to run the `:eta_log` functions in your shell to inspect some traces.

## Step 14: pin the trace, not the seed

After adding the pause operation, `mix dst` went red. Seed 6 no longer does what
it used to do. This is expected; we changed how operations are generated.

```
1) test seed 6 reproduces the inversion without the write-back (AbdTest)
   match (=) failed
   left:  {:violation, %{property: :no_new_old_inversion}}
   right: :ok
```

**When you pin a test to a seed, it's coupled to the generated workload.** Changing
the generator can cause pinned seeds to silently stop testing what they were pinned
for. Ours failed loudly because it asserts on a violation. A test asserting
`:ok` would likely be just as pointless.

Instead of pinning the seed, we can pin the trace. `:eta_run.replay/3` never calls `generate/2`, it
walks the entries it's given, so a saved trace survives generator changes
completely.

Capture it with `save_fixture/4`. For our `abd`, seed 53 now fails, but if you chose different
parameters, your first failing seed might be different.

```elixir
buggy = %{max_ops: 20, max_steps: 20_000, preload: [:abd], config: %{mode: :no_writeback}}
opts53 = Map.put(buggy, :seed, 53)

r = :eta_run.run(Abd.Harness, opts53)
s = :eta_shrink.shrink(Abd.Harness, r.trace, opts53)
{s.original, s.shrunk, s.verified}

File.mkdir_p!("dst/fixtures")
:eta_run.save_fixture("dst/fixtures/inversion.eta", Abd.Harness, s.trace, opts53)
```

RESULT: `{39, 17, true}`, then `{:ok, {:violation, %{property: :no_new_old_inversion}}}`.

Now we can load that fixture into a test.

```elixir
  test "the recorded inversion still reproduces" do
    assert %{outcome: {:violation, %{property: :no_new_old_inversion}}} =
             :eta_run.replay_fixture("dst/fixtures/inversion.eta")
  end
```

The 2 seed-pinned tests from step 12 are still red until you re-pin them to 53,
which is the coupling this step is about.

 Whether or not you actually want to do this in your project is up to you. There
are pros and cons to the approach. It does still break if the *shape* of an
operation changes, or if `processes/1` starts registering processes in a
different order. Those are changes to the contract rather than to the workload.

## Step 15: How to incorporate system state into your invariant

`eta_log` records what your system *did*. `eta_observe` is for tracking current
system state. It requires special configuration of the transform because
state is typically accessible via message passing, and all processes are suspended,
which halts message passing during the `check/1` phase.

### Tweak the transform with an `@eta_observe` attribute

One attribute on `lib/abd/replica.ex`:

```elixir
  use Abd.Eta
  use GenServer

  @eta_observe :all
```

For every `GenServer` callback, the transform will publish the returned state
to a shared memory location, observable by the harness. (In the Erlang
walkthrough this is `-eta_observe({st, [ts, val]})`, naming record fields; an
Elixir state is a struct, and `:all` publishes the whole thing.)

### Read it back out

In `dst/abd_harness.ex`, take the replicas in `check/1` and attach
their state to a violation:

```elixir
  @impl true
  def check(%{tab: tab, replicas: replicas}) do
    reads = for {{:read, _}, s, f, ts, _} <- :ets.tab2list(tab), do: {s, f, ts}

    case inversion(Enum.sort(reads)) do
      :ok -> :ok
      {:violation, detail} -> {:violation, Map.put(detail, :replicas, replica_states(replicas))}
    end
  end

  # What each replica holds, read straight out of its heap while it is suspended.
  defp replica_states(replicas) do
    for {pid, i} <- Enum.with_index(replicas, 1), do: {i, :eta_observe.read(pid)}
  end
```

### Run it

```elixir
opts = %{max_ops: 20, max_steps: 20_000, preload: [:abd], config: %{mode: :no_writeback}}
:eta_run.run(Abd.Harness, Map.put(opts, :seed, 53)).outcome
```

RESULT:

```elixir
{:violation,
 %{
   property: :no_new_old_inversion,
   detail: "a later read reported an older value",
   earlier: {18, 45, {1, 1}},
   later: {48, 93, {0, 0}},
   replicas: [
     {1, %Abd.Replica{index: 1, ts: {1, 1}, val: {:v, 1}, paused: false}},
     {2, %Abd.Replica{index: 2, ts: {0, 0}, val: nil, paused: false}},
     {3, %Abd.Replica{index: 3, ts: {0, 0}, val: nil, paused: false}}
   ]
 }}
```

**The bug is now directly visible.** `{1,1}` exists at exactly one replica, not
a quorum. We have a lot of information about the defect before inspecting
the trace, shrink, or log.

### Two ways to observe

So how do we pick the right one?

**If the state already lives somewhere readable, read it there.** Our reads and
writes go into ets because the invariant needs a history, `eta_observe` is not
a history.

**If the state exists only inside a process, publish it.** A replica's
`{ts, val}` is a current internal value, so publish it out to the harness with
`eta_observe`.

Finally, with respect to `eta_log`: the log is the narrative, this is a snapshot.
Use both to debug.

## Conclusion

That covers all the high level concepts of `eta`. The main takeaway is that DST
is an investment. Doing it right requires time and attention, but if your
problem space is the right fit, it will probably prevent some headaches and
lead to a more reliable software system.
