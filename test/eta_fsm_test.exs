defmodule EtaFsmTest do
  @moduledoc """
  `:eta_fsm` — `gen_fsm`'s time-outs on the virtual clock.

  The bar, the same one `:eta_statem` is held to:

  1. **The deadline is eta's.** In `eta_time`'s wheel, not the VM's.
  2. **`gen_fsm`'s cancellation rule, exactly.** Any message cancels; a new
     time-out replaces; a state function that reaches another one directly keeps
     what the inner one armed.
  3. **Inert without a clock.** Every return goes to `gen_fsm` untouched.
  """
  use ExUnit.Case, async: false

  @time :eta_time
  @sut :eta_fsm_sut

  setup do
    on_exit(fn -> @time.stop() end)
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
      :ok = @sut.drive(pid, {:arm, 60_000})

      assert @time.pending() == 1, "the deadline went to the VM's timer wheel, not eta's"
      refute_received {:fired, _}

      {micros, _} = :timer.tc(fn -> @time.advance(60_000) end)

      assert_receive {:fired, :a}
      assert micros < 1_000_000, "a 60s gen_fsm time-out took #{div(micros, 1_000)}ms"
    end

    test "any message cancels it", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100})
      :ok = @sut.drive(pid, :noop)

      assert @time.pending() == 0, "the deadline outlived the message that cancelled it"
      @time.advance(1_000)
      refute_received {:fired, _}
    end

    test "a new time-out replaces the pending one", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100})
      :ok = @sut.drive(pid, {:arm, 500})

      assert @time.pending() == 1
      @time.advance(100)
      refute_received {:fired, _}
      @time.advance(400)
      assert_receive {:fired, :a}
    end

    test "the reply form arms it too", %{pid: pid} do
      :ok = @sut.sync_drive(pid, {:arm_reply, 100})

      assert @time.pending() == 1
      @time.advance(100)
      assert_receive {:fired, :a}
    end

    test "a reply without a time-out cancels, as any message does", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100})
      :ok = @sut.sync_drive(pid, :noop_reply)

      assert @time.pending() == 0
    end

    test "it fires in the state the machine is in", %{pid: pid} do
      :ok = @sut.drive(pid, {:next_state, :b})
      :ok = @sut.sync_drive(pid, {:arm_reply, 100})

      @time.advance(100)
      assert_receive {:fired, :b}
    end

    test "a state function reached directly keeps the time-out it armed", %{pid: pid} do
      # `a(chain, D)` returns `b(enter, D)`, whose return carries 250. The
      # outer return passes through the wrapper too, without a time-out — and
      # must not read that as "a message was handled, cancel".
      :ok = @sut.drive(pid, :chain)

      assert @time.pending() == 1, "the outer return cancelled the inner arm"
      # Read through `sys` — a synchronous event here would itself cancel it.
      assert {:b, _} = :sys.get_state(pid)
      @time.advance(250)
      assert_receive {:fired, :b}
    end

    test "infinity cancels and arms nothing", %{pid: pid} do
      :ok = @sut.drive(pid, {:arm, 100})
      :ok = @sut.drive(pid, {:arm, :infinity})

      assert @time.pending() == 0
    end

    test "zero fires at once when the mailbox is empty, without the clock moving", %{pid: pid} do
      # Armed from a synchronous event: the test is blocked on the reply while
      # the return is read, so the mailbox is empty when the zero is applied.
      :ok = @sut.sync_drive(pid, {:arm_reply, 0})

      assert_receive {:fired, :a}
      assert @time.pending() == 0
      assert @time.now_ms() == 0
    end

    test "a cancelled time-out produces no event, even if it had just fired", %{pid: pid} do
      # Advance to the deadline first, so the message is already in the
      # mailbox when the cancelling message is processed. The flush in
      # `eta_time:disarm_self/2` is what keeps it from arriving as `timeout`.
      :ok = @sut.drive(pid, {:arm, 100})
      send(pid, {:"$gen_event", :noop})
      @time.advance(100)

      :ok = @sut.drive(pid, :noop)
      refute_received {:fired, _}
    end

    test "send_event_after/2 and start_timer/2 are on the virtual clock", %{pid: pid} do
      :ok = @sut.drive(pid, {:later, 300, :ping})
      :ok = @sut.drive(pid, {:timer, 500, :tick})

      assert @time.pending() == 2
      @time.advance(300)
      assert_receive {:event, :a, :ping}
      @time.advance(200)
      assert_receive {:timer, :a, :tick}
    end

    test "cancel_timer/1 answers as gen_fsm's does", %{pid: pid} do
      :ok = @sut.drive(pid, {:timer, 500, :tick})
      @time.advance(100)
      :ok = @sut.drive(pid, :cancel_timer)
      assert_receive {:cancelled, 400}

      :ok = @sut.drive(pid, {:timer, 100, :tock})
      @time.advance(100)
      :ok = @sut.drive(pid, :cancel_timer)
      # Fired and delivered before the cancel event was reached — `false`, as
      # `gen_fsm:cancel_timer/1` answers for a timer whose message is gone.
      assert_receive {:timer, :a, :tock}
      assert_receive {:cancelled, false}
    end

    test "hibernate is refused rather than left on the real clock", %{pid: pid} do
      Process.flag(:trap_exit, true)
      ref = Process.monitor(pid)
      :ok = :gen_fsm.send_event(pid, {:arm, :hibernate})

      assert_receive {:DOWN, ^ref, :process, ^pid,
                      {{:eta_fsm, {:unsupported_timeout, :hibernate, _}}, _}}
    end
  end

  describe "init/1" do
    setup do
      :ok = @time.start(%{start_ms: 0})
      :ok
    end

    test "a time-out set from init/1 is on the virtual clock" do
      {:ok, pid} = @sut.start_link(self(), 100)
      on_exit(fn -> stop(pid) end)

      assert @time.pending() == 1
      @time.advance(100)
      assert_receive {:fired, :a}
    end
  end

  describe "with no clock" do
    test "every return goes to gen_fsm untouched" do
      {:ok, pid} = @sut.start_link(self())
      on_exit(fn -> stop(pid) end)

      :ok = @sut.sync_drive(pid, {:arm_reply, 20})
      refute @time.running()
      assert_receive {:fired, :a}, 1_000
    end
  end

  defp stop(pid) do
    if Process.alive?(pid), do: @sut.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
