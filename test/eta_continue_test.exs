defmodule EtaContinueTest do
  @moduledoc """
  The first `handle_continue/2` of a `gen_server` that is started during a run.

  `init/1` of `eta_continue_server` returns `{ok, State, {continue, step}}`.
  Each `handle_continue/2` does the next step of a script. A script is 0 to 3
  chained continues and then one last step. The last steps are every return
  that `gen_server` accepts from `handle_continue/2`, an error, an exit, a
  throw and a bad return.

  The claims under test:

  1. **A run equals OTP.** For each of the 56 scripts, the answer to a call,
     the exit reason of the server and the reason that `terminate/2` receives
     are equal in a run and outside a run.
  2. **A time-out of 0 yields once.** The run of a script that ends with a
     time-out of 0 calls `eta_sched:yield/0` once more than the run of a script
     that ends with `infinity`.

  The primary level of `logger` is `none` during each test. A `gen_server` that
  stops with an error writes a report through `logger`, in `stdlib` code that
  `eta_transform` does not rewrite. With the report, 1,500 runs of seed 1 of the
  script `[{:stop, :bye}]` had 3 different traces. Without the report, the 1,500
  runs had 1 trace. See "Why logging is a determinism hazard" in `eta_logger`.
  """
  use ExUnit.Case, async: false

  setup do
    %{level: level} = :logger.get_primary_config()
    :ok = :logger.set_primary_config(:level, :none)
    on_exit(fn -> :ok = :logger.set_primary_config(:level, level) end)
  end

  @lasts [
    :noreply,
    :hibernate,
    :zero,
    :infinity,
    :timeout,
    :throw,
    :bad,
    {:stop, :normal},
    {:stop, :shutdown},
    {:stop, :bye},
    {:error, :boom},
    {:exit, :normal},
    {:exit, :shutdown},
    {:exit, :bye}
  ]

  @scripts for n <- 0..3, last <- @lasts, do: List.duplicate(:continue, n) ++ [last]

  defp outcome(play) do
    :eta_continue = :ets.new(:eta_continue, [:named_table, :public])

    try do
      play.()
      :eta_continue_ops.outcome()
    after
      :ets.delete(:eta_continue)
    end
  end

  defp otp(script), do: outcome(fn -> :ok = :eta_continue_ops.client(script) end)

  defp eta(script) do
    outcome(fn ->
      result =
        :eta_run.run(:eta_continue_sut, %{seed: 1, max_ops: 1, config: %{script: script}})

      assert result.outcome == :ok, inspect(:eta_run.summary(result))
    end)
  end

  test "there are 56 scripts" do
    assert length(@scripts) == 56
  end

  for script <- @scripts do
    test "a run equals OTP for the script #{inspect(script)}" do
      script = unquote(Macro.escape(script))
      assert eta(script) == otp(script)
    end
  end

  test "a server that does not stop answers the call" do
    for last <- [:noreply, :hibernate, :zero, :infinity, :timeout, :throw] do
      assert [answer: :pong, exit: :shutdown] = eta([:continue, last])
    end
  end

  test "a stop calls terminate/2 with the reason" do
    assert {:terminated, :bye} in eta([{:stop, :bye}])
    assert {:terminated, :boom} in eta([{:error, :boom}])
    assert {:terminated, :bye} in eta([{:exit, :bye}])
  end

  test "a seed gives one trace for a script that stops with an error" do
    traces =
      for _ <- 1..200 do
        outcome(fn ->
          result =
            :eta_run.run(:eta_continue_sut, %{
              seed: 1,
              max_ops: 1,
              config: %{script: [{:stop, :bye}]}
            })

          send(self(), {:trace, result.trace})
        end)

        assert_received {:trace, trace}
        trace
      end

    assert [_] = Enum.uniq(traces)
  end

  test "a time-out of 0 yields once" do
    assert yields([:zero]) - yields([:infinity]) == 1
  end

  defp yields(script) do
    mfa = {:eta_sched, :yield, 0}
    {:module, :eta_sched} = :code.ensure_loaded(:eta_sched)
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      eta(script)
      {:call_count, count} = :erlang.trace_info(mfa, :call_count)
      count
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end
end
