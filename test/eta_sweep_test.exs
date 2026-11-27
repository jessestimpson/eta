defmodule EtaSweepTest do
  @moduledoc """
  `eta_run:sweep/3`, and the shrinking of the content of an operation in
  `eta_shrink:shrink/3`.

  The harness is `eta_sweep_sut`. An operation is `{put, Key, Size}`. The
  invariant is violated when a stored size is at or above the limit of the
  configuration. The least trace that violates the invariant has one operation,
  `{put, 1, Limit}`.

  The claims under test:

  1. **A sweep runs every seed when no run fails.**
  2. **A sweep stops at the first seed that fails.** The seed equals the first
     failing seed of a loop over `eta_run:run/2`.
  3. **A sweep shrinks a violation**, unless the option `shrink` is `false`.
  4. **A sweep stops at an error and does not shrink the error.**
  5. **A sweep with the option `audit` stops at a suspect run.** Without the
     option, the same sweep passes.
  6. **`shrink/3` reaches the least operation.** For each failing seed, the
     shrunk trace has the one operation `{put, 1, Limit}`, and the trace
     replays strictly.
  7. **Without `shrink_op/1`, `shrink/3` changes no operation.**
  8. **`shrink/3` removes entries again after it replaces an operation.** With
     the configuration `pair`, a trace with 2 operations on the keys 2 and 3
     shrinks to the one operation `{put, 1, Limit}`.
  9. **The `max_tests` budget ends the search** when `shrink_op/1` returns the
     operation that it received.
  """
  use ExUnit.Case, async: false

  @sut :eta_sweep_sut
  @limit 30
  @opts %{max_ops: 3, max_steps: 2_000, config: %{limit: @limit}}
  @seeds Enum.to_list(1..40)

  defp ops(trace), do: for({:op, op} <- Enum.map(trace, &:eta_run.action/1), do: op)

  defp failing?(seed),
    do: match?({:violation, _}, :eta_run.run(@sut, Map.put(@opts, :seed, seed)).outcome)

  test "a sweep runs every seed when no run fails" do
    sweep = :eta_run.sweep(@sut, @seeds, %{max_ops: 3, max_steps: 2_000})

    assert sweep == %{outcome: :ok, runs: 40}
  end

  test "a sweep of no seeds passes" do
    assert :eta_run.sweep(@sut, [], @opts) == %{outcome: :ok, runs: 0}
  end

  test "a sweep stops at the first seed that fails" do
    # The list starts with a seed that passes, so a sweep that stops at its
    # first seed fails the test.
    seeds = Enum.drop_while(@seeds, &failing?/1)
    first = Enum.find(seeds, &failing?/1)
    assert first, "no seed of the list fails"
    assert first != hd(seeds)

    sweep = :eta_run.sweep(@sut, seeds, @opts)

    assert sweep.seed == first
    assert sweep.runs == Enum.find_index(seeds, &(&1 == first)) + 1
    assert {:violation, %{property: :small_values}} = sweep.outcome
    assert sweep.result.outcome == sweep.outcome
    assert sweep.result.seed == first
    assert sweep.result.trace == :eta_run.run(@sut, Map.put(@opts, :seed, first)).trace
  end

  test "a sweep shrinks a violation, and the shrunk trace replays with the reported seed" do
    sweep = :eta_run.sweep(@sut, @seeds, @opts)

    assert %{verified: true, trace: trace} = sweep.shrunk
    assert ops(trace) == [{:put, 1, @limit}]

    replayed = :eta_run.replay(@sut, trace, Map.put(@opts, :seed, sweep.seed))
    assert {:violation, %{property: :small_values}} = replayed.outcome
    assert replayed.skipped == 0
  end

  test "a sweep passes max_tests to the shrinker" do
    sweep = :eta_run.sweep(@sut, @seeds, Map.put(@opts, :max_tests, 3))

    assert sweep.shrunk.tests <= 3
  end

  test "a sweep with shrink false does not shrink" do
    sweep = :eta_run.sweep(@sut, @seeds, Map.put(@opts, :shrink, false))

    assert {:violation, _} = sweep.outcome
    refute Map.has_key?(sweep, :shrunk)
  end

  test "a sweep stops at an error and does not shrink the error" do
    sweep = :eta_run.sweep(@sut, @seeds, %{@opts | max_steps: 1})

    assert sweep.outcome == {:error, :step_budget_exhausted}
    assert sweep.runs == 1
    assert sweep.seed == 1
    refute Map.has_key?(sweep, :shrunk)
  end

  describe "the audit option" do
    @suspect %{max_ops: 3, max_steps: 2_000, config: %{driver_draw: true}}

    test "a sweep stops at a run that passes its invariants and is suspect" do
      sweep = :eta_run.sweep(@sut, @seeds, Map.put(@suspect, :audit, true))

      assert {:error, {:suspect, reasons}} = sweep.outcome
      assert Keyword.has_key?(reasons, :rand_unmanaged)
      assert sweep.runs == 1
      assert sweep.seed == 1
      assert sweep.result.outcome == :ok
      assert sweep.audit == {:suspect, reasons}
      refute Map.has_key?(sweep, :shrunk)
    end

    test "without the option, the same sweep passes" do
      assert :eta_run.sweep(@sut, @seeds, @suspect) == %{outcome: :ok, runs: 40}
    end

    test "a sweep of clean runs passes with the option" do
      opts = %{max_ops: 3, max_steps: 2_000, audit: true}

      assert :eta_run.sweep(@sut, @seeds, opts) == %{outcome: :ok, runs: 40}
    end

    test "a violation of a clean run reports the audit ok and is shrunk" do
      sweep = :eta_run.sweep(@sut, @seeds, Map.put(@opts, :audit, true))

      assert {:violation, _} = sweep.outcome
      assert sweep.audit == :ok
      assert sweep.shrunk.verified
    end

    test "a violation of a suspect run keeps the violation and reports the audit" do
      opts = %{@opts | config: %{limit: @limit, driver_draw: true}}
      first = Enum.find(@seeds, &failing?/1)

      sweep =
        :eta_run.sweep(@sut, Enum.drop_while(@seeds, &(&1 != first)), Map.put(opts, :audit, true))

      assert {:violation, %{property: :small_values}} = sweep.outcome
      assert {:suspect, _} = sweep.audit
      assert Map.has_key?(sweep, :shrunk)
    end

    test "without the option, a failed run has no audit key" do
      sweep = :eta_run.sweep(@sut, @seeds, @opts)

      refute Map.has_key?(sweep, :audit)
    end
  end

  test "shrink/3 reaches the least operation for every failing seed" do
    failing = Enum.filter(@seeds, &failing?/1)
    assert length(failing) >= 10, "only #{length(failing)} of 40 seeds fail"

    for seed <- failing do
      opts = Map.put(@opts, :seed, seed)
      original = :eta_run.run(@sut, opts)
      result = :eta_shrink.shrink(@sut, original.trace, opts)

      assert result.verified, "seed #{seed}: the shrunk trace does not replay strictly"
      assert ops(result.trace) == [{:put, 1, @limit}], "seed #{seed}"

      replayed = :eta_run.replay(@sut, result.trace, opts)
      assert {:violation, %{property: :small_values, large: [{1, @limit}]}} = replayed.outcome
      assert replayed.skipped == 0
    end
  end

  test "ops_shrunk counts the replacements that were kept" do
    seed = Enum.find(@seeds, &failing?/1)
    opts = Map.put(@opts, :seed, seed)
    original = :eta_run.run(@sut, opts)

    refute {:put, 1, @limit} in ops(original.trace),
           "the generator produced the least operation, so the test shows nothing"

    result = :eta_shrink.shrink(@sut, original.trace, opts)
    assert result.ops_shrunk >= 1
  end

  test "without shrink_op/1, shrink/3 changes no operation" do
    refute function_exported?(:eta_2pc, :shrink_op, 1)
    opts = %{max_ops: 25, max_steps: 20_000, config: %{mode: :first_vote_wins}}

    seed =
      Enum.find(1..60, fn s ->
        match?({:violation, _}, :eta_run.run(:eta_2pc, Map.put(opts, :seed, s)).outcome)
      end)

    original = :eta_run.run(:eta_2pc, Map.put(opts, :seed, seed))
    result = :eta_shrink.shrink(:eta_2pc, original.trace, Map.put(opts, :seed, seed))

    assert result.verified
    assert result.ops_shrunk == 0
    assert ops(result.trace) -- ops(original.trace) == []
  end

  test "shrink/3 removes entries again after it replaces an operation" do
    opts = %{max_ops: 6, max_steps: 2_000, config: %{limit: @limit, pair: true}}
    opts = Map.put(opts, :seed, pair_seed(opts))

    original = :eta_run.run(@sut, opts)
    assert {:violation, _} = original.outcome
    refute Enum.any?(ops(original.trace), &match?({:put, 1, size} when size >= @limit, &1))

    result = :eta_shrink.shrink(@sut, original.trace, opts)

    assert result.verified
    assert ops(result.trace) == [{:put, 1, @limit}]
  end

  # A seed whose run violates the pair invariant without a large size under
  # the key 1.
  defp pair_seed(opts) do
    Enum.find(1..200, fn seed ->
      run = :eta_run.run(@sut, Map.put(opts, :seed, seed))

      match?({:violation, _}, run.outcome) and
        not Enum.any?(ops(run.trace), &match?({:put, 1, size} when size >= @limit, &1))
    end) || flunk("no seed violates the pair invariant without the key 1")
  end

  test "the max_tests budget ends the search when shrink_op/1 returns its argument" do
    opts = %{@opts | config: %{limit: @limit, cycle: true}}
    seed = Enum.find(@seeds, &failing?/1)
    opts = Map.put(opts, :seed, seed)
    original = :eta_run.run(@sut, opts)

    result = :eta_shrink.shrink(@sut, original.trace, Map.put(opts, :max_tests, 40))

    assert result.tests == 40
    assert result.verified
    assert {:violation, _} = result.outcome
  end
end
