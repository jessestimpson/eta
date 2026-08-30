defmodule DstElixirStatemTest do
  @moduledoc """
  `gen_statem` support for Elixir modules — the coverage claim, tested.

  Elixir has no `gen_statem` wrapper, so an Elixir state machine already
  speaks in the qualified Erlang calls the rewrite tables match; the statem
  passes — gated starts, routed replies, virtualised state time-outs, the
  prepended delivery clause — should apply to Elixir-generated abstract
  format with no `'Elixir.*'` entries at all. "Should" is what this suite
  turns into evidence, on both of the fronts `EtaStateTimeoutTest` holds the
  Erlang side to:

  - **Directed**: with a virtual clock and no scheduler, the lease's expiry
    is a deadline in eta's wheel — waiting it out costs no real time, and a
    state change cancels it exactly as `gen_statem`'s rules say. Every firing
    test is also a test of clause *prepending*, because `EtaElixir.Lease` has
    no `info` clauses of its own to catch the delivery.
  - **Under simulation**: full runs through the harness, with the same
    determinism and trace-replay assertions the other SUTs answer. The
    interesting schedules race a `:release` against the expiry the clock
    jumps to.

  The SUT is written in `state_functions` mode deliberately: the transform
  finds those callbacks through the export table, and Elixir exports every
  `def` — the exact meeting point worth pinning.
  """
  use ExUnit.Case, async: false

  # The fixtures exist only after `setup_all` compiles them.
  @compile {:no_warn_undefined, EtaElixir.Lease}

  @fixtures ~w(eta_elixir_lease.ex eta_elixir_lease_harness.ex)
  @modules [EtaElixir.Lease, EtaElixir.LeaseHarness]

  @run :eta_run
  @time :eta_time
  @sut EtaElixir.LeaseHarness

  @opts %{max_ops: 20, max_steps: 5_000, preload: [:eta]}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "eta_elixir_statem_#{System.unique_integer([:positive])}")
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

    assert results["Elixir.EtaElixir.Lease.beam"] == :transformed
    assert results["Elixir.EtaElixir.LeaseHarness.beam"] == :not_opted_in

    for mod <- @modules do
      file = Path.join(dir, "#{mod}.beam")
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, String.to_charlist(file), File.read!(file))
    end

    :ok
  end

  setup do
    on_exit(fn -> @time.stop() end)
    :ok
  end

  defp run(seed, extra \\ %{}) do
    @run.run(@sut, Map.merge(@opts, Map.merge(extra, %{seed: seed})))
  end

  defp start_lease do
    {:ok, pid} = EtaElixir.Lease.start_link(self())

    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  # -------------------------------------------------------------------------
  # Directed — the state time-out is eta's
  # -------------------------------------------------------------------------

  describe "directed, with a virtual clock" do
    setup do
      :ok = @time.start(%{start_ms: 0})
      %{pid: start_lease()}
    end

    test "the lease expiry is a deadline in eta's wheel, and waiting is free", %{pid: pid} do
      assert {:granted, 1} = EtaElixir.Lease.acquire(pid)

      # The reply releases this test before the action list is read, so a
      # second call is the fence that puts the arming strictly behind us —
      # the cast-then-sync pattern from eta_state_timeout_sut, one call over.
      assert {:held, 1, 0} = EtaElixir.Lease.status(pid)
      assert @time.pending() == 1, "the deadline went to the VM's wheel, not eta's"

      {micros, _} = :timer.tc(fn -> @time.advance(100) end)

      assert_receive {:expired, 1}, 1000
      assert {:free, 1, 1} = EtaElixir.Lease.status(pid)
      assert micros < 1_000_000, "a virtual expiry took #{div(micros, 1_000)}ms"
    end

    test "a release cancels the deadline, as a state change must", %{pid: pid} do
      assert {:granted, 1} = EtaElixir.Lease.acquire(pid)
      :ok = EtaElixir.Lease.release(pid)

      assert {:free, 1, 0} = EtaElixir.Lease.status(pid)
      assert @time.pending() == 0, "the deadline outlived the state it belonged to"

      @time.advance(100)
      refute_received {:expired, _}
    end
  end

  describe "inert without a clock" do
    test "the state time-out stays gen_statem's own" do
      pid = start_lease()

      assert {:granted, 1} = EtaElixir.Lease.acquire(pid)
      assert_receive {:expired, 1}, 1000
      assert {:free, 1, 1} = EtaElixir.Lease.status(pid)
    end
  end

  # -------------------------------------------------------------------------
  # Under simulation
  # -------------------------------------------------------------------------

  describe "an Elixir gen_statem under eta" do
    test "runs clean and exercises the statem passes" do
      result = run(1)

      assert result.outcome == :ok,
             "the lease SUT did not come out clean: #{inspect(result.outcome)}"

      assert result.ops == 20, "not every operation was injected"

      assert :ok = @run.audit(result),
             "audit failed: #{inspect(@run.audit(result))}"
    end

    test "some schedule jumps the clock to a lease expiry" do
      # Unlike the counter, whose tick timer is always armed, the lease only
      # holds a deadline while held — so whether a given seed's run ever
      # advances the clock is the schedule's business. The claim worth
      # pinning is that the deadline is reachable at all, without coupling
      # the suite to any one seed's schedule.
      assert Enum.any?(1..10, fn seed -> run(seed).clock_ms > 0 end),
             "no schedule ever advanced the clock — the expiry may not be virtual in-run"
    end

    test "one seed produces one full result" do
      for seed <- 1..4 do
        runs = for _ <- 1..3, do: run(seed)

        assert length(Enum.uniq(runs)) == 1,
               "seed #{seed} produced #{length(Enum.uniq(runs))} distinct results"
      end
    end

    test "a recorded trace replays to the same result" do
      original = run(2)

      replayed = @run.replay(@sut, original.trace, Map.merge(@opts, %{seed: 2}))

      assert replayed.outcome == original.outcome
      assert replayed.trace == original.trace
      assert replayed.skipped == 0
    end
  end
end
