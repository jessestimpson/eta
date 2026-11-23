defmodule EtaYieldTest do
  @moduledoc """
  `eta_sched:yield/0`, and the yield on a `gen_server` time-out of 0.

  A `gen_server` that returns a time-out of 0 asks for `timeout` as soon as its
  mailbox is empty. Without a yield, a server that does its work in chunks that
  way runs every chunk in one step, and no other process can act in between. The
  claims under test:

  1. **Other processes run between chunks.** A message that another process sends
     is handled between two chunks in some schedule.
  2. **`gen_server`'s rule holds.** The chunks are done in order, each once.
  3. **The yield is part of the schedule.** A seed reproduces, and its trace
     replays exactly.
  4. **Inert without a scheduler.** The server does all of its chunks.
  """
  use ExUnit.Case, async: false

  @chunks 5
  @opts %{max_ops: 8, max_steps: 5_000, preload: [:eta]}

  defp run(seed) do
    tab = :ets.new(:eta_yield_test, [:public, :ordered_set])

    result =
      :eta_run.run(
        :eta_yield_sut,
        Map.merge(@opts, %{seed: seed, config: %{tab: tab, chunks: @chunks}})
      )

    events = for {_seq, event} <- :lists.sort(:ets.tab2list(tab)), do: event
    :ets.delete(tab)
    {result, events}
  end

  defp interleaved?(events) do
    chunks_before = fn i -> Enum.count(Enum.take(events, i), &match?({:chunk, _}, &1)) end

    events
    |> Enum.with_index()
    |> Enum.any?(fn {event, i} ->
      match?({:poke, _}, event) and chunks_before.(i) in 1..(@chunks - 1)
    end)
  end

  test "another process is handled between two chunks" do
    assert Enum.any?(1..20, fn seed -> seed |> run() |> elem(1) |> interleaved?() end),
           "no poke was handled between two chunks in 20 seeds"
  end

  test "the chunks are done in order, each once" do
    for seed <- 1..20 do
      {result, events} = run(seed)
      assert result.outcome == :ok

      assert for({:chunk, left} <- events, do: left) == Enum.to_list(@chunks..1//-1)
    end
  end

  test "a seed reproduces and replays" do
    for seed <- 1..10 do
      runs = for _ <- 1..3, do: run(seed)
      assert [{result, _}] = Enum.uniq_by(runs, fn {r, e} -> {r.trace, e} end)
      assert :ok = :eta_run.audit(result)

      tab = :ets.new(:eta_yield_test, [:public, :ordered_set])

      replay =
        :eta_run.replay(
          :eta_yield_sut,
          result.trace,
          Map.merge(@opts, %{seed: seed, config: %{tab: tab, chunks: @chunks}})
        )

      :ets.delete(tab)
      assert replay.trace == result.trace
    end
  end

  test "without a scheduler the server does every chunk" do
    tab = :ets.new(:eta_yield_test, [:public, :ordered_set])
    {:ok, pid} = :eta_yield_worker.start(tab, @chunks)
    ref = Process.monitor(pid)

    wait = fn wait, n ->
      if :ets.info(tab, :size) == @chunks or n == 0 do
        :ok
      else
        Process.sleep(1)
        wait.(wait, n - 1)
      end
    end

    :ok = wait.(wait, 1_000)

    assert for({_, {:chunk, left}} <- :lists.sort(:ets.tab2list(tab)), do: left) ==
             Enum.to_list(@chunks..1//-1)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    :ets.delete(tab)
  end
end
