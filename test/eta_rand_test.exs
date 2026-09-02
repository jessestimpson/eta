defmodule EtaRandTest do
  @moduledoc """
  `:eta_rand` — the process-local `rand` state, seeded from the run.

  The claim under test: a system that draws from `rand:uniform/1` without ever
  seeding it has draws that are a function of the run's seed, and a draw made
  outside the schedule is reported rather than silently changing the run.
  """
  use ExUnit.Case, async: false

  @run :eta_run
  @rand :eta_rand
  @sut :eta_rand_sut
  @worker :eta_rand_worker

  @opts %{max_ops: 12, max_steps: 5_000, preload: [:eta]}
  @workers 3

  setup do
    on_exit(fn ->
      @rand.stop()
      :eta_time.stop()
    end)

    :ok
  end

  # A run against a fresh table, returning the result and every worker's draws.
  defp run(seed, extra \\ %{}) do
    tab = :ets.new(:eta_rand_test, [:public, :ordered_set])
    config = Map.merge(%{tab: tab}, Map.get(extra, :config, %{}))
    opts = @opts |> Map.merge(extra) |> Map.merge(%{seed: seed, config: config})
    result = @run.run(@sut, opts)
    draws = draws(tab)
    :ets.delete(tab)
    {result, draws}
  end

  defp draws(tab), do: for(i <- 1..@workers, do: @worker.values(tab, {:worker, i}))

  describe "inert" do
    test "delegates to rand when no run has started it" do
      refute @rand.running()

      v = @rand.uniform(10)
      assert v in 1..10
      assert is_float(@rand.uniform())
      assert is_float(@rand.uniform_real())
      assert is_float(@rand.normal())

      # Nothing of this module's was left behind in the process.
      assert Process.get(:"$eta_rand") == nil
    end
  end

  describe "under a run" do
    test "draws are a function of the seed" do
      runs = for _ <- 1..5, do: run(3)

      distinct = runs |> Enum.map(fn {r, d} -> {r.trace, r.rand, d} end) |> Enum.uniq()
      assert length(distinct) == 1, "one seed produced #{length(distinct)} distinct runs in 5"

      {result, draws} = hd(runs)
      assert result.outcome == :ok
      assert :ok = @run.audit(result)

      # Non-vacuity: the workers actually drew, and each got its own stream.
      assert result.rand.draws > 0
      assert Enum.count(draws, &(&1 != [])) > 1
      assert result.rand.streams == Enum.count(draws, &(&1 != []))
    end

    test "a different seed draws differently" do
      {_, a} = run(3)
      {_, b} = run(4)

      assert a != b
    end

    test "a recorded trace replays with the same draws" do
      {recorded, draws} = run(9)

      tab = :ets.new(:eta_rand_replay, [:public, :ordered_set])
      opts = Map.merge(@opts, %{seed: 9, config: %{tab: tab}})
      replayed = @run.replay(@sut, recorded.trace, opts)

      assert replayed.skipped == 0
      assert replayed.rand == recorded.rand
      assert draws(tab) == draws
      :ets.delete(tab)
    end

    test "an explicit rand:seed/2 is honoured" do
      seed = {1, 2, 3}
      {_result, [first | _]} = run(5, %{config: %{reseed: seed}})

      # Worker 1 was reseeded before any of its draws, so its values are exactly
      # what `rand` itself produces from that seed.
      expected =
        Enum.map_reduce(first, :rand.seed_s(:exsss, seed), fn _, s ->
          :rand.uniform_s(1_000_000, s)
        end)
        |> elem(0)

      assert first != [], "worker 1 never drew; the run proves nothing"
      assert first == expected
    end

    test "a draw by a process the scheduler is not stepping is counted, and audit says so" do
      {result, _} = run(5, %{config: %{driver_draw: true}})

      assert result.rand.unmanaged > 0
      assert {:suspect, reasons} = @run.audit(result)
      assert Keyword.has_key?(reasons, :rand_unmanaged)
    end

    test "a stream left by an earlier run is not continued" do
      # The test process draws under one run, then under another with the same
      # seed. If the stream carried over, the second run's first draw would be
      # the first run's second — and it is a process the scheduler never owned,
      # which is exactly the leftover a long-lived test process is.
      :ok = @rand.start(%{seed: 1})
      a1 = @rand.uniform(1_000_000)
      _a2 = @rand.uniform(1_000_000)
      @rand.stop()

      :ok = @rand.start(%{seed: 1})
      b1 = @rand.uniform(1_000_000)
      @rand.stop()

      assert a1 == b1
    end
  end
end
