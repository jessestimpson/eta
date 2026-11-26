defmodule EtaVmWaitTest do
  @moduledoc """
  A step in which the process calls a function of the `erlang` module that
  waits for an answer of another process.

  `erlang:garbage_collect/1`, `erlang:check_process_code/2` and
  `erlang:process_info/2` of another process send a request and wait for the
  answer in a `receive` inside the call. The process is then scheduled out
  with the status `waiting`. `:eta_sched` must not end the step there.

  Each case runs in a VM of its own. Without the check in `:eta_sched`, the
  step ended inside the call in this many of 200 trials on Erlang/OTP 28:

  | Call | Target | 1 scheduler | 4 schedulers |
  |---|---|---|---|
  | `garbage_collect/1` | scheduled, heap of 3,000,000 cells | 53 | 195 |
  | `garbage_collect/1` | outside the schedule, busy | 200 | 200 |
  | `process_info/2` | outside the schedule, busy | 191 | 199 |
  """
  use ExUnit.Case, async: false

  # The system under test is Erlang: test/support/eta_vm_wait_sut.erl
  @sut :eta_vm_wait_sut

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

  for schedulers <- [1, 4],
      {call, target} <- [
        {:garbage_collect, :suspended_big},
        {:garbage_collect, :outside_busy},
        {:check_process_code, :suspended_big},
        {:process_info, :outside_busy}
      ] do
    test "a step does not end inside #{call} of a #{target} process, #{schedulers} schedulers" do
      in_peer(unquote(schedulers), fn peer ->
        assert :peer.call(peer, @sut, :early, [100, unquote(call), unquote(target)], 120_000) == 0
      end)
    end
  end

  test "a step of a process that hibernates ends as a block" do
    in_peer(4, fn peer ->
      assert :peer.call(peer, @sut, :hibernate, [], 60_000) == {0, false, true}
    end)
  end
end
