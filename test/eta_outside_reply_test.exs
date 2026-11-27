defmodule EtaOutsideReplyTest do
  @moduledoc """
  A step that ends as a block while a process outside the schedule can still
  wake the process, and a step that ends in a time-out.

  The process asks `file_server_2`, which the scheduler does not own, and
  blocks in `gen:do_call/4`. When the answer arrives while the scheduler
  confirms the block, the process runs on after its step ended. Before the
  check in `:eta_sched`, the step then ended as a block, and nothing stepped
  the process again. Measured on Erlang/OTP 29 with `+SDio 1`, in this many of
  500 trials:

  | Build | 1 scheduler | 4 schedulers |
  |---|---|---|
  | without the change | 57 | 312 |
  | without the check, with the change to time-outs | 80 | 391 |
  | with the change | 0 | 0 |

  A step that ended in a time-out left the process idle when its queue was
  empty, so it was not runnable either. Without that part of the change, the
  first test fails in 109 of 500 trials with 1 scheduler.

  `filelib:file_size/1` and `filelib:last_modified/1` ask `file_server_2`
  through `file:read_file_info/1`. `:eta_transform` points them at `:eta_file`.
  """
  use ExUnit.Case, async: false

  # The system under test is Erlang: test/support/eta_outside_reply_sut.erl
  @sut :eta_outside_reply_sut

  defp in_peer(schedulers, fun) do
    paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
    args = [~c"+S", Integer.to_charlist(schedulers), ~c"+SDio", ~c"1"] ++ paths
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io, args: args})
    # The scheduler logs a warning for each step that it counts in `ran_on` or
    # in `timeouts`. The tests assert the counts, so the peer does not print
    # the warnings.
    :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :none])

    try do
      fun.(peer)
    after
      :peer.stop(peer)
    end
  end

  for schedulers <- [1, 4] do
    test "a process woken from outside the schedule after its block stays runnable, #{schedulers} schedulers" do
      in_peer(unquote(schedulers), fn peer ->
        assert :peer.call(peer, @sut, :stranded, [500], 300_000) == 0
      end)
    end
  end

  test "the scheduler counts a process woken from outside the schedule in ran_on" do
    # With 4 schedulers the wake-up arrives after the block in more than half
    # of the trials, so 500 trials have at least 1.
    in_peer(4, fn peer ->
      assert {0, ran_on} = :peer.call(peer, @sut, :counted, [500], 300_000)
      assert ran_on > 0
    end)
  end

  for schedulers <- [1, 4] do
    test "a process that nothing outside the schedule wakes has a ran_on of 0, #{schedulers} schedulers" do
      # The process blocks in a plain receive, in erlang:hibernate/3 and in
      # eta_sched:yield/0, and the test reads the blocked process after each
      # step. The VM then schedules the process in and out for the signal.
      in_peer(unquote(schedulers), fn peer ->
        assert :peer.call(peer, @sut, :quiet, [600], 300_000) == {0, 0}
      end)
    end
  end

  test "audit/1 reports a ran_on above 0" do
    result = %{
      modules_loaded: [],
      sched: %{adopted_late: 0, timeouts: 0, ran_on: 2, cold_code: []}
    }

    assert :eta_run.audit(result) == {:suspect, [ran_on: 2]}
  end

  test "a process suspended by a step time-out stays runnable with an empty queue" do
    in_peer(1, fn peer ->
      assert :peer.call(peer, @sut, :timed_out, [], 60_000) == {1, true}
    end)
  end

  test "filelib:file_size/1 and filelib:last_modified/1 are done in the calling process" do
    source = """
    -module(eta_outside_reply_calls).
    f(N) -> {filelib:file_size(N), filelib:last_modified(N)}.
    """

    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn
          {:dot, _} = t, acc -> {:cont, Enum.reverse([t | acc]), []}
          t, acc -> {:cont, [t | acc]}
        end,
        fn acc -> {:cont, acc} end
      )
      |> Enum.map(fn form ->
        {:ok, f} = :erl_parse.parse_form(form)
        f
      end)

    [{:function, _, :f, 1, [{:clause, _, _, _, [{:tuple, _, calls}]}]}] =
      for {:function, _, :f, 1, _} = f <- :eta_transform.parse_transform(forms, []), do: f

    assert [{:eta_file, :file_size}, {:eta_file, :last_modified}] =
             for({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, _} <- calls, do: {m, f})
  end
end
