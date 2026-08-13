defmodule EtaElixirTest do
  @moduledoc """
  End-to-end test of Elixir support: an Elixir GenServer with `use Eta` driven
  through `:eta_run.run/2`.

  This is the proof that the no-parse_transform approach works on Elixir code.
  `Eta.send_after/3`, `Eta.cast/2`, `Eta.call/3`, `Eta.send/2`, and
  `Eta.start_link/3` in the SUT each expand to their `:eta_*` equivalents, and
  `@eta_observe :all` (with the `@before_compile` callback in `Eta`) wraps
  `handle_call/3` to route replies through `:eta_net` and publishes state the
  harness reads through `:eta_observe.read/1`.

  The `!` operator is not rewritten without a parse transform; the SUT uses
  `Eta.send/2` instead.
  """

  use ExUnit.Case, async: false

  @run :eta_run
  @sut EtaElixir.Harness
  @worker_sut EtaElixir.WorkerHarness

  @opts %{max_ops: 20, max_steps: 5_000, preload: [:eta]}

  defp run(seed, extra \\ %{}) do
    @run.run(@sut, Map.merge(@opts, Map.merge(extra, %{seed: seed})))
  end

  defp run_worker(seed, extra \\ %{}) do
    @run.run(@worker_sut, Map.merge(@opts, Map.merge(extra, %{seed: seed})))
  end

  # -------------------------------------------------------------------------
  # Counter SUT — basic macros
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
  # Worker SUT — full macro surface
  # -------------------------------------------------------------------------

  describe "worker SUT: spawn_link, monitor, cancel_timer, monotonic_time, reply" do
    test "runs clean and exercises the full macro surface" do
      result = run_worker(1)

      assert result.outcome == :ok,
             "the worker SUT did not come out clean: #{inspect(result.outcome)}"

      assert result.ops == 20, "not every operation was injected"

      assert result.steps > 10,
             "suspiciously few steps — the macros may not have taken effect"

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
  # @before_compile edge cases
  # -------------------------------------------------------------------------

  describe "@before_compile edge cases" do
    test "handle_call with guards still matches correctly" do
      # EtaElixir.Worker has handle_call(:health, ...) with `when state.alive`
      # and a fallback. If the wrapping broke the guard, the wrong clause
      # would match.
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # Helper is alive, so the guard clause should match.
      assert {:ok, _} = EtaElixir.Worker.health(pid)

      GenServer.stop(pid)
    end

    test "handle_call with {:stop, reason, reply, state} routes reply and stops" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # :stop returns {:stop, :normal, :ok, state}. The @before_compile
      # wrapper should route the reply through :eta_net.reply/2 and return
      # {:stop, :normal, state} to gen_server.
      assert :ok = EtaElixir.Worker.stop(pid)

      # The process should be stopped.
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    end

    test "handle_call with async reply (Eta.reply/2) works" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # :measure spawns a worker that calls Eta.reply(from, result).
      # The handle_call returns {:noreply, state}, so the reply comes
      # through :eta_net.reply/2 from the spawned worker.
      assert {:measured, _} = EtaElixir.Worker.measure(pid)

      GenServer.stop(pid)
    end

    test "handle_continue/2 state is published" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      # gen_server:start_link returns after init/1 but before handle_continue/2.
      # A call forces the GenServer to process a message, which means
      # handle_continue/2 has already run.
      {:ok, _} = EtaElixir.Worker.health(pid)

      observed = :eta_observe.read(pid)
      assert %{helper: helper, mon_ref: mon_ref} = observed
      assert is_pid(helper), "helper is not a pid: #{inspect(helper)}"
      assert is_reference(mon_ref), "mon_ref is not a reference: #{inspect(mon_ref)}"

      GenServer.stop(pid)
    end

    test "demonitor is exercised by :detach" do
      {:ok, pid} = EtaElixir.Worker.start_link([])

      assert :ok = EtaElixir.Worker.detach(pid)

      # After detach, mon_ref should be nil in the published state.
      observed = :eta_observe.read(pid)
      assert %{mon_ref: nil}, "mon_ref was not cleared after detach: #{inspect(observed)}"

      GenServer.stop(pid)
    end
  end

  # -------------------------------------------------------------------------
  # Non-DST expansion tests live in test/eta_elixir_non_dst_test.exs to avoid
  # interfering with determinism tests (Code.compile_string loads compiler
  # modules that change eta_run's modules_loaded tracking).
  # -------------------------------------------------------------------------
end
