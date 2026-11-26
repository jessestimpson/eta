defmodule EtaExitSignalTest do
  @moduledoc """
  The deaths that happen outside a step of the dead process.

  A process that does not trap exits dies when the VM handles an exit signal
  for the process, also while `:eta_sched` holds the process suspended. The
  signal comes from a linked process that exits or from `erlang:exit/2`.
  `:eta_sched` must settle these deaths before the next choice, and before
  the end of a step of a process that called `erlang:exit/2`.

  Each case runs in a VM of its own. Without the settling in `:eta_sched`:

  - a chain of 4 links left the watcher not runnable in 46 to 51 of 200
    trials with 1 scheduler, and a chain of 8 links in 200 of 200;
  - `:eta_sched.release/1` failed in 194 to 198 of the 200 trials with a
    chain of 8 links;
  - the shutdown case missed the `DOWN` message in 19 of 5,000 trials with 8
    schedulers and 8 processes that never block.
  """
  use ExUnit.Case, async: false

  # The system under test is Erlang: test/support/eta_exit_signal_sut.erl
  @sut :eta_exit_signal_sut

  defp in_peer(schedulers, fun) do
    paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
    args = [~c"+S", Integer.to_charlist(schedulers)] ++ paths
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io, args: args})

    try do
      fun.(peer)
    after
      :peer.stop(peer)
    end
  end

  for schedulers <- [1, 8], links <- [1, 2, 4, 8] do
    test "a watcher of a chain of #{links} links is runnable after the step, #{schedulers} schedulers" do
      in_peer(unquote(schedulers), fn peer ->
        assert :peer.call(peer, @sut, :chain, [200, unquote(links)], 120_000) == 0
      end)
    end
  end

  test "the EXIT message of exit/2 is in the queue before the end of the step" do
    in_peer(8, fn peer ->
      assert :peer.call(peer, @sut, :trapper, [2_000, 8], 120_000) == 0
    end)
  end

  test "a process that calls exit/2 takes the DOWN message in the same step" do
    in_peer(8, fn peer ->
      assert :peer.call(peer, @sut, :shutdown, [2_000, 8], 120_000) == 0
    end)
  end
end
