defmodule EtaPidReuseTest do
  @moduledoc """
  The statistic `pid_reuse` of `:eta_sched`.

  The term order of pids is their creation order until the VM has created about
  as many processes as its process limit. After that the VM reuses pid values,
  and a new process can have a pid that compares below the pid of an older one.
  A system or a harness that sorts pids then orders the same processes
  differently from one run of a seed to the next.

  Each case runs in a VM of its own, because the count depends on the number
  of processes that the VM has created before the run.
  """
  use ExUnit.Case, async: false

  # The system under test is Erlang: test/support/eta_pid_reuse_sut.erl
  @sut :eta_pid_reuse_sut

  defp in_new_vm(extra_args, fun) do
    paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)

    {:ok, peer, _node} =
      :peer.start(%{connection: :standard_io, args: [~c"+S", ~c"1"] ++ extra_args ++ paths})

    try do
      fun.(peer)
    after
      :peer.stop(peer)
    end
  end

  test "a new VM with the default process limit reuses no pid in 3,000 spawns" do
    in_new_vm([], fn peer ->
      assert :peer.call(peer, :erlang, :system_info, [:process_limit]) == 1_048_576
      %{stats: stats, sorted: sorted} = :peer.call(peer, @sut, :run, [3_000], 60_000)
      # The parent and its 3,000 children. A child of a module without the
      # transform runs before the scheduler owns it.
      assert stats.pid_reuse == 0
      assert sorted, "the term order of the pids must be their creation order"
    end)
  end

  test "a VM with a process limit of 1,024 reuses pids within 3,000 spawns" do
    in_new_vm([~c"+P", ~c"1024"], fn peer ->
      assert :peer.call(peer, :erlang, :system_info, [:process_limit]) == 1024
      %{stats: stats, sorted: sorted} = :peer.call(peer, @sut, :run, [3_000], 60_000)
      assert stats.pid_reuse > 0
      refute sorted, "the term order of the pids must differ from their creation order"
    end)
  end
end
