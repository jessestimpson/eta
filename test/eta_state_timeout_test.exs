defmodule EtaStateTimeoutTest do
  @moduledoc """
  `:eta_statem` — `gen_statem`'s state time-outs on the virtual clock.

  The bar these tests hold it to:

  1. **The deadline is eta's.** It is in `eta_time`'s wheel, not the VM's, so the
     driver can see it and jump to it and a test can wait one out for free.
  2. **`gen_statem`'s cancellation rules, exactly.** A state change cancels; the
     four ways of not changing state do not. Getting either direction wrong is a
     bug that looks like the algorithm's.
  3. **Inert without a clock.** Every action goes to `gen_statem` untouched.

  Every firing test is also a test that the transform *prepends* its delivery
  clause: `:eta_state_timeout_sut` has no `info` clause at all, so a machine that
  saw the delivery message through its own callbacks would die of
  `function_clause` rather than time out.
  """
  use ExUnit.Case, async: false

  @time :eta_time
  @net :eta_net
  @sched :eta_sched
  @sut :eta_state_timeout_sut
  @members [:eta_elect_1, :eta_elect_2, :eta_elect_3]

  setup do
    on_exit(fn ->
      @net.stop()
      @time.stop()
    end)

    :ok
  end

  describe "with a virtual clock" do
    setup do
      :ok = @time.start(%{start_ms: 0})
      {:ok, pid} = @sut.start_link(self())
      on_exit(fn -> stop(pid) end)
      %{pid: pid}
    end

    test "the deadline is in eta's wheel, and waiting it out costs no real time", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 60_000, :election})

      assert @time.pending() == 1, "the deadline went to the VM's timer wheel, not eta's"
      refute_received {:fired, _, _}

      {micros, _} = :timer.tc(fn -> @time.advance(60_000) end)

      assert_receive {:fired, :a, :election}
      assert micros < 1_000_000, "a 60s state time-out took #{div(micros, 1_000)}ms"
    end

    test "a state change cancels it", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100, :election})
      :ok = @sut.drive(pid, {:next_state, :b})

      assert @time.pending() == 0, "the deadline outlived the state it belonged to"
      @time.advance(1_000)
      refute_received {:fired, _, _}
    end

    # The other half, and the half a leader election depends on: a follower
    # rearms on every heartbeat with a `keep_state`, so if any of these cancelled
    # it the machine would stop timing out entirely.
    for {op, label} <- [
          {:keep, "keep_state_and_data"},
          {:keep_data, "keep_state"},
          {:repeat, "repeat_state_and_data"},
          {:repeat_data, "repeat_state"},
          {{:next_state, :a}, "next_state to the same state"}
        ] do
      test "#{label} does not cancel it", %{pid: pid} do
        :ok = @sut.drive(pid, {:arm, 100, :election})
        :ok = @sut.drive(pid, unquote(Macro.escape(op)))

        assert @time.pending() == 1
        @time.advance(100)
        assert_receive {:fired, :a, :election}
      end
    end

    test "setting one replaces the one running", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100, :first})
      :ok = @sut.drive(pid, {:arm, 300, :second})

      assert @time.pending() == 1, "both deadlines are armed; there is only supposed to be one"

      @time.advance(100)
      refute_received {:fired, _, _}, "the replaced deadline fired anyway"

      @time.advance(200)
      assert_receive {:fired, :a, :second}
    end

    for {op, label} <- [{{:arm, :infinity, :x}, "infinity"}, {:cancel, "{state_timeout, cancel}"}] do
      test "#{label} cancels it", %{pid: pid} do
        :ok = @sut.drive(pid, {:arm, 100, :election})
        :ok = @sut.drive(pid, unquote(Macro.escape(op)))

        assert @time.pending() == 0
        @time.advance(1_000)
        refute_received {:fired, _, _}
      end
    end

    test "update changes the content and leaves the deadline alone", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100, :old})
      :ok = @sut.drive(pid, {:update, :new})

      @time.advance(99)
      refute_received {:fired, _, _}, "update restarted the clock instead of leaving it alone"

      @time.advance(1)
      assert_receive {:fired, :a, :new}
    end

    test "update with nothing running fires immediately, as gen_statem's does", %{pid: pid} do
      # Not a mistake being papered over: `gen_statem` documents this as a
      # time-out autostart with immediate expiry, "so there will be noise for
      # example if a generic time-out name was misspelled". Mirrored, not fixed.
      :ok = @sut.drive(pid, {:update, :noise})

      assert_receive {:fired, :a, :noise}
      assert @time.pending() == 0, "an immediate expiry went through the timer wheel"
    end

    test "a zero time-out never touches the wheel", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 0, :now})

      assert_received {:fired, :a, :now}
      assert @time.pending() == 0
    end

    test "a zero time-out is delivered after the events already queued", %{pid: pid} do
      # `gen_statem` delivers one when the event *queue* drains, not at the head
      # of it — so an event inserted in the same transition goes first. Handing
      # the zero back to gen_statem is what gets this right; substituting
      # `{next_event, state_timeout, _}` for it puts the time-out first.
      :ok = @sut.drive(pid, {:zero_then, :inserted})

      # Drained in mailbox order — `assert_received` is a selective receive and
      # would pass on either ordering, which is the whole question here.
      assert [{:inserted, :inserted}, {:fired, :a, :zero}] == drain()
    end

    test "a queued event that changes state cancels a zero time-out before it lands", %{pid: pid} do
      # The idiom this is really about: "do this next, unless I leave the state
      # before I get to it". A zero time-out is still cancellable while it waits,
      # because gen_statem re-checks its timer table before delivering — so an
      # inserted event that changes state means it never arrives.
      #
      # An inserted event cannot be cancelled, which is why substituting one is
      # not good enough: it would fire here.
      :ok = @sut.drive(pid, {:zero_then, {:goto, :b}})

      assert :b = :gen_statem.call(pid, :state)
      refute_received {:fired, _, _}
    end

    test "a real time-out replacing an undelivered zero leaves only one", %{pid: pid} do
      # The failure mode of letting gen_statem and eta each own a state time-out
      # without either knowing: the zero stays queued in gen_statem while eta
      # arms its own, and the machine times out twice for one time-out. The
      # replacement has to be forwarded so gen_statem cancels what it holds.
      :ok = @sut.drive(pid, {:zero_then, {:arm, 100, :replacement}})

      refute_received {:fired, _, _}, "the replaced zero time-out was delivered anyway"

      @time.advance(100)
      assert_receive {:fired, :a, :replacement}
      refute_receive {:fired, _, _}, 50, "the time-out fired twice for one arming"
    end

    test "an absolute deadline is a point on the virtual clock", %{pid: pid} do
      @time.advance(1_000)
      :ok = @sut.drive(pid, {:arm, 1_500, :absolute, [{:abs, true}]})

      @time.advance(499)
      refute_received {:fired, _, _}

      @time.advance(1)
      assert_receive {:fired, :a, :absolute}
    end

    test "an action that is not a list is read too", %{pid: pid} do
      # `Actions :: [action()] | action()`. A pass that only walked lists would
      # leave this one with gen_statem and on the real clock.
      :ok = @sut.drive(pid, {:bare, 100, :single})

      assert @time.pending() == 1
      @time.advance(100)
      assert_receive {:fired, :a, :single}
    end

    test "init/1 can arm one", %{pid: _} do
      {:ok, pid} = @sut.start_link(self(), [{:state_timeout, 100, :from_init}])
      on_exit(fn -> stop(pid) end)

      assert @time.pending() == 1
      @time.advance(100)
      assert_receive {:fired, :a, :from_init}
    end

    test "a deadline cancelled after it fired produces no event at all", %{pid: pid} do
      # The case the flush exists for, and the only one that needs the machine
      # held still to reach. `gen_statem` parks the ref of a timer it cancelled
      # too late and drops the message when it arrives, without running a
      # callback; `eta_time:disarm_self/2` takes it out of the mailbox instead.
      :ok = @sut.drive(pid, {:arm, 100, :election})

      # Suspended, so the state change is queued behind nothing and the fired
      # message lands behind it rather than being processed on arrival.
      :ok = :sys.suspend(pid)
      :ok = :gen_statem.cast(pid, {:next_state, :b})
      @time.advance(100)
      :ok = :sys.resume(pid)

      assert :b = :gen_statem.call(pid, :state)
      refute_received {:fired, _, _}, "a cancelled deadline was delivered as an event"
    end

    test "and costs the machine no event either", %{pid: pid} do
      # The reason the cancel flushes rather than relying on the bookkeeping.
      # Clearing the armed entry is already enough to stop the *content* being
      # delivered — `fire/1` finds nothing and keeps state — but the message
      # would still be received, and a received message is an event: a step in
      # the schedule, a line in the log, and once event time-outs are owned here,
      # something that would cancel one. `gen_statem` drops it without running a
      # callback, so this has to as well.
      #
      # Counted through `sys:statistics/2`, which is `gen_statem`'s own count of
      # the events it processed.
      :ok = @sut.drive(pid, {:arm, 100, :election})
      # Counting starts here, so the two events the arming itself cost are out.
      :ok = :sys.statistics(pid, true)

      :ok = :sys.suspend(pid)
      :ok = :gen_statem.cast(pid, {:next_state, :b})
      @time.advance(100)
      :ok = :sys.resume(pid)
      assert :b = :gen_statem.call(pid, :state)

      {:ok, stats} = :sys.statistics(pid, :get)

      # The cast that changed state, and the call that read it back. The
      # delivery message was taken out of the mailbox before gen_statem saw it.
      assert stats[:messages_in] == 2
    end

    test "the same race with no state change still fires", %{pid: pid} do
      # The control for the test above. Same ordering, same suspension, and the
      # only difference is that nothing cancels — so a flush that was too eager
      # would show up here as a time-out that went missing.
      :ok = @sut.drive(pid, {:arm, 100, :election})

      :ok = :sys.suspend(pid)
      :ok = :gen_statem.cast(pid, :keep)
      @time.advance(100)
      :ok = :sys.resume(pid)

      assert_receive {:fired, :a, :election}
    end
  end

  describe "generic time-outs" do
    setup do
      :ok = @time.start(%{start_ms: 0})
      {:ok, pid} = @sut.start_link(self())
      on_exit(fn -> stop(pid) end)
      {:ok, pid: pid}
    end

    test "fire on the virtual clock, as a {timeout, Name} event", %{pid: pid} do
      :ok = @sut.drive(pid, {:raw, {{:timeout, :tick}, 60_000, :beat}})
      assert @time.pending() == 1
      @time.advance(60_000)
      assert_receive {:generic, :tick, :a, :beat}
    end

    test "survive a state change", %{pid: pid} do
      :ok = @sut.drive(pid, {:raw, {{:timeout, :tick}, 100, :beat}})
      :ok = @sut.drive(pid, {:next_state, :b})
      @time.advance(100)
      assert_receive {:generic, :tick, :b, :beat}
    end

    test "are one per name: a second replaces the first, and others run alongside", %{pid: pid} do
      :ok = @sut.drive(pid, {:raw, {{:timeout, :tick}, 100, :first}})
      :ok = @sut.drive(pid, {:raw, {{:timeout, :tick}, 200, :second}})
      :ok = @sut.drive(pid, {:raw, {{:timeout, :other}, 150, :other}})
      :ok = @sut.drive(pid, {:arm, 120, :state})

      @time.advance(200)
      assert_receive {:fired, :a, :state}
      assert_receive {:generic, :other, :a, :other}
      assert_receive {:generic, :tick, :a, :second}
      refute_received {:generic, :tick, :a, :first}
    end

    test "cancel by name, with cancel or infinity", %{pid: pid} do
      :ok = @sut.drive(pid, {:raw, {{:timeout, :one}, 100, :x}})
      :ok = @sut.drive(pid, {:raw, {{:timeout, :two}, 100, :y}})
      :ok = @sut.drive(pid, {:raw, {{:timeout, :one}, :cancel}})
      :ok = @sut.drive(pid, {:raw, {{:timeout, :two}, :infinity, :y}})
      @time.advance(1_000)
      refute_received {:generic, _, _, _}
      assert @time.pending() == 0
    end

    test "update changes the content and keeps the deadline", %{pid: pid} do
      :ok = @sut.drive(pid, {:raw, {{:timeout, :tick}, 100, :old}})
      @time.advance(50)
      :ok = @sut.drive(pid, {:raw, {{:timeout, :tick}, :update, :new}})
      @time.advance(50)
      assert_receive {:generic, :tick, :a, :new}
    end
  end

  describe "the time-out kinds eta does not own" do
    @describetag :capture_log

    setup do
      :ok = @time.start(%{start_ms: 0})
      :ok
    end

    for {action, label} <- [
          {{:timeout, 100, :x}, "an event time-out"},
          {100, "a bare time as an action"}
        ] do
      test "#{label} raises rather than staying on the real clock" do
        {:ok, pid} = @sut.start_link(self())
        Process.unlink(pid)
        ref = Process.monitor(pid)

        :ok = :gen_statem.cast(pid, {:raw, unquote(Macro.escape(action))})

        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
        assert {{:eta_statem, {:unsupported_timeout, _, _}}, _} = reason
      end
    end
  end

  describe "with no clock" do
    test "every action goes to gen_statem untouched" do
      # The transform is on and eta is inert, which is the configuration the
      # ordinary test suite of a project using eta runs in. Real timers, real
      # semantics, and the kinds that raise above are ordinary here.
      {:ok, pid} = @sut.start_link(self())
      on_exit(fn -> stop(pid) end)

      :ok = @sut.drive(pid, {:arm, 10, :real})
      assert_receive {:fired, :a, :real}, 1_000

      :ok = @sut.drive(pid, {:raw, {:timeout, 10, :event}})
      refute_received {:fired, _, _}
    end
  end

  # ---------------------------------------------------------------------------
  # End to end
  # ---------------------------------------------------------------------------

  describe "a leader election driven entirely by state time-outs" do
    # `:eta_elect` is the evidence that the three pieces work together on
    # something that is not a fixture. Nothing in it sends a message on a timer
    # or reads a clock — every deadline it has is a `state_timeout` — so a
    # cluster that elects anybody at all has had all of arming, delivery and
    # cancellation go right, in `state_functions` mode.
    setup do
      # Without this the first run of a seed differs from the second, and the
      # cause is not the election. A member reaching a code path for the first
      # time blocks on `code_server` — a process the scheduler does not own — so
      # it looks unrunnable, the driver calls the system quiescent and advances
      # the clock, and the schedule diverges from the warm run's. `eta_run:run/2`
      # takes `preload` for exactly this; a test driving `eta_sched` by hand has
      # to ask for it.
      :ok = :eta_run.preload([])
      on_exit(&kill_members/0)
      :ok
    end

    test "elects exactly one leader, on no real time at all" do
      {sched, elapsed} = run_election(seed: 1)

      # Read while the scheduler still holds everything still, and out of band
      # through `eta_observe` — asking a suspended member would hang.
      leaders = :eta_elect.leaders(@members)
      clock = @time.now_ms()
      safety = :eta_elect.at_most_one_leader_per_term(@members)
      @sched.release(sched)

      assert safety == :ok
      assert [{_name, term}] = leaders, "expected one leader, got #{inspect(leaders)}"
      assert term >= 1

      # The clock moved, which is the proof the deadlines were eta's: nothing in
      # this system advances it except a state time-out coming due.
      assert clock >= 150, "the virtual clock never reached the first election period"
      assert elapsed < 5_000_000, "an election over #{clock}ms took #{div(elapsed, 1_000)}ms"
    end

    test "the leader keeps the term, because its heartbeats keep rearming" do
      # Liveness rather than safety, and it fails in both directions. A heartbeat
      # deadline that stopped rearming would let the followers elect somebody
      # else; a follower deadline that a `keep_state` wrongly cancelled would
      # stop the followers ever standing again.
      {sched, _} = run_election(seed: 7, steps: 4_000)

      leaders = :eta_elect.leaders(@members)
      clock = @time.now_ms()
      @sched.release(sched)

      assert [{_name, term}] = leaders
      assert clock > 1_000, "the run did not get far enough to be about stability"

      assert term <= 3,
             "the term reached #{term}, so leadership kept lapsing rather than being held"
    end

    test "one seed, one election" do
      {sched, _} = run_election(seed: 3)
      first = {:eta_elect.leaders(@members), @time.now_ms()}
      @sched.release(sched)
      kill_members()
      @time.stop()

      {sched2, _} = run_election(seed: 3)
      second = {:eta_elect.leaders(@members), @time.now_ms()}
      @sched.release(sched2)

      assert first == second
    end
  end

  describe "a planted bug that only a fault can reach" do
    # `:eta_elect` carries an optional bug: a member grants a vote it has
    # already given away. On a healthy network it does nothing, because two
    # members never reach the same term — the first to time out tells everyone
    # else, and a later candidate necessarily stands in a higher one. So there is
    # never a second vote to give.
    #
    # Cut one link and that stops being true, and the three tests below are the
    # case for fault injection written out: the fault alone is survived, the bug
    # alone is invisible, and only together do they break safety.
    @cut {:eta_elect_1, :eta_elect_2}

    setup do
      :ok = :eta_run.preload([])
      on_exit(&kill_members/0)
      :ok
    end

    test "two members reach one term, and a double vote gives them both a majority" do
      {sched, _} = run_election(seed: 1, steps: 600, net: true, bug: true, cut: @cut)

      leaders = :eta_elect.leaders(@members)
      verdict = :eta_elect.at_most_one_leader_per_term(@members)
      dropped = @net.stats()[:dropped]
      @sched.release(sched)

      # Non-vacuity: a run whose cut lost nothing tested a healthy network and
      # would report the same `ok` as one with no fault in it at all.
      assert dropped > 0, "the cut dropped nothing"

      assert {:violation, {:split_brain, [{term, split}]}} = verdict
      assert length(split) == 2
      assert length(leaders) == 2
      assert Enum.all?(leaders, fn {_name, t} -> t == term end)
    end

    test "the same fault without the bug elects one leader" do
      # The control that matters most. Without it the test above only says
      # "cutting a link breaks this election", which would be a finding about
      # the algorithm rather than about the line that was changed.
      {sched, _} = run_election(seed: 1, steps: 600, net: true, bug: false, cut: @cut)

      leaders = :eta_elect.leaders(@members)
      verdict = :eta_elect.at_most_one_leader_per_term(@members)
      dropped = @net.stats()[:dropped]
      @sched.release(sched)

      assert dropped > 0, "the cut dropped nothing"
      assert verdict == :ok
      assert [{_name, _term}] = leaders
    end

    test "the same bug without the fault elects one leader" do
      # And the reason it is worth planting: on a network that loses nothing,
      # the broken line is never reached with a vote left to give.
      {sched, _} = run_election(seed: 1, steps: 600, net: true, bug: true)

      leaders = :eta_elect.leaders(@members)
      verdict = :eta_elect.at_most_one_leader_per_term(@members)
      @sched.release(sched)

      assert verdict == :ok
      assert [{_name, _term}] = leaders
    end
  end

  # Starts the clock, then a cluster, then puts the cluster on a schedule and
  # runs it. The order is the point: each member arms its first election deadline
  # in `init/1`, and a clock that was not running yet would have left it with
  # `gen_statem` and on the wall clock. It is also why nothing happens between
  # starting the members and running them — the deadlines are virtual, so only
  # the driver can bring them due.
  defp run_election(opts) do
    seed = Keyword.fetch!(opts, :seed)
    steps = Keyword.get(opts, :steps, 400)
    :ok = @time.start(%{start_ms: 0, seed: seed})
    if opts[:net], do: :ok = @net.start(%{seed: seed})

    pids =
      for {name, i} <- Enum.with_index(@members) do
        {:ok, pid} =
          :eta_elect.start_link(%{
            name: name,
            members: @members,
            # Staggered rather than randomised. Equal periods under a virtual
            # clock are not an unlikely tie, they are a permanent one.
            election_ms: 150 + i * 40,
            heartbeat_ms: 50,
            bug: Keyword.get(opts, :bug, false)
          })

        Process.unlink(pid)
        pid
      end

    # After the members exist, because a cut is between two pids.
    case opts[:cut] do
      nil -> :ok
      {from, to} -> :ok = @net.cut(from, to)
    end

    sched = @sched.register(@sched.new(%{seed: seed}), pids)

    {elapsed, _} =
      :timer.tc(fn -> @sched.run(sched, steps, fn -> :eta_time.advance_to_next() end) end)

    {sched, elapsed}
  end

  defp kill_members do
    for name <- @members, pid = Process.whereis(name) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  # Everything in the mailbox, in arrival order.
  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stop(pid) do
    if Process.alive?(pid), do: @sut.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
