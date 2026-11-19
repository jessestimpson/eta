defmodule EtaKillWaitTest do
  @moduledoc """
  A process that kills a scheduled process and then waits for its `DOWN`.

  `supervisor:shutdown/1` does this to every child that does not trap exits.
  The victim dies at once, although the scheduler has suspended it, and its
  `DOWN` reaches the killer in real time, after the killer has blocked. The
  scheduler must treat that `DOWN` as a new message. If the scheduler counts it
  as a message the killer has already rejected, the killer is not runnable
  until its time-out fires, and a supervisor shutdown costs the whole shutdown
  time-out in virtual time.
  """
  use ExUnit.Case, async: false

  @sut :eta_kill_wait_sut
  @tab :eta_kill_wait_sut

  setup_all do
    src = Path.join([__DIR__, "support", "eta_kill_wait_sut.erl"]) |> String.to_charlist()
    {:ok, mod, bin} = :compile.file(src, [:binary, :return_errors, :debug_info])
    :code.purge(mod)
    {:module, ^mod} = :code.load_binary(mod, src, bin)
    :ok = :eta_run.preload([])
    :ok
  end

  defp run(seed, victims) do
    :eta_run.run(@sut, %{
      seed: seed,
      max_ops: 1,
      max_steps: 1_000,
      settle_steps: 200,
      config: %{victims: victims}
    })
  end

  test "the killer sees the DOWN without waiting for its time-out" do
    for seed <- 1..20 do
      result = run(seed, 1)
      assert result.outcome == :ok
      assert :ets.tab2list(@tab) == [{1, {:down, :shutdown}, 0}], "seed #{seed}"
      assert result.clock_ms == 0, "seed #{seed}"
    end
  end

  test "several kills in a row each see their DOWN at once" do
    for seed <- 1..20 do
      result = run(seed, 3)
      assert result.outcome == :ok

      assert :ets.tab2list(@tab) == for(n <- 1..3, do: {n, {:down, :shutdown}, 0}),
             "seed #{seed}"
    end
  end
end
