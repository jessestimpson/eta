defmodule EtaDrainTest do
  @moduledoc """
  A `gen_server` that drains its own mailbox with `receive ... after 0`.

  The claim under test: the requests that such a server finds in its mailbox are
  a function of the seed. A server that commits requests in groups depends on
  this. peace's `peace_server` is one.
  """
  use ExUnit.Case, async: false

  @opts %{max_ops: 30, max_steps: 5_000, preload: [:eta]}

  defp run(seed) do
    tab = :ets.new(:eta_drain_test, [:public, :ordered_set])
    result = :eta_run.run(:eta_drain_sut, Map.merge(@opts, %{seed: seed, config: %{tab: tab}}))
    groups = :eta_drain_server.groups(tab)
    :ets.delete(tab)
    {result, groups}
  end

  test "the groups are a function of the seed" do
    for seed <- 1..10 do
      runs = for _ <- 1..3, do: run(seed)
      assert [{result, groups}] = Enum.uniq_by(runs, fn {r, g} -> {r.trace, g} end)
      assert result.outcome == :ok
      assert :ok = :eta_run.audit(result)
      assert List.flatten(groups) == Enum.to_list(1..length(List.flatten(groups)))
    end
  end

  test "the server does find requests in its mailbox" do
    sizes = for seed <- 1..10, {_, groups} = run(seed), g <- groups, do: length(g)
    assert Enum.max(sizes) > 1, "no group had more than one item, so nothing was drained"
  end
end
