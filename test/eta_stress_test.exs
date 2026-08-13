defmodule EtaStressTest do
  @moduledoc """
  `:eta_stress` — a system under test designed to maximize the surface area
  where `eta`'s determinism could break.

  Every mechanism that has ever produced a nondeterminism bug in `eta` is
  working hard at once: `gen_statem` `state_timeout` arming, cancellation by
  state change, and rearming with `keep_state` (hundreds of cycles per run);
  fan-out casts to every peer inside one scheduler step (the state the schedule
  alone cannot produce); network fault injection with drops and delays; monitor
  retirement and `noconnection` DOWN delivery across simulated nodes; and the
  virtual clock on the critical path, because members only progress when their
  tick deadlines fire.

  The SUT is correct — there is no planted bug, and the invariant always holds.
  The assertion is that the same seed produces one result, and a run this dense
  is the one most likely to find a drift in `eta` itself.
  """

  use ExUnit.Case, async: false

  @run :eta_run
  @sut :eta_stress

  @opts %{max_ops: 20, max_steps: 10_000, preload: [:eta]}
  @lossy %{net: %{policy: %{drop_p: 0.15, delay_p: 0.15, max_delay: 20}}}

  setup do
    on_exit(fn ->
      :eta_net.stop()
      :eta_time.stop()
    end)

    :ok
  end

  defp run(seed, extra \\ %{}) do
    @run.run(@sut, Map.merge(@opts, Map.merge(extra, %{seed: seed})))
  end

  describe "determinism under stress, with a lossy network" do
    @describetag timeout: 120_000

    test "every seed produces one full result" do
      for seed <- 1..6 do
        runs = for _ <- 1..3, do: run(seed, @lossy)

        assert length(Enum.uniq(runs)) == 1,
               "seed #{seed} produced #{length(Enum.uniq(runs))} distinct results in 3 runs"

        [one] = Enum.uniq(runs)

        # Non-vacuity: a run that executed nothing satisfies "one result" trivially.
        # The stress is in the volume — hundreds of steps, thousands of virtual
        # milliseconds, and real network activity.
        assert one.ops == 20, "seed #{seed} did not inject every operation"
        assert one.steps > 500, "seed #{seed} ran suspiciously few steps: #{one.steps}"
        assert one.clock_ms > 5_000, "seed #{seed} barely advanced the clock: #{one.clock_ms}"

        assert one.net.dropped > 0,
               "seed #{seed} lost nothing; the lossy network was not exercised"
      end
    end
  end

  describe "determinism under stress, without a network" do
    # The pure path: scheduler + state timeouts + virtual clock, with no fault
    # injection. This isolates the surfaces `eta_statem` and `eta_time` own from
    # the ones `eta_net` does. A bug in either shows up here as a different
    # result from the same seed.
    @describetag timeout: 120_000

    test "every seed produces one full result" do
      for seed <- 1..6 do
        runs = for _ <- 1..3, do: run(seed)

        assert length(Enum.uniq(runs)) == 1,
               "seed #{seed} produced #{length(Enum.uniq(runs))} distinct results in 3 runs"

        [one] = Enum.uniq(runs)

        assert one.ops == 20, "seed #{seed} did not inject every operation"
        assert one.steps > 500, "seed #{seed} ran suspiciously few steps: #{one.steps}"
        assert one.clock_ms > 5_000, "seed #{seed} barely advanced the clock: #{one.clock_ms}"

        # No network, so no drops and no strays: members never die, so their
        # state timeouts are always cleaned up. This is the clean audit a
        # well-behaved SUT should assert on.
        assert one.stray_timers == 0, "seed #{seed} left #{one.stray_timers} stray timers"
        assert :ok = @run.audit(one), "seed #{seed} failed audit without a network"
      end
    end
  end

  describe "a recorded trace replays to the same result" do
    # Replay draws no choices from the seed, but the network still makes
    # decisions — and it makes the same ones, because they are a function of
    # the order sends happen in, which the trace fixes. This is the property
    # that makes a counterexample useful: it reproduces.
    test "under a lossy network" do
      original = run(4, @lossy)

      replayed =
        @run.replay(@sut, original.trace, Map.merge(@opts, Map.merge(@lossy, %{seed: 4})))

      assert replayed.outcome == original.outcome
      assert replayed.trace == original.trace
      assert replayed.net == original.net
      assert replayed.skipped == 0
    end

    test "without a network" do
      original = run(4)

      replayed = @run.replay(@sut, original.trace, Map.merge(@opts, %{seed: 4}))

      assert replayed.outcome == original.outcome
      assert replayed.trace == original.trace
      assert replayed.skipped == 0
    end
  end
end
