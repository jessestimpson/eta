defmodule DstElixirSutTest do
  @moduledoc """
  End-to-end proof for Elixir support: idiomatic Elixir GenServers driven
  through `:eta_run.run/2` under the beam-rewriting mechanism.

  Where `DstElixirTest` pins the mechanism itself — what `Eta.Beam` rewrites
  and refuses — this suite is the payoff: two SUTs written as ordinary Elixir
  (`Process.send_after/3`, `send/2`, `spawn_link/1`, `Process.monitor/1`),
  transformed after compilation, and simulated with the same assertions the
  Erlang SUTs answer. A clean outcome says the rewrites compose; the
  determinism and trace-replay tests say the runs they produce are the real
  article, not merely code that loads.

  The SUTs and harnesses were first written against a macro facade
  (`Eta.send/2` for `send/2`, and so on) that asked every call site to opt
  in. This port keeps their behaviour and their harnesses while returning the
  call sites to the stdlib — the diff between the two versions of
  `EtaElixir.Worker` is the argument for the mechanism. With the
  `'Elixir.GenServer'` table entries in place, the SUTs are idiomatic all the
  way down: `EtaElixir.Counter` is a `use GenServer` module (covering the
  `-behaviour('Elixir.GenServer')` gate on the reply pass), and
  `EtaElixir.Worker` keeps `@behaviour :gen_server` so the raw declaration
  stays covered too.

  Fixtures compile at run time, the `DstAfterTest` freshness argument again:
  Mix does not track the transform as a dependency of what it rewrites, and a
  suite exercising yesterday's beams is not a regression suite.
  """
  use ExUnit.Case, async: false

  # The fixtures exist only after `setup_all` compiles them.
  @compile {:no_warn_undefined,
            [EtaElixir.Counter, EtaElixir.Harness, EtaElixir.Worker, EtaElixir.WorkerHarness]}

  @fixtures ~w(
    eta_elixir_counter.ex
    eta_elixir_harness.ex
    eta_elixir_worker.ex
    eta_elixir_worker_harness.ex
  )

  @modules [EtaElixir.Counter, EtaElixir.Harness, EtaElixir.Worker, EtaElixir.WorkerHarness]

  @run :eta_run
  @sut EtaElixir.Harness
  @worker_sut EtaElixir.WorkerHarness

  @opts %{max_ops: 20, max_steps: 5_000, preload: [:eta]}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "eta_elixir_sut_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    srcs = for f <- @fixtures, do: Path.join([__DIR__, "support", f])

    orig = Code.compiler_options()[:debug_info]

    try do
      Code.put_compiler_option(:debug_info, true)
      {:ok, _, _} = Kernel.ParallelCompiler.compile_to_path(srcs, dir, return_diagnostics: true)
    after
      Code.put_compiler_option(:debug_info, orig)
    end

    results = Map.new(Eta.Beam.transform_path(dir), fn {p, o} -> {Path.basename(p), o} end)

    # The SUTs opt in and the harnesses do not — the same division the
    # Erlang side keeps between systems under test and the driver.
    assert results["Elixir.EtaElixir.Counter.beam"] == :transformed
    assert results["Elixir.EtaElixir.Worker.beam"] == :transformed
    assert results["Elixir.EtaElixir.Harness.beam"] == :not_opted_in
    assert results["Elixir.EtaElixir.WorkerHarness.beam"] == :not_opted_in

    # Load what is on disk, rather than trusting whichever versions the
    # compiler and the transform's reload left in the VM.
    for mod <- @modules do
      file = Path.join(dir, "#{mod}.beam")
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, String.to_charlist(file), File.read!(file))
    end

    :ok
  end

  defp run(seed, extra \\ %{}) do
    @run.run(@sut, Map.merge(@opts, Map.merge(extra, %{seed: seed})))
  end

  defp run_worker(seed, extra \\ %{}) do
    @run.run(@worker_sut, Map.merge(@opts, Map.merge(extra, %{seed: seed})))
  end

  # -------------------------------------------------------------------------
  # Counter SUT — the basic rewritten surface
  # -------------------------------------------------------------------------

  describe "an Elixir GenServer under eta" do
    test "runs clean and exercises the rewrites" do
      result = run(1)

      assert result.outcome == :ok,
             "the Elixir SUT did not come out clean: #{inspect(result.outcome)}"

      assert result.ops == 20, "not every operation was injected"

      assert result.steps > 10,
             "suspiciously few steps — the rewrites may not have taken effect"

      assert result.clock_ms > 0,
             "the virtual clock never moved — send_after was not rewritten"

      assert :ok = @run.audit(result),
             "audit failed: #{inspect(@run.audit(result))}"
    end
  end

  describe "determinism" do
    test "one seed produces one full result" do
      for seed <- 1..6 do
        runs = for _ <- 1..3, do: run(seed)

        assert length(Enum.uniq(runs)) == 1,
               "seed #{seed} produced #{length(Enum.uniq(runs))} distinct results"
      end
    end

    test "a recorded trace replays to the same result" do
      original = run(3)

      replayed = @run.replay(@sut, original.trace, Map.merge(@opts, %{seed: 3}))

      assert replayed.outcome == original.outcome
      assert replayed.trace == original.trace
      assert replayed.skipped == 0
    end
  end

  # -------------------------------------------------------------------------
  # Worker SUT — the full rewritten surface
  # -------------------------------------------------------------------------

  describe "worker SUT: spawn_link, monitor, cancel_timer, monotonic_time, reply" do
    test "runs clean and exercises the full surface" do
      result = run_worker(1)

      assert result.outcome == :ok,
             "the worker SUT did not come out clean: #{inspect(result.outcome)}"

      assert result.ops == 20, "not every operation was injected"

      assert result.steps > 10,
             "suspiciously few steps — the rewrites may not have taken effect"

      assert result.clock_ms > 0,
             "the virtual clock never moved — send_after was not rewritten"

      assert :ok = @run.audit(result),
             "audit failed: #{inspect(@run.audit(result))}"
    end

    test "one seed produces one full result" do
      for seed <- 1..4 do
        runs = for _ <- 1..3, do: run_worker(seed)

        assert length(Enum.uniq(runs)) == 1,
               "seed #{seed} produced #{length(Enum.uniq(runs))} distinct results"
      end
    end

    test "a recorded trace replays to the same result" do
      original = run_worker(2)

      replayed = @run.replay(@worker_sut, original.trace, Map.merge(@opts, %{seed: 2}))

      assert replayed.outcome == original.outcome
      assert replayed.trace == original.trace
      assert replayed.skipped == 0
    end
  end

  # -------------------------------------------------------------------------
  # The generated wrappers, outside a run
  # -------------------------------------------------------------------------

  describe "the handle_call pass, inert outside a simulation" do
    # These drive the transformed Worker with no clock, scheduler or network
    # running — the same inertness `eta_time` and `eta_net` promise for
    # Erlang modules. The wrapping must not change behaviour when eta is idle.

    test "handle_call with guards still matches correctly" do
      # `handle_call(:health, ...)` has `when state.alive` and a fallback.
      # If the wrapping broke the guard, the wrong clause would match.
      {:ok, pid} = EtaElixir.Worker.start_link([])

      assert {:ok, _} = EtaElixir.Worker.health(pid)

      GenServer.stop(pid)
    end

    test "handle_call with {:stop, reason, reply, state} routes reply and stops" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # :stop returns {:stop, :normal, :ok, state}. The wrapper routes the
      # reply through eta_net:reply/2 and hands {:stop, :normal, state} on.
      assert :ok = EtaElixir.Worker.stop(pid)

      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    test "handle_call with an async reply from a spawned process works" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # :measure spawns a process that replies via :gen_server.reply/2 —
      # rewritten to eta_net:reply/2 — while handle_call returns {:noreply, _}.
      assert {:measured, _} = EtaElixir.Worker.measure(pid)

      GenServer.stop(pid)
    end

    test "handle_continue/2 state is published" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # start_link returns after init/1 but before handle_continue/2. A call
      # forces a message through, so handle_continue/2 has already run.
      {:ok, _} = EtaElixir.Worker.health(pid)

      observed = :eta_observe.read(pid)
      assert %{helper: helper, mon_ref: mon_ref} = observed
      assert is_pid(helper), "helper is not a pid: #{inspect(helper)}"
      assert is_reference(mon_ref), "mon_ref is not a reference: #{inspect(mon_ref)}"

      GenServer.stop(pid)
    end

    test "a named start goes through the shim's option translation" do
      # `GenServer.start_link(mod, arg, name: atom)` pops the name inside
      # Elixir's stdlib — the reason the starts rewrite to Eta.GenServer
      # rather than straight to eta_sched. A registered name proves the
      # translation ran.
      name = :"eta_elixir_named_#{System.unique_integer([:positive])}"
      {:ok, pid} = EtaElixir.Worker.start_named(name)

      assert Process.whereis(name) == pid
      assert {:ok, _} = EtaElixir.Worker.health(name)

      GenServer.stop(pid)
    end

    test "demonitor is exercised by :detach" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      assert :ok = EtaElixir.Worker.detach(pid)

      {:ok, _} = EtaElixir.Worker.health(pid)
      observed = :eta_observe.read(pid)
      assert %{mon_ref: nil} = observed

      GenServer.stop(pid)
    end
  end
end
