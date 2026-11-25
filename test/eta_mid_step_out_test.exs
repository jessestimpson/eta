defmodule EtaMidStepOutTest do
  @moduledoc """
  The end of a step of `:eta_sched` when the VM schedules the process out and
  in again in the middle of the step.

  `erlang:demonitor(Ref, [:flush])` after a reply through an alias with the
  option `reply_demonitor` has that effect. `:gen_server.check_response/3`
  makes this call. The scheduler must end the step at the last `out` trace
  event of the step.

  The case runs in a VM of its own with 8 schedulers and 8 processes that
  never block. Without the check in `:eta_sched`, the client was runnable
  after the step in 358 to 413 of 3,000 trials under these conditions.
  """
  use ExUnit.Case, async: false

  # The system under test is Erlang: test/support/eta_mid_step_out_sut.erl
  @sut :eta_mid_step_out_sut

  test "a step ends at the last out event when demonitor schedules the process out" do
    paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io, args: [~c"+S", ~c"8"] ++ paths})

    try do
      assert :peer.call(peer, @sut, :run, [3_000, 8], 120_000) == 0
    after
      :peer.stop(peer)
    end
  end
end
