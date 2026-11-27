defmodule EtaPreemptTest do
  @moduledoc """
  Preemption points: the attribute `-eta_preempt(...)`, `eta_sched:preempt/0`
  and the run option `preempt`.

  The system is `eta_preempt_store`. A transfer changes 2 balances with 2 ETS
  calls, and a reader reads the 2 balances in its own process. The sum of the
  balances is 100 after every transfer and is not 100 between the 2 calls.

  The claims under test:

  1. **Without the option, a run does not reach the state between the 2
     calls.** No seed violates the invariant.
  2. **With the option, a run reaches that state.** A sweep finds a violation,
     and the shrunk trace replays strictly.
  3. **A system that is correct on the BEAM passes with the option.** The
     atomic mode of the store passes every seed, and the runs preempt.
  4. **The option keeps a run a function of its seed.** A seed gives one
     trace, the trace replays, and the audit passes.
  5. **A probability of 0.0 changes nothing.** The trace equals the trace
     without the option.
  6. **The pass wraps the calls that the attribute names, and no other
     call.**
  """
  use ExUnit.Case, async: false

  @sut :eta_preempt_sut
  @opts %{max_ops: 12, max_steps: 4_000, preload: [:eta]}
  @seeds Enum.to_list(1..60)

  defp ops(trace), do: for({:op, op} <- Enum.map(trace, &:eta_run.action/1), do: op)

  describe "a run without the option" do
    test "does not reach the state between the 2 calls of a transfer" do
      assert :eta_run.sweep(@sut, @seeds, Map.put(@opts, :audit, true)) ==
               %{outcome: :ok, runs: 60}
    end

    test "counts no preemption point" do
      result = :eta_run.run(@sut, Map.put(@opts, :seed, 1))

      assert result.sched.preempt_points == 0
      assert result.sched.preemptions == 0
    end

    test "has the trace of a run with the probability 0.0" do
      for seed <- 1..10 do
        without = :eta_run.run(@sut, Map.put(@opts, :seed, seed))
        zero = :eta_run.run(@sut, Map.merge(@opts, %{seed: seed, preempt: 0.0}))

        assert zero.trace == without.trace
        assert zero.sched.preempt_points == 0
      end
    end
  end

  describe "a run with the option" do
    @preempt Map.put(@opts, :preempt, 0.5)

    test "finds the read between the 2 calls of a transfer" do
      sweep = :eta_run.sweep(@sut, @seeds, Map.put(@preempt, :audit, true))

      assert {:violation, %{property: :total, totals: [first]}} = sweep.outcome
      assert first != 100
      assert sweep.audit == :ok

      # The least failure is one transfer of 1 and one read. The read sees the
      # sum 99 or 101, as it reads the first balance before or after the
      # transfer.
      assert %{verified: true, trace: trace, outcome: {:violation, %{totals: [total]}}} =
               sweep.shrunk

      assert total in [99, 101]
      assert Enum.sort(ops(trace)) == [:read, {:transfer, 1}]

      replayed = :eta_run.replay(@sut, trace, Map.put(@preempt, :seed, sweep.seed))
      assert {:violation, %{property: :total, totals: [^total]}} = replayed.outcome
      assert replayed.skipped == 0
    end

    test "a replay without the option does not follow the trace" do
      sweep = :eta_run.sweep(@sut, @seeds, Map.put(@preempt, :shrink, false))
      assert {:violation, _} = sweep.outcome

      replayed = :eta_run.replay(@sut, sweep.result.trace, Map.put(@opts, :seed, sweep.seed))
      refute match?({:violation, _}, replayed.outcome)
    end

    test "passes a store that is correct on the BEAM, and the runs preempt" do
      opts = Map.put(@preempt, :config, %{atomic: true})

      assert :eta_run.sweep(@sut, @seeds, Map.put(opts, :audit, true)) ==
               %{outcome: :ok, runs: 60}

      scheds = for seed <- 1..10, do: :eta_run.run(@sut, Map.put(opts, :seed, seed)).sched
      points = scheds |> Enum.map(& &1.preempt_points) |> Enum.sum()
      preemptions = scheds |> Enum.map(& &1.preemptions) |> Enum.sum()

      assert points > 100
      assert preemptions > points / 4
      assert preemptions < points * 3 / 4
    end

    test "a seed gives one trace, and the trace replays" do
      opts = Map.put(@preempt, :config, %{atomic: true})

      for seed <- 1..10 do
        runs = for _ <- 1..3, do: :eta_run.run(@sut, Map.put(opts, :seed, seed))
        assert [result] = Enum.uniq_by(runs, & &1.trace)
        assert result.outcome == :ok
        assert :ok = :eta_run.audit(result)
        assert result.sched.preemptions > 0

        replayed = :eta_run.replay(@sut, result.trace, Map.put(opts, :seed, seed))
        assert replayed.trace == result.trace
        assert replayed.skipped == 0
        assert replayed.sched.preemptions == result.sched.preemptions
      end
    end

    test "a check that reads the table at every step sees the state between the 2 writes" do
      # The atomic store is correct, so the readers never see a wrong sum. The
      # rows `a` and `b` are not used in that mode, so this test uses the mode
      # with 2 rows and looks only for the violation `table`.
      opts = Map.put(@preempt, :config, %{check_table: :always})
      sweep = :eta_run.sweep(@sut, @seeds, Map.merge(opts, %{shrink: false, match: nil}))

      assert {:violation, %{property: property}} = sweep.outcome
      assert property in [:table, :total]

      tables =
        for seed <- @seeds,
            {:violation, %{property: :table}} <- [
              :eta_run.run(@sut, Map.put(opts, :seed, seed)).outcome
            ],
            do: seed

      assert tables != [], "no seed has the violation of the table"
    end

    test "preempted/1 lets the check skip the table while the store is preempted" do
      # With the default configuration the check skips the table while the
      # store waits at a preemption point. No seed has the violation `table`.
      for seed <- @seeds do
        outcome = :eta_run.run(@sut, Map.put(@preempt, :seed, seed)).outcome
        refute match?({:violation, %{property: :table}}, outcome), "seed #{seed}"
      end
    end

    test "with the probability 1.0 every point preempts" do
      opts = Map.merge(@opts, %{preempt: 1.0, seed: 3, config: %{atomic: true}})
      result = :eta_run.run(@sut, opts)

      assert result.outcome == :ok
      assert result.sched.preempt_points > 0
      assert result.sched.preemptions == result.sched.preempt_points
    end

    test "a probability outside 0.0 to 1.0 is refused" do
      for bad <- [1.5, -0.1, :often] do
        assert {:eta_sched, {:bad_preempt, ^bad, _}} =
                 catch_error(:eta_sched.new(%{preempt: bad}))
      end

      refute :eta_sched.active()
    end
  end

  describe "outside a run" do
    test "the store works, and preempt/0 returns ok" do
      refute :eta_sched.active()
      assert :eta_sched.preempt() == :ok
      refute :eta_sched.preempted(self())

      {:ok, store} = :eta_preempt_store.start_link(false)
      handle = :eta_preempt_store.handle(store)
      :ok = :eta_preempt_store.transfer(store, 7)
      assert :eta_preempt_store.total(handle) == 100
      :ok = :gen_server.stop(store)
    end
  end

  describe "the pass" do
    @head ~c"-module(m). -export([f/1]). "
    @body ~c"f(T) -> ets:insert(T, ets:lookup(T, k)), atomics:get(T, 1), lists:sort(ets:tab2list(T))."

    defp count(attribute, call), do: :eta_preempt_forms.count(@head ++ attribute ++ @body, call)

    test "wraps every call of a module that the attribute names" do
      assert count(~c"-eta_preempt([ets]). ", {:eta_sched, :preempt}) == 3
      assert count(~c"-eta_preempt([ets, atomics]). ", {:eta_sched, :preempt}) == 4
    end

    test "wraps the calls of a function that the attribute names" do
      assert count(~c"-eta_preempt([{ets, insert, 2}]). ", {:eta_sched, :preempt}) == 1
      assert count(~c"-eta_preempt([{ets, insert, 3}]). ", {:eta_sched, :preempt}) == 0
    end

    test "wraps nothing without the attribute" do
      assert count(~c"", {:eta_sched, :preempt}) == 0
    end

    test "leaves a wrapped call to the other passes" do
      # `ets:tab2list/1` is rewritten to `eta_ets`, with and without the wrap.
      assert count(~c"", {:eta_ets, :tab2list}) == 1
      assert count(~c"-eta_preempt([ets]). ", {:eta_ets, :tab2list}) == 1
      assert count(~c"-eta_preempt([ets]). ", {:ets, :tab2list}) == 0
    end

    test "refuses a value that is not a list of modules and functions" do
      assert_raise ErlangError, fn -> count(~c"-eta_preempt(ets). ", {:eta_sched, :preempt}) end

      assert_raise ErlangError, fn ->
        count(~c"-eta_preempt([{ets, insert}]). ", {:eta_sched, :preempt})
      end
    end
  end
end
