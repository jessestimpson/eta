defmodule EtaNetTest do
  @moduledoc """
  `:eta_net` — the simulated network.

  The bar these tests hold it to:

  1. **Inert unless started.** A module built with the transform behaves exactly
     as it did before, and so does a run that starts no network.
  2. **Only faults real Erlang can produce.** Loss and delay, never reordering
     within an ordered pair.
  3. **Seeded.** The same seed makes the same decisions about the same messages.
  """
  use ExUnit.Case, async: false

  @net :eta_net
  @time :eta_time
  @sched :eta_sched

  setup do
    on_exit(fn ->
      @net.stop()
      @time.stop()
    end)

    :ok
  end

  # A process that parks every message it receives where a test can read them.
  defp sink do
    me = self()
    spawn(fn -> sink_loop(me) end)
  end

  defp sink_loop(owner) do
    receive do
      {:__drain__, ref} ->
        send(owner, {ref, :lists.reverse(Process.get(:msgs, []))})
        sink_loop(owner)

      # Drain and reset, for a test that reads the same sink at several points in
      # a sequence of link events and wants each read to be that step alone.
      {:__take__, ref} ->
        send(owner, {ref, :lists.reverse(Process.get(:msgs, []))})
        Process.put(:msgs, [])
        sink_loop(owner)

      {:__send__, dest, msg} ->
        :eta_net.send(dest, msg)
        sink_loop(owner)

      # Monitors have to be created *by* the watching process, so a test that
      # wants one across a link has to ask a sink to make it.
      {:__monitor__, reply_to, ref, dest} ->
        send(reply_to, {ref, :eta_net.monitor(:process, dest)})
        sink_loop(owner)

      {:__demonitor__, reply_to, ref, mref} ->
        send(reply_to, {ref, :eta_net.demonitor(mref, [:flush])})
        sink_loop(owner)

      {:__call__, reply_to, ref, dest, msg} ->
        result =
          try do
            {:ok, :eta_net_echo.call(dest, msg)}
          rescue
            e in ErlangError -> {:error, e.original}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(reply_to, {ref, result})
        sink_loop(owner)

      msg ->
        Process.put(:msgs, [msg | Process.get(:msgs, [])])
        sink_loop(owner)
    end
  end

  # The echo is linked to the test process, so it is usually already gone by the
  # time cleanup runs. Racing that is not worth a failed test.
  defp stop_echo(name) do
    quietly(fn -> :eta_net_echo.stop(name) end)
  end

  # Same race, for anything else a cleanup shuts down. `catch_exit/1` is the
  # wrong tool here even though it reads right: it *requires* an exit, so it
  # fails on the runs where the cleanup wins and shuts the thing down cleanly.
  defp quietly(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  # Send *from* a sink, so the sender is a process the topology knows about. A
  # send from the test process is a send from nowhere, and nowhere is not on any
  # link.
  #
  # Draining the sender afterwards is the sync: its loop is sequential, so an
  # answer to the drain proves the forward already happened.
  defp send_from(from, dest, msg) do
    send(from, {:__send__, dest, msg})
    _ = drained(from)
    :ok
  end

  # Runs `fun` in a fresh process and returns `{result, calls}`, where `calls`
  # is every call that process made to the function `mfa` names, as argument
  # lists. Call tracing rather than sampling, so "it did not ask" is an
  # observation and not the absence of one.
  defp calls_to({m, f, a} = mfa, fun) do
    me = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          :go -> send(me, {ref, fun.()})
        end
      end)

    _ = :erlang.trace_pattern(mfa, true, [:global])
    1 = :erlang.trace(pid, true, [:call])
    send(pid, :go)

    result =
      receive do
        {^ref, result} -> result
      after
        2_000 -> flunk("no answer from the traced process")
      end

    delivered = :erlang.trace_delivered(pid)

    receive do
      {:trace_delivered, ^pid, ^delivered} -> :ok
    after
      2_000 -> flunk("trace was not delivered")
    end

    _ = :erlang.trace_pattern(mfa, false, [:global])
    {result, traced_calls(pid, m, f, a, [])}
  end

  defp traced_calls(pid, m, f, a, acc) do
    receive do
      {:trace, ^pid, :call, {^m, ^f, args}} when length(args) == a ->
        traced_calls(pid, m, f, a, [args | acc])
    after
      0 -> :lists.reverse(acc)
    end
  end

  # A process `spawner` spawned, which nothing has placed.
  defp child_of(spawner) do
    me = self()
    send(spawner, {:__spawn__, me})

    receive do
      {:__spawned__, child} -> child
    after
      2_000 -> flunk("no child from the spawner")
    end
  end

  defp spawner do
    spawn(fn -> spawner_loop() end)
  end

  defp spawner_loop do
    receive do
      {:__spawn__, to} ->
        send(to, {:__spawned__, spawn(fn -> Process.sleep(:infinity) end)})
        spawner_loop()
    end
  end

  # Issue a call *from* a placed process, and report what happened. The refusal is
  # an `error/1` raised in the caller, so it has to be caught where it is raised.
  defp call_from(from, dest, msg) do
    ref = make_ref()
    send(from, {:__call__, self(), ref, dest, msg})

    receive do
      {^ref, result} -> result
    after
      2_000 -> flunk("no answer from the calling sink")
    end
  end

  # A call the test does not wait for, so the clock can be advanced while the
  # caller is still blocked in it.
  defp call_async(from, dest, msg) do
    ref = make_ref()
    send(from, {:__call__, self(), ref, dest, msg})
    ref
  end

  defp await_call(ref) do
    receive do
      {^ref, result} -> result
    after
      2_000 -> flunk("the call never finished")
    end
  end

  defp stop_plain(name) do
    :eta_net_plain.stop(name)
  catch
    :exit, _ -> :ok
  end

  # Ask a sink to monitor something, and hand back the ref it got.
  defp monitor_from(watcher, target) do
    ref = make_ref()
    send(watcher, {:__monitor__, self(), ref, target})

    receive do
      {^ref, mref} -> mref
    after
      1_000 -> flunk("sink never monitored")
    end
  end

  defp demonitor_from(watcher, mref) do
    ref = make_ref()
    send(watcher, {:__demonitor__, self(), ref, mref})

    receive do
      {^ref, result} -> result
    after
      1_000 -> flunk("sink never demonitored")
    end
  end

  defp drained(pid) do
    ref = make_ref()
    send(pid, {:__drain__, ref})

    receive do
      {^ref, msgs} -> msgs
    after
      1_000 -> flunk("sink never answered")
    end
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never came true")
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end

  # A call arms its timeout in the *caller*, so "the call is outstanding" is a
  # condition to wait for rather than a span to sleep through. Sleeping a fixed
  # 20ms and advancing races it: arm after the advance and the clock has already
  # passed the deadline, so nothing fires and the test fails 2s later in
  # `await_call` — a scheduling hiccup reported as a broken timeout.
  #
  # Exhausting the tries returns rather than flunking, leaving the assertion
  # that follows to report in its own terms.
  defp await_armed(n \\ 1, tries \\ 400) do
    cond do
      :eta_time.pending() >= n -> :ok
      tries == 0 -> :ok
      true -> Process.sleep(5) && await_armed(n, tries - 1)
    end
  end

  # The sink's messages once at least `n` have arrived. `drained/1` reads
  # without clearing, so this polls it rather than accumulating. For an
  # assertion about messages another process sends, the count is the condition
  # and the elapsed time is not; returning early on exhausted tries leaves the
  # assertion to report what actually arrived.
  defp drained_at_least(pid, n, tries \\ 400) do
    msgs = drained(pid)

    cond do
      length(msgs) >= n -> msgs
      tries == 0 -> msgs
      true -> Process.sleep(5) && drained_at_least(pid, n, tries - 1)
    end
  end

  defp taken(pid) do
    ref = make_ref()
    send(pid, {:__take__, ref})

    receive do
      {^ref, msgs} -> msgs
    after
      1_000 -> flunk("sink never answered")
    end
  end

  # ---------------------------------------------------------------------------
  # Inertness
  # ---------------------------------------------------------------------------

  describe "with no network running" do
    test "send/2 delivers and returns the message, exactly as `!` does" do
      s = sink()
      assert @net.send(s, {:hello, 1}) == {:hello, 1}
      assert drained(s) == [{:hello, 1}]
    end

    test "running/0 is false and nothing is counted" do
      refute @net.running()
    end

    test "cast/2 and reply/2 fall through to gen_server" do
      {:ok, _} = :eta_net_echo.start_link(:inert_echo)
      on_exit(fn -> stop_echo(:inert_echo) end)

      s = sink()
      assert @net.cast(:inert_echo, {:forward, s, :through}) == :ok
      assert :eta_net_echo.call(:inert_echo, {:echo, 7}) == {:echoed, 7}
      assert drained_at_least(s, 1) == [:through]
    end

    test "a cast to a name nobody has registered does not raise" do
      assert @net.cast(:nobody_at_all, :msg) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The transform actually points a module here
  # ---------------------------------------------------------------------------

  describe "eta_transform's network pass" do
    setup do
      :ok = @net.start(%{seed: 1})
      {:ok, pid} = :eta_net_echo.start_link(:pass_echo)
      on_exit(fn -> stop_echo(:pass_echo) end)

      # The test process and the echo share a node, so the calls below are local
      # API calls rather than network round trips and `eta_net:call/3` lets them
      # through. Their replies are still *routed* — they just cannot be faulted,
      # which is the point: this describe is about the rewrite reaching them.
      :ok = @net.place(:here, [self(), pid])
      :ok
    end

    test "routes `!`, erlang:send/2, gen_server:cast/2 and gen_server:reply/2" do
      s = sink()

      :eta_net_echo.bang(s, :from_bang)
      :eta_net_echo.qualified(s, :from_qualified)
      :eta_net_echo.cast(:pass_echo, {:forward, s, :from_cast})
      assert :eta_net_echo.call(:pass_echo, {:echo, 9}) == {:echoed, 9}

      assert Enum.sort(drained_at_least(s, 3)) == [:from_bang, :from_cast, :from_qualified]

      # bang + qualified + the echo's forward + the reply. The cast itself is sent
      # by the test process, which is not transformed, so it does not count.
      assert %{delivered: n} = @net.stats()
      assert n >= 4, "expected every rewritten send to be routed, got #{n}"
    end

    test "a routed gen_server:reply still satisfies the caller's selective receive" do
      # The reply is addressed to the caller's pid rather than the alias in the
      # tag. This is the check that OTP's call machinery does not mind.
      for i <- 1..5 do
        assert :eta_net_echo.call(:pass_echo, {:echo, i}) == {:echoed, i}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Synchronous calls
  # ---------------------------------------------------------------------------

  describe "a call across a link" do
    setup do
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.start(%{seed: 1})
      {:ok, pid} = :eta_net_echo.start_link(:call_echo)
      on_exit(fn -> stop_echo(:call_echo) end)

      caller = sink()
      :ok = @net.place(:a, [caller])
      :ok = @net.place(:b, [pid])
      %{pid: pid, caller: caller}
    end

    test "works, with both legs on the network", %{caller: caller} do
      # The request is routed by `eta_net:call/3`; the reply is routed because the
      # transform rewrote the callee's `{reply, R, S}` into `eta_net:reply/2`.
      assert {:ok, {:echoed, 1}} = call_from(caller, :call_echo, {:echo, 1})

      # Two crossings, not one. A run that could only fault the request would be
      # covering half the channel.
      assert %{delivered: n} = @net.stats()
      assert n >= 2, "expected request and reply to both be routed, got #{n}"
    end

    test "a lost reply times out the caller, though the work happened", %{caller: caller} do
      # The asymmetric fault that actually bites, and the reason routing only the
      # request would have been pointless: the server did the work and answered,
      # and the caller never learned it.
      :ok = @net.set_policy(%{drop_p: 1.0, scope: {:tags, [:"$gen_reply"]}})

      task = call_async(caller, :call_echo, {:echo, 2})
      # Nothing runnable will ever satisfy the receive, so only the clock can end
      # it — and it is a virtual clock, so this costs nothing.
      await_armed()
      @time.advance(5_000)

      assert {:exit, {:timeout, _}} = await_call(task)
      assert %{dropped: 1} = @net.stats()
    end

    test "a partition ends an outstanding call in nodedown, as distribution does", %{
      caller: caller
    } do
      # The reply is held on the wire, so the call is outstanding when the link
      # goes. The caller's own monitor is what fires: `gen:call/4` turns a
      # `noconnection` DOWN into `{nodedown, Node}`, and so does this.
      :ok = @net.set_policy(%{drop_p: 1.0, scope: {:tags, [:"$gen_reply"]}})

      task = call_async(caller, :call_echo, {:echo, 5})
      await_armed()
      :ok = @net.partition(:a, :b)

      assert {:exit, {{:nodedown, :b}, _}} = await_call(task)
      assert @time.now_ms() == 0, "the call waited for its timeout rather than the link"
    end

    test "a call to a name nothing holds on a simulated node is noproc", %{caller: caller} do
      # The server died with its node, say. Real distribution is not consulted.
      assert {:exit, {:noproc, _}} = call_from(caller, {:nobody_here, :b}, {:echo, 7})
    end

    test "a call into a severed link fails at once", %{caller: caller} do
      :ok = @net.partition(:a, :b)

      assert {:exit, {{:nodedown, :b}, _}} = call_from(caller, :call_echo, {:echo, 6})
      assert %{delivered: 0} = @net.stats()
    end

    test "a lost request times out the caller too", %{caller: caller} do
      :ok = @net.set_policy(%{drop_p: 1.0, scope: {:tags, [:echo]}})

      task = call_async(caller, :call_echo, {:echo, 3})
      await_armed()
      @time.advance(5_000)

      assert {:exit, {:timeout, _}} = await_call(task)
    end

    test "the timeout is virtual, so waiting one out costs no real time", %{caller: caller} do
      :ok = @net.set_policy(%{drop_p: 1.0, scope: {:tags, [:echo]}})

      {micros, result} =
        :timer.tc(fn ->
          task = call_async(caller, :call_echo, {:echo, 4})
          await_armed()
          @time.advance(5_000)
          await_call(task)
        end)

      assert {:exit, {:timeout, _}} = result
      assert micros < 1_000_000, "a 5s virtual timeout took #{div(micros, 1_000)}ms"
    end

    test "a reply that comes around the network is detected", %{caller: caller} do
      # `eta_net_plain` has no transform, so `gen_server` answers it through
      # `gen:reply/2` — a raw send from inside OTP. The call succeeds; what has
      # failed is the fault model, which is silently missing one direction.
      {:ok, plain} = :eta_net_plain.start_link(:plain_echo)
      on_exit(fn -> stop_plain(:plain_echo) end)
      :ok = @net.place(:b, [plain])

      assert {:error, {:eta_net, {:unrouted_reply, _, :echo, _}}} =
               call_from(caller, :plain_echo, {:echo, 5})
    end

    test "a dead callee is an exit, not a hang", %{caller: caller, pid: pid} do
      # Unlink first: the echo is started with start_link from the test process.
      Process.unlink(pid)
      Process.exit(pid, :kill)
      wait_until(fn -> not Process.alive?(pid) end)

      assert {:exit, {:noproc, _}} = call_from(caller, :call_echo, {:echo, 6})
    end

    test "a reply that loses the race to the timeout is dropped", %{caller: caller} do
      # Outside a simulation `gen:call/4` waits on an alias and deactivates it on
      # timeout, so an answer that arrives too late never reaches the caller.
      # `reply/2` routes to the caller's *pid*, because the network places and
      # faults pids, so that protection has to be rebuilt here.
      #
      # Without it the late reply lands as a `{Tag, Reply}` nothing will ever
      # match — for a gen_server caller, an `handle_info` clause it never
      # expected, and a crash the simulation manufactured rather than found.
      task = call_async(caller, :call_echo, {:defer, :k})
      await_armed()
      @time.advance(5_000)
      assert {:exit, {:timeout, _}} = await_call(task)

      # Anything parked before the answer is not what this is about.
      _ = drained(caller)

      # Sent from the caller itself, so the channel's ordering clamp puts it
      # ahead of the sync call below, and a returned sync call therefore proves
      # the echo has already answered the deferred one.
      send_from(caller, :call_echo, {:answer, :k, :too_late})
      assert {:ok, {:echoed, :sync}} = call_from(caller, :call_echo, {:echo, :sync})

      assert drained(caller) == [],
             "a reply the caller had already given up on reached its mailbox"
    end
  end

  describe "a call with a clock but no network" do
    setup do
      :ok = @time.start(%{start_ms: 0})
      :ok
    end

    test "keeps its timeout on the virtual clock" do
      # The default run configuration — transform on, scheduler and clock up,
      # `net => false`. This used to take OTP's own `receive ... after`, so every
      # call in an ordinary run counted down real milliseconds while the driver
      # did other work, and when it fired was decided by machine load rather than
      # by the seed. Nothing reported it.
      callee = sink()
      me = self()
      ref = make_ref()

      spawn(fn ->
        result =
          try do
            {:ok, :eta_net_echo.call(callee, :never_answered)}
          catch
            :exit, reason -> {:exit, reason}
          end

        send(me, {ref, result})
      end)

      await_armed()

      # The deadline is in eta's wheel rather than the VM's, which is the claim.
      assert @time.pending() == 1
      refute_received {^ref, _}

      # Five virtual seconds, and no real ones.
      {micros, _} = :timer.tc(fn -> @time.advance(5_000) end)

      assert_receive {^ref, {:exit, {:timeout, _}}}, 1_000
      assert micros < 1_000_000, "a 5s virtual timeout took #{div(micros, 1_000)}ms"
    end

    test "answers normally, and arms nothing it does not need" do
      {:ok, _} = :eta_net_echo.start_link(:nonet_echo)
      on_exit(fn -> stop_echo(:nonet_echo) end)

      assert :eta_net_echo.call(:nonet_echo, {:echo, 1}) == {:echoed, 1}
      assert @time.pending() == 0, "the deadline outlived the call it belonged to"
    end

    test "falls back to a real timeout for a caller the scheduler is not stepping" do
      # `eta_run` advances the clock only to deadlines owned by a process it can
      # step and treats every other one as a stray, so a virtual deadline armed
      # here would be a deadline nothing ever reaches. The test process stands in
      # for the driver, or for a harness `execute/2` that calls instead of
      # spawning. Nondeterminism is bad; a run with no way to end is worse.
      callee = sink()
      sched = @sched.new(%{seed: 1})

      {micros, result} =
        :timer.tc(fn ->
          try do
            {:ok, :eta_net_echo.call(callee, :never_answered, 150)}
          catch
            :exit, reason -> {:exit, reason}
          end
        end)

      pending = @time.pending()
      @sched.release(sched)

      assert {:exit, {:timeout, _}} = result
      assert micros >= 150_000, "the wait did not happen on the real clock"
      assert pending == 0, "a deadline nothing could reach was armed anyway"
    end
  end

  describe "functions eta_net does not implement" do
    test "raise while a network is running, naming the function" do
      :ok = @net.start(%{seed: 1})

      result =
        try do
          {:ok, :eta_net_echo.broadcast(:nobody, :msg)}
        rescue
          e in ErlangError -> {:error, e.original}
        end

      assert {:error, {:eta_net, {:unsupported, {:gen_server, :abcast, 2}, _}}} = result
    end

    test "pass straight through with no network" do
      # A module holding one of these on a path no simulation reaches still builds
      # and still behaves normally outside a run.
      assert :eta_net_echo.broadcast(:nobody, :msg) == :abcast
    end
  end

  describe "a call with no network" do
    test "is an ordinary gen_server:call" do
      {:ok, _} = :eta_net_echo.start_link(:bare_echo)
      on_exit(fn -> stop_echo(:bare_echo) end)

      assert :eta_net_echo.call(:bare_echo, {:echo, 7}) == {:echoed, 7}
    end
  end

  # ---------------------------------------------------------------------------
  # Loss
  # ---------------------------------------------------------------------------

  describe "dropping" do
    test "drop_p 1.0 loses everything, and the counter says so" do
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      s = sink()

      for i <- 1..10, do: @net.send(s, {:m, i})

      assert drained(s) == []
      assert %{dropped: 10, delivered: 0} = @net.stats()
    end

    test "drop_p 0.0 is exactly a perfect network" do
      :ok = @net.start(%{seed: 1})
      s = sink()

      for i <- 1..10, do: @net.send(s, {:m, i})

      assert drained(s) == for(i <- 1..10, do: {:m, i})
      assert %{dropped: 0, delivered: 10} = @net.stats()
    end

    test "a partial drop rate loses some and keeps order among the survivors" do
      :ok = @net.start(%{seed: 3, policy: %{drop_p: 0.5}})
      s = sink()

      for i <- 1..40, do: @net.send(s, {:m, i})

      got = drained(s)
      assert got != [], "seed dropped everything; pick another"
      assert length(got) < 40, "seed dropped nothing; pick another"

      indexes = for {:m, i} <- got, do: i
      assert indexes == Enum.sort(indexes), "the network reordered an ordered pair"
    end

    test "drop_matching/5 skips K of one tag and drops the next, leaving others alone" do
      # The fault that severs a channel part-way through one batch: a raw message
      # count cannot say it, because the batch is interleaved with other traffic.
      :ok = @net.start(%{seed: 1})
      s = sink()

      :ok = @net.drop_matching(self(), s, :batch, 1, 2)

      @net.send(s, {:batch, 1})
      @net.send(s, {:ack, 1})
      @net.send(s, {:batch, 2})
      @net.send(s, {:batch, 3})
      @net.send(s, {:ack, 2})
      @net.send(s, {:batch, 4})

      assert drained(s) == [{:batch, 1}, {:ack, 1}, {:ack, 2}, {:batch, 4}]
    end

    test "drop_next/3 loses exactly the next K, then stops" do
      :ok = @net.start(%{seed: 1})
      s = sink()

      :ok = @net.drop_next(self(), s, 2)
      for i <- 1..5, do: @net.send(s, {:m, i})

      assert drained(s) == [{:m, 3}, {:m, 4}, {:m, 5}]
    end
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------

  describe "scope" do
    test "{tags, _} faults only the named traffic" do
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0, scope: {:tags, [:batch]}}})
      s = sink()

      @net.send(s, {:batch, 1})
      @net.send(s, {:ack, 1})
      @net.send(s, {:batch, 2})

      assert drained(s) == [{:ack, 1}]
    end

    test "a predicate can scope by channel" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.set_policy(%{drop_p: 1.0, scope: fn _from, dest, _msg -> dest == a end})

      @net.send(a, :to_a)
      @net.send(b, :to_b)

      assert drained(a) == []
      assert drained(b) == [:to_b]
    end

    test "a perfect policy consumes no fault schedule at all" do
      # The rule: the generator advances only when the answer could have been
      # otherwise. This is not an optimisation — it is what makes a fault schedule
      # a function of its seed.
      #
      # A cluster that must sync before it can survive faults starts perfect and
      # turns loss on at the end of `init/2`, and everything it sends while
      # starting up runs on the real scheduler, varying in order and count from
      # run to run. Charging those messages for a decision that could only come out
      # one way leaves the generator at a different offset every time. It cost five
      # distinct schedules in five runs of one seed on a 3-member registry.
      pattern = fn startup ->
        :ok = @net.start(%{seed: 5})
        s = sink()

        # "Startup": traffic sent under a perfect policy, in a quantity that
        # varies, exactly as a real cluster's does.
        for i <- 1..startup//1, do: @net.send(s, {:startup, i})
        _ = drained(s)

        :ok = @net.set_policy(%{drop_p: 0.5})
        for i <- 1..30, do: @net.send(s, {:m, i})

        got = for {:m, i} <- drained(s), do: i
        @net.stop()
        got
      end

      assert pattern.(0) == pattern.(17)
      assert pattern.(0) == pattern.(200)
    end

    test "out-of-scope traffic does not consume the fault schedule" do
      # The trap the Elixir original hit: anything drawing from the RNG before the
      # traffic under test shifts which messages get dropped. Two runs of the same
      # seed, differing only in how much out-of-scope traffic they carry, must make
      # the same decisions about the in-scope messages.
      pattern = fn extra ->
        :ok = @net.start(%{seed: 11, policy: %{drop_p: 0.5, scope: {:tags, [:batch]}}})
        s = sink()

        for i <- 1..20 do
          for _ <- 1..extra//1, do: @net.send(s, {:noise, i})
          @net.send(s, {:batch, i})
        end

        got = for {:batch, i} <- drained(s), do: i
        @net.stop()
        got
      end

      assert pattern.(0) == pattern.(3)
    end
  end

  # ---------------------------------------------------------------------------
  # Channel identity
  # ---------------------------------------------------------------------------

  describe "channel identity" do
    setup do
      :ok = @net.start(%{seed: 1})
      {:ok, pid} = :eta_net_echo.start_link(:named_echo)
      on_exit(fn -> stop_echo(:named_echo) end)
      %{pid: pid}
    end

    test "a name, a {Name, node()} tuple and the pid are one channel", %{pid: pid} do
      # `gen_server:cast/2` to a member named `{Name, Node}` is what dgen's
      # registry does, and it has to land on the same channel as a send to the
      # same process by pid — or each gets its own ordering clamp and one can
      # overtake the other.
      :ok = @net.cut(self(), pid)

      s = sink()
      @net.send(:named_echo, {:forward, s, :by_name})
      @net.send({:named_echo, node()}, {:forward, s, :by_tuple})
      @net.send(pid, {:forward, s, :by_pid})

      Process.sleep(20)
      assert drained(s) == [], "a cut by pid did not cover the same target by name"
      assert %{dropped: 3} = @net.stats()
    end

    test "a cut can be expressed by name too", %{pid: _pid} do
      :ok = @net.cut(self(), :named_echo)
      s = sink()

      @net.send(:named_echo, {:forward, s, :nope})
      Process.sleep(20)

      assert drained(s) == []
    end

    test "an unregistered name is not a channel, and behaves as erlang:send does" do
      assert_raise ArgumentError, fn -> @net.send(:no_such_name, :m) end
    end
  end

  # ---------------------------------------------------------------------------
  # Topology
  # ---------------------------------------------------------------------------

  describe "node placement" do
    test "faults only cross the link, never stay inside a node" do
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      a1 = sink()
      a2 = sink()
      b1 = sink()

      :ok = @net.place(:a, [a1, a2])
      :ok = @net.place(:b, [b1])

      :ok = send_from(a1, b1, :crosses)
      assert drained(b1) == [], "a cross-link send was not faulted"

      # Same node: not a network at all, so not a thing a network can break.
      :ok = send_from(a1, a2, :within)
      assert drained(a2) == [:within], "a same-node send was faulted"
    end

    test "an unplaced process is off the network in both directions" do
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      placed = sink()
      stranger = sink()

      :ok = @net.place(:a, [placed])

      :ok = send_from(placed, stranger, :to_stranger)
      assert drained(stranger) == [:to_stranger], "an unplaced destination was faulted"

      :ok = send_from(stranger, placed, :from_stranger)
      assert drained(placed) == [:from_stranger], "an unplaced sender was faulted"
    end

    test "a node cut survives the process on the far side being replaced" do
      # The difference between cutting a link and cutting a pid. A pid-level cut
      # names a process; a partition names a place, and whatever is standing there
      # after a restart is still on the wrong side of it.
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [b])
      :ok = @net.partition(:na, :nb)

      replacement = sink()
      :ok = @net.place(:nb, [replacement])

      :ok = send_from(a, replacement, :should_not_arrive)
      assert drained(replacement) == []
    end

    test "with no topology at all every link is faultable" do
      # `place/2` is opt-in: a network that was never given one behaves exactly as
      # it did before there was such a thing.
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      s = sink()

      @net.send(s, :lost)
      assert drained(s) == []
    end

    test "a child is placed where its parent is" do
      # Without this a topology is a snapshot rather than a description: the first
      # worker the system spawns sends across a link nobody declared.
      :ok = @net.start(%{seed: 1})
      parent = sink()
      :ok = @net.place(:a, [parent])

      child = spawn(fn -> Process.sleep(:infinity) end)
      :ok = @net.inherit(parent, child)

      assert @net.node_of(child) == :a
    end

    test "inheriting from an unplaced parent places nothing" do
      :ok = @net.start(%{seed: 1})
      parent = sink()
      child = sink()

      :ok = @net.inherit(parent, child)
      assert @net.node_of(child) == :undefined
    end

    test "an unplaced child of a placed spawner answers with the spawner's node" do
      # The child a server spawns from `init/1` during the harness's `init/2`:
      # no scheduler exists to adopt it, so nothing calls `inherit/2`, yet it is
      # on its parent's node in every sense but the table's. Located, not placed
      # — off the wire, and not the network's to fault.
      :ok = @net.start(%{seed: 1})
      me = self()

      parent =
        spawn(fn ->
          receive do
            :go -> send(me, {:child, spawn(fn -> Process.sleep(:infinity) end)})
          end
        end)

      :ok = @net.place(:a, [parent])
      send(parent, :go)
      assert_receive {:child, child}

      assert @net.node_of(child) == :a
      refute @net.faultable(child)
    end
  end

  describe "who spawned a process" do
    # `node_of/1` answers for an unplaced process with its spawner's node, and
    # the only way to learn a spawner is `process_info/2`. Against a process
    # the scheduler has suspended that is a signal and a wait: the asker parks
    # in `erts_internal:await_result/1`, the scheduler reads a parked process
    # as one whose step is over, and the step ends in the middle of whatever
    # the asker was doing. Every routed send asks, through `node_cut/2`. So
    # the question is put once, by whoever can afford to wait, and remembered.

    test "a process the scheduler owns is not asked" do
      :ok = @net.start(%{seed: 1})
      parent = spawner()
      :ok = @net.place(:a, [parent])
      child = child_of(parent)

      sched = @sched.new(%{seed: 1})
      @sched.register(sched, [child])

      {node, asked} =
        calls_to({:erlang, :process_info, 2}, fn ->
          # A message first, as a sender has always just sent one: a process
          # with a signal waiting is the one `process_info/2` cannot read
          # without asking.
          send(child, :hello)
          @net.node_of(child)
        end)

      @sched.release(sched)

      assert node == :a
      assert asked == [], "node_of/1 asked a suspended process: #{inspect(asked)}"
    end

    test "a process nobody has introduced is asked once" do
      :ok = @net.start(%{seed: 1})
      parent = spawner()
      :ok = @net.place(:a, [parent])
      child = child_of(parent)

      {nodes, asked} =
        calls_to({:erlang, :process_info, 2}, fn ->
          [@net.node_of(child), @net.node_of(child), @net.node_of(child)]
        end)

      assert nodes == [:a, :a, :a]
      assert asked == [[child, :parent]]
    end

    test "the answer follows a spawner that is placed afterwards" do
      # What is remembered is who spawned it, which never changes, and not
      # where that was, which can.
      :ok = @net.start(%{seed: 1})
      parent = spawner()
      child = child_of(parent)

      assert @net.node_of(child) == :undefined
      :ok = @net.place(:a, [parent])
      assert @net.node_of(child) == :a
      :ok = @net.place(:b, [parent])
      assert @net.node_of(child) == :b
    end

    test "a child adopted from an unplaced parent is not asked either" do
      # `eta_sched` reports every spawn it sees through `inherit/2`, parent
      # placed or not, and that is the same fact.
      :ok = @net.start(%{seed: 1})
      parent = sink()
      child = sink()
      :ok = @net.inherit(parent, child)
      :ok = @net.place(:a, [parent])

      {node, asked} =
        calls_to({:erlang, :process_info, 2}, fn -> @net.node_of(child) end)

      assert node == :a
      assert asked == []
    end

    test "remembering spawners is not a topology" do
      # With nothing placed every link is faultable, and a table of who
      # spawned whom must not count as something placed.
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      a = sink()
      b = sink()
      :ok = @net.inherit(a, b)
      _ = @net.node_of(b)

      :ok = send_from(a, b, :lost)
      assert drained(b) == []
      assert %{dropped: 1} = @net.stats()
    end
  end

  describe "simulated name registration" do
    # What lets a system under test keep its own addressing. Distributed Erlang
    # says `{Name, Node}` and lets the VM resolve it; one VM holds one registry,
    # so a per-node singleton — a lock server, a metadata store — cannot be
    # expressed without this.

    test "the same name on two nodes is two processes" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [b])
      :ok = @net.register_name(:na, :the_server, a)
      :ok = @net.register_name(:nb, :the_server, b)

      assert @net.whereis_name(:na, :the_server) == a
      assert @net.whereis_name(:nb, :the_server) == b

      :ok = send_from(a, {:the_server, :nb}, :across)
      assert drained(b) == [:across]

      :ok = send_from(b, {:the_server, :na}, :back)
      assert drained(a) == [:back]
    end

    test "an unregistered name resolves to undefined" do
      # The trap this closes. `{Name, SimNode}` used to normalize to `undefined`
      # and fall through to `erlang:send/2`, which on a non-distributed VM drops
      # it — a cluster's whole traffic vanishing with nothing raised and nothing
      # counted.
      :ok = @net.start(%{seed: 1})
      assert @net.whereis_name(:nowhere, :the_server) == :undefined
    end

    test "a name is cut by a partition, because the pid behind it is" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [b])
      :ok = @net.register_name(:nb, :the_server, b)

      :ok = @net.partition(:na, :nb)
      :ok = send_from(a, {:the_server, :nb}, :should_not_arrive)
      assert drained(b) == []
    end

    test "re-registering moves the name" do
      :ok = @net.start(%{seed: 1})
      first = sink()
      second = sink()
      sender = sink()
      :ok = @net.place(:na, [sender])
      :ok = @net.place(:nb, [first, second])
      :ok = @net.register_name(:nb, :the_server, first)
      :ok = @net.register_name(:nb, :the_server, second)

      :ok = send_from(sender, {:the_server, :nb}, :hello)
      assert drained(first) == []
      assert drained(second) == [:hello]
    end

    test "unregister_name/2 removes it" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.register_name(:na, :the_server, a)
      :ok = @net.unregister_name(:na, :the_server)

      assert @net.whereis_name(:na, :the_server) == :undefined
    end

    test "registering something that is not a process is an error" do
      :ok = @net.start(%{seed: 1})

      assert_raise ErlangError, fn ->
        @net.register_name(:na, :the_server, :no_such_name_anywhere)
      end
    end

    test "monitoring a simulated name on your own node does not raise" do
      # `{Name, SimNode}` can never be handed to `:erlang.monitor/2` — the VM has
      # no such node, and answers `badarg` when it is not distributed at all.
      # Whether the pair spans nodes decides if the monitor can be *faulted*, not
      # whether it can be delegated, and conflating the two killed every process
      # that monitored a per-node singleton on its own node. Exactly one survived
      # doing it — the one on `node()` — so the system it was under looked
      # conservative rather than mostly dead.
      :ok = @net.start(%{seed: 1})
      server = sink()
      client = sink()
      :ok = @net.place(:na, [server, client])
      :ok = @net.register_name(:na, :the_server, server)

      ref = monitor_from(client, {:the_server, :na})
      assert is_reference(ref)
      assert Process.alive?(client)
    end

    test "a simulated same-node monitor still fires when the target dies" do
      :ok = @net.start(%{seed: 1})
      server = sink()
      client = sink()
      :ok = @net.place(:na, [server, client])
      :ok = @net.register_name(:na, :the_server, server)

      _ = monitor_from(client, {:the_server, :na})
      Process.exit(server, :kill)
      :ok = @net.notify_exit(server, :killed)

      assert [{:DOWN, _ref, :process, {:the_server, :na}, :killed}] = drained(client)
    end

    test "the registry does not outlive the network" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.register_name(:na, :the_server, a)
      @net.stop()

      assert @net.whereis_name(:na, :the_server) == :undefined
    end
  end

  describe "a name on a simulated node with nobody behind it" do
    # The server died with its node, or was never started. `call/3` already
    # answers `noproc` for this. The sends used to be handed to OTP instead,
    # which takes `{Name, Node}` for a real node: `gen_server:cast/2` spawns a
    # process to connect to it, outside the schedule, and a plain send tries
    # the connection itself.

    setup do
      :ok = @net.start(%{seed: 1})
      a = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [sink()])
      :ok
    end

    test "a cast is dropped, and gen_server is not asked to deliver it" do
      {result, handed_on} =
        calls_to({:gen_server, :cast, 2}, fn -> @net.cast({:nobody_here, :nb}, :msg) end)

      assert result == :ok
      assert handed_on == []
    end

    test "a send is dropped, and returns the message as a send does" do
      {result, handed_on} =
        calls_to({:erlang, :send, 2}, fn -> @net.send({:nobody_here, :nb}, :msg) end)

      assert result == :msg
      # The traced process also sends its answer back to the test.
      assert for([{:nobody_here, _}, _] = call <- handed_on, do: call) == []
    end

    test "gen_fsm events are dropped the same way" do
      {result, handed_on} =
        calls_to({:gen_fsm, :send_event, 2}, fn ->
          @net.send_event({:nobody_here, :nb}, :ev)
        end)

      assert {result, handed_on} == {:ok, []}

      {result, handed_on} =
        calls_to({:gen_fsm, :send_all_state_event, 2}, fn ->
          @net.send_all_state_event({:nobody_here, :nb}, :ev)
        end)

      assert {result, handed_on} == {:ok, []}
    end

    test "a name on a node the network has never heard of is still OTP's" do
      # Not simulated, so not this module's to swallow.
      {result, handed_on} =
        calls_to({:gen_server, :cast, 2}, fn -> @net.cast({:nobody_here, :not_a_node}, :msg) end)

      assert result == :ok
      assert handed_on == [[{:nobody_here, :not_a_node}, :msg]]
    end
  end

  describe "node-level partitions" do
    setup do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [b])
      %{a: a, b: b}
    end

    test "partition/2 names nodes and cuts both directions", %{a: a, b: b} do
      :ok = @net.partition(:na, :nb)

      :ok = send_from(a, b, :from_a_side)
      assert drained(b) == []
      :ok = send_from(b, a, :from_b_side)
      assert drained(a) == []

      :ok = @net.heal_partition(:na, :nb)
      :ok = send_from(a, b, :after_heal)
      assert drained(b) == [:after_heal]
    end

    test "the link signal reaches every process on both nodes" do
      a2 = sink()
      b2 = sink()
      :ok = @net.place(:na, [a2])
      :ok = @net.place(:nb, [b2])

      :ok = @net.partition(:na, :nb, %{signal: {:nodedown, :peer}})

      # Not two representative processes — everything on both sides, because a
      # system hangs its recovery off this event.
      assert drained(a2) == [{:nodedown, :peer}]
      assert drained(b2) == [{:nodedown, :peer}]
    end

    test "cutting one node to another is refused if the ends disagree", %{a: a} do
      assert_raise ErlangError, fn -> @net.cut(:na, a) end
    end
  end

  # ---------------------------------------------------------------------------
  # Cuts and partitions
  # ---------------------------------------------------------------------------

  describe "node names" do
    test "a binary name partitions like an atom" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place("a", [a])
      :ok = @net.place("b", [b])

      :ok = @net.partition("a", "b")
      assert @net.faultable(a)
      assert :ets.member(:eta_net_chan, {:node_cut, "a", "b"})
      assert :ets.member(:eta_net_chan, {:node_cut, "b", "a"})

      :ok = @net.heal_partition("a", "b")
      refute :ets.member(:eta_net_chan, {:node_cut, "a", "b"})
    end
  end

  describe "cuts" do
    test "cut/2 is one-directional and heal/2 restores it" do
      :ok = @net.start(%{seed: 1})
      s = sink()

      :ok = @net.cut(self(), s)
      @net.send(s, :while_cut)
      assert drained(s) == []

      :ok = @net.heal(self(), s)
      @net.send(s, :after_heal)
      assert drained(s) == [:after_heal]
    end

    test "partition/3 delivers the link signal to both ends, cut or not" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()

      :ok = @net.partition(a, b, %{signal: {:nodedown, node()}})

      assert drained(a) == [{:nodedown, node()}]
      assert drained(b) == [{:nodedown, node()}]
    end

    test "heal_all/0 clears cuts and pending drop_nexts" do
      :ok = @net.start(%{seed: 1})
      s = sink()

      :ok = @net.cut(self(), s)
      :ok = @net.drop_next(self(), s, 5)
      :ok = @net.drop_matching(self(), s, :m, 0, 5)
      :ok = @net.heal_all()

      @net.send(s, :m)
      assert drained(s) == [:m]
    end
  end

  # ---------------------------------------------------------------------------
  # Link events: signals
  # ---------------------------------------------------------------------------

  describe "a link signal" do
    setup do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [b])
      %{a: a, b: b}
    end

    test "given as an atom is derived per side", %{a: a, b: b} do
      # What a partition actually says: A learns B is gone and B learns A is.
      # One undifferentiated term tells both sides the same thing, which is never
      # what happened.
      :ok = @net.partition(:na, :nb, %{signal: :nodedown})

      assert taken(a) == [{:nodedown, :nb}]
      assert taken(b) == [{:nodedown, :na}]
    end

    test "given as a term is delivered as written, to both sides", %{a: a, b: b} do
      # The form that has callers. It has to keep meaning exactly what it did.
      :ok = @net.partition(:na, :nb, %{signal: {:nodedown, node()}})

      assert taken(a) == [{:nodedown, node()}]
      assert taken(b) == [{:nodedown, node()}]
    end

    test "given as {literal, Atom} is not derived", %{a: a, b: b} do
      :ok = @net.partition(:na, :nb, %{signal: {:literal, :split}})

      assert taken(a) == [:split]
      assert taken(b) == [:split]
    end

    test "reaches only the side that learns, while the cut stays symmetric", %{a: a, b: b} do
      # "A finds out that B is gone and B does not notice" — the asymmetry two
      # independently timing-out ends produce constantly, and the thing that used
      # to need two cut/2 calls and a hand-rolled fan-out.
      :ok = @net.partition(:na, :nb, %{signal: :nodedown, learns: :a})

      assert taken(a) == [{:nodedown, :nb}]
      assert taken(b) == [], "the side that was not told still heard about it"

      :ok = send_from(a, b, :from_a)
      assert taken(b) == [], "a one-sided signal made the cut one-sided too"
      :ok = send_from(b, a, :from_b)
      assert taken(a) == []
    end

    test "on heal derives the other direction the same way", %{a: a, b: b} do
      :ok = @net.partition(:na, :nb, %{signal: :nodedown})
      _ = taken(a)
      _ = taken(b)

      :ok = @net.heal_partition(:na, :nb, %{signal: :nodeup})

      assert taken(a) == [{:nodeup, :nb}]
      assert taken(b) == [{:nodeup, :na}]
    end

    test "between two processes names the pids, since there are no nodes to name" do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()

      :ok = @net.partition(a, b, %{signal: :nodedown})

      assert taken(a) == [{:nodedown, b}]
      assert taken(b) == [{:nodedown, a}]
    end

    test "is counted, so a partition that reached nobody is visible" do
      :ok = @net.partition(:na, :nb, %{signal: :nodedown})
      assert %{signalled: 2} = @net.stats()

      :ok = @net.place(:empty, [])
      :ok = @net.partition(:empty, :na, %{signal: :nodedown})
      assert %{signalled: 3} = @net.stats()
    end

    test "rejects a `learns` it does not understand" do
      assert_raise ErlangError, fn -> @net.partition(:na, :nb, %{learns: :neither}) end
    end
  end

  describe "the order a link event fans out in" do
    # `on_node/1` and the monitor table are both read with `ets:match`, whose row
    # order is specified by nothing. These two assert the fan-out is ordered by
    # something the *run* decided instead — placement order and monitor-creation
    # order — because a fan-out that follows the table puts a different sequence
    # of messages in a mailbox from one run of a seed to the next.

    test "follows placement order for signals" do
      :ok = :eta_log.trace(:start)
      on_exit(fn -> :eta_log.stop() end)
      :ok = @net.start(%{seed: 1})

      side_a = for _ <- 1..8, do: sink()
      b = sink()
      for p <- side_a, do: :ok = @net.place(:na, [p])
      :ok = @net.place(:nb, [b])

      :ok = @net.partition(:na, :nb, %{signal: :nodedown})

      delivered =
        for {_seq, _label, {:net, :signal, pid, _tag}} <- :eta_log.events(),
            pid in side_a,
            do: pid

      assert delivered == side_a
    end

    test "follows monitor order for synthetic DOWNs" do
      :ok = @net.start(%{seed: 1})

      watcher = sink()
      :ok = @net.place(:na, [watcher])

      targets = for _ <- 1..8, do: sink()
      for t <- targets, do: :ok = @net.place(:nb, [t])
      refs = for t <- targets, do: monitor_from(watcher, t)

      :ok = @net.partition(:na, :nb)

      fired = for {:DOWN, ref, :process, _target, :noconnection} <- taken(watcher), do: ref
      assert fired == refs
    end
  end

  # ---------------------------------------------------------------------------
  # Located vs faultable
  # ---------------------------------------------------------------------------

  describe "attach/2" do
    setup do
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      member = sink()
      conn = sink()
      peer = sink()

      :ok = @net.place(:na, [member])
      :ok = @net.attach(:na, [conn])
      :ok = @net.place(:nb, [peer])

      %{member: member, conn: conn, peer: peer}
    end

    test "receives its node's link events while its traffic survives a policy that drops everything",
         %{member: member, conn: conn, peer: peer} do
      # The case that forces located and faultable apart. A connector's sends
      # model a durable-store operation rather than a message, so dropping one
      # injects a failure the real system cannot have — but it is still the thing
      # that has to hear about a dead peer.
      :ok = send_from(member, peer, :from_member)
      assert taken(peer) == [], "a cross-link send from a placed process was not faulted"

      :ok = send_from(conn, peer, :from_conn)
      assert taken(peer) == [:from_conn], "an attached process's send was faulted"

      :ok = send_from(peer, conn, :to_conn)
      assert taken(conn) == [:to_conn], "an attached process's inbound traffic was faulted"

      :ok = @net.partition(:na, :nb, %{signal: :nodedown})

      assert taken(conn) == [{:nodedown, :nb}], "an attached process missed its node's link event"
      assert taken(member) == [{:nodedown, :nb}]
    end

    test "is located, and says so", %{member: member, conn: conn, peer: peer} do
      assert @net.node_of(conn) == :na
      assert @net.faultable(conn) == false
      assert @net.faultable(member) == true
      assert @net.faultable(peer) == true
      assert @net.faultable(sink()) == false, "an unplaced process is not on the network"
    end

    test "is inherited by children, so a worker does not acquire a wire its parent lacks", %{
      conn: conn,
      peer: peer
    } do
      child = sink()
      :ok = @net.inherit(conn, child)

      assert @net.node_of(child) == :na
      assert @net.faultable(child) == false

      :ok = send_from(child, peer, :from_child)
      assert taken(peer) == [:from_child]
    end
  end

  # ---------------------------------------------------------------------------
  # Link events: synthetic noconnection DOWNs
  # ---------------------------------------------------------------------------

  describe "a monitor across a partition" do
    setup do
      :ok = @net.start(%{seed: 1})
      a = sink()
      b = sink()
      :ok = @net.place(:na, [a])
      :ok = @net.place(:nb, [b])
      %{a: a, b: b}
    end

    test "fires exactly one noconnection DOWN, and heal does not resurrect it", %{a: a, b: b} do
      mref = monitor_from(a, b)

      :ok = @net.partition(:na, :nb, %{signal: :nodedown})

      assert taken(a) == [
               {:DOWN, mref, :process, b, :noconnection},
               {:nodedown, :nb}
             ]

      assert %{noconnection: 1} = @net.stats()

      # Real Erlang does not re-arm a monitor after a noconnection DOWN, and the
      # monitoring process has to monitor again. Healing is a second event, not
      # an undo.
      :ok = @net.heal_partition(:na, :nb)
      assert taken(a) == []

      :ok = @net.partition(:na, :nb)
      assert taken(a) == [], "a retired monitor fired a second time"
      assert %{noconnection: 1} = @net.stats()
    end

    test "does not fire when its target is on the same side of the cut", %{a: a} do
      a2 = sink()
      :ok = @net.place(:na, [a2])
      _mref = monitor_from(a, a2)

      :ok = @net.partition(:na, :nb)

      assert taken(a) == []
      assert %{noconnection: 0} = @net.stats()
    end

    test "created across a cut that is already in force fires noconnection at once",
         %{a: a, b: b} do
      # Not a replay of the old failure — nothing here is retroactive. It reports
      # that the monitor could not be established, which is a fact about the
      # topology now, and the BIF answers an unreachable node the same way. A
      # system that monitors a peer to learn it is unreachable waits forever
      # otherwise, and the run looks healthy while it does.
      :ok = @net.partition(:na, :nb)

      mref = monitor_from(a, b)

      assert taken(a) == [{:DOWN, mref, :process, b, :noconnection}]
      assert %{noconnection: 1} = @net.stats(), "the immediate DOWN went uncounted"
    end

    test "created across a cut reports the name as Object, as the BIF does", %{a: a, b: b} do
      # The shape the bug was found in: a system monitors {Name, Node} to find
      # out whether that node is reachable at all.
      :ok = @net.register_name(:nb, :srv, b)
      :ok = @net.partition(:na, :nb)

      mref = monitor_from(a, {:srv, :nb})

      assert taken(a) == [{:DOWN, mref, :process, {:srv, :nb}, :noconnection}]
    end

    test "created after a heal does not fire, and is armed for the next failure",
         %{a: a, b: b} do
      # The healed link is usable again, so this monitor establishes normally —
      # and the terminal rule is about the monitor that already fired, not about
      # the link.
      :ok = @net.partition(:na, :nb)
      :ok = @net.heal_partition(:na, :nb)

      mref = monitor_from(a, b)
      assert taken(a) == []

      :ok = @net.partition(:na, :nb)
      assert taken(a) == [{:DOWN, mref, :process, b, :noconnection}]
    end

    test "created across a cut to a target on its own side does not fire", %{a: a} do
      a2 = sink()
      :ok = @net.place(:na, [a2])
      :ok = @net.partition(:na, :nb)

      _mref = monitor_from(a, a2)

      assert taken(a) == []
      assert %{noconnection: 0} = @net.stats()
    end

    test "created across a one-way cut does not fire", %{a: a, b: b} do
      # `cut/2` is a channel that swallows traffic while both ends still believe
      # the link is up, and it signals nothing. An end that believes the link is
      # up would not observe a monitor failing to establish, so this one does not.
      :ok = @net.cut(:na, :nb)

      _mref = monitor_from(a, b)

      assert taken(a) == []
      assert %{noconnection: 0} = @net.stats()
    end

    test "created across a process-level cut does not fire", %{a: a, b: b} do
      # Same rule, and the reason a pid cut never fires a monitor anywhere else
      # here: it is a message fault, not a lost connection. Both directions, so
      # that the failure cannot be blamed on the cut being one-way.
      :ok = @net.cut(a, b)
      :ok = @net.cut(b, a)

      _mref = monitor_from(a, b)

      assert taken(a) == []
      assert %{noconnection: 0} = @net.stats()
    end

    test "fires only on the side that learns", %{a: a, b: b} do
      from_a = monitor_from(a, b)
      _from_b = monitor_from(b, a)

      :ok = @net.partition(:na, :nb, %{learns: :a})

      assert taken(a) == [{:DOWN, from_a, :process, b, :noconnection}]
      assert taken(b) == [], "the side that did not notice fired a monitor anyway"
    end

    test "the side that did not notice learns when the link heals", %{a: a, b: b} do
      _from_a = monitor_from(a, b)
      from_b = monitor_from(b, a)

      :ok = @net.partition(:na, :nb, %{learns: :a})
      _ = taken(a)
      assert taken(b) == []

      :ok = @net.heal_partition(:nb, :na)
      assert taken(b) == [{:DOWN, from_b, :process, a, :noconnection}]
      assert taken(a) == [], "a already knew"
    end

    test "can be cancelled, and then a partition fires nothing", %{a: a, b: b} do
      mref = monitor_from(a, b)
      assert demonitor_from(a, mref) == true

      :ok = @net.partition(:na, :nb)

      assert taken(a) == []
    end

    test "cancelling one that already fired is not an error", %{a: a, b: b} do
      mref = monitor_from(a, b)
      :ok = @net.partition(:na, :nb)
      assert [{:DOWN, ^mref, :process, ^b, :noconnection}] = taken(a)

      # Real Erlang does not raise for an already-fired monitor, and a system
      # tidying up after a DOWN must not crash on the tidying.
      assert demonitor_from(a, mref) == true
    end

    test "on a target that is already dead is a noproc DOWN, as erlang's is", %{a: a} do
      dead = sink()
      :ok = @net.place(:nb, [dead])
      Process.exit(dead, :kill)
      Process.sleep(10)

      mref = monitor_from(a, dead)

      assert taken(a) == [{:DOWN, mref, :process, dead, :noproc}]
    end

    test "between two processes with no topology is left to the VM" do
      # Simulation is confined to monitors that cross a *declared* link. Anything
      # else keeps machinery that cannot go wrong.
      :ok = @net.start(%{seed: 1})
      w = sink()
      t = sink()
      _mref = monitor_from(w, t)

      :ok = @net.partition(w, t)

      assert taken(w) == []
    end
  end

  describe "a simulated monitor whose target exits" do
    test "fires with the real reason once the scheduler reports it" do
      # A simulated monitor has no VM monitor behind it, so `eta_sched` is what
      # tells the network the target is gone. Without this a system that detects
      # a crashed peer by monitor would simply hang.
      :ok = @net.start(%{seed: 1})
      s = :eta_sched.new(%{seed: 1})
      on_exit(fn -> quietly(fn -> :eta_sched.release(s) end) end)

      watcher = sink()
      target = sink()
      :ok = @net.place(:na, [watcher])
      :ok = @net.place(:nb, [target])
      mref = monitor_from(watcher, target)

      _ = :eta_sched.register(s, [watcher, target])
      Process.exit(target, :kill)

      # The scheduler is the tracer, so the exit reaches it as a trace event and
      # `eta_net:notify_exit/2` fires the monitor from there.
      wait_until(fn -> not Process.alive?(target) end)
      _ = :eta_sched.stats(s)
      :ok = :eta_sched.release(s)

      assert taken(watcher) == [{:DOWN, mref, :process, target, :killed}]
    end
  end

  # ---------------------------------------------------------------------------
  # Node death
  # ---------------------------------------------------------------------------

  describe "kill_node/2" do
    setup do
      :ok = @net.start(%{seed: 1})
      member = sink()
      conn = sink()
      peer = sink()
      observer = sink()

      :ok = @net.place(:na, [member])
      :ok = @net.attach(:na, [conn])
      :ok = @net.place(:nb, [peer])

      %{member: member, conn: conn, peer: peer, observer: observer}
    end

    test "takes the dead node's timers with it", %{member: member, conn: conn, peer: peer} do
      # A heartbeat armed by a process that then dies with its node would sit
      # in the wheel as a stray the run is charged with, for a fault the run
      # injected on purpose. The survivor's timer is untouched.
      :ok = :eta_time.start(%{seed: 1})

      try do
        _ = :eta_time.send_after(1_000, member, :tick)
        _ = :eta_time.send_after(1_000, conn, :tick)
        kept = :eta_time.send_after(1_000, peer, :tick)
        assert :eta_time.pending() == 3

        :ok = @net.kill_node(:na, %{signal: :nodedown})

        assert :eta_time.pending() == 1
        assert is_integer(:eta_time.read_timer(kept))
      after
        :eta_time.stop()
      end
    end

    test "kills every located process, signals the survivors, and reports noconnection to a remote monitor",
         %{member: member, conn: conn, peer: peer, observer: observer} do
      # Cross-node: simulated, so it can be told what distribution would have told
      # it. Unplaced: a real monitor in the same VM, so it sees the true reason.
      # That is the asymmetry real distribution has, seen from both sides.
      cross = monitor_from(peer, member)
      local = monitor_from(observer, member)

      :ok = @net.kill_node(:na, %{signal: :nodedown})

      refute Process.alive?(member)
      refute Process.alive?(conn), "an attached process did not die with its node"
      assert Process.alive?(peer)

      assert taken(peer) == [
               {:DOWN, cross, :process, member, :noconnection},
               {:nodedown, :na}
             ]

      assert taken(observer) == [{:DOWN, local, :process, member, :killed}]
    end

    test "a monitor held by a dying process is simply gone", %{member: member, peer: peer} do
      _outbound = monitor_from(member, peer)

      :ok = @net.kill_node(:na, %{signal: :nodedown})

      assert taken(peer) == [{:nodedown, :na}]
    end

    test "an unplaced process gets no signal", %{observer: observer} do
      :ok = @net.kill_node(:na, %{signal: :nodedown})
      assert taken(observer) == []
    end

    test "the node name survives, so placing on it again is a restart", %{peer: peer} do
      :ok = @net.kill_node(:na, %{signal: :nodedown})
      _ = taken(peer)

      replacement = sink()
      :ok = @net.place(:na, [replacement])
      assert @net.node_of(replacement) == :na

      :ok = send_from(replacement, peer, :back_up)
      assert taken(peer) == [:back_up]

      :ok = @net.partition(:na, :nb, %{signal: :nodedown})
      assert taken(replacement) == [{:nodedown, :nb}]
    end

    test "loses what was in flight to and from the node", %{member: member, peer: peer} do
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.set_policy(%{delay_p: 1.0, max_delay: 50})

      :ok = send_from(peer, member, :in_flight)
      assert @net.in_flight() == 1

      :ok = @net.kill_node(:na)
      @time.advance(100)

      assert @net.in_flight() == 0
      assert %{cancelled: 1} = @net.stats()
    end

    test "naming a node nothing was ever placed on raises rather than doing nothing" do
      assert_raise ErlangError, fn -> @net.kill_node(:no_such_node) end
    end
  end

  # ---------------------------------------------------------------------------
  # Delay, on the virtual clock
  # ---------------------------------------------------------------------------

  describe "delay" do
    test "a delayed message is not delivered until the clock reaches it" do
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.start(%{seed: 1, policy: %{delay_p: 1.0, max_delay: 10}})
      s = sink()

      @net.send(s, :later)

      assert drained(s) == [], "delivered without the clock moving"
      assert @net.in_flight() == 1
      assert %{delayed: 1} = @net.stats()

      @time.advance(10)
      assert drained(s) == [:later]
      assert @net.in_flight() == 0
    end

    test "a delay costs no wall-clock time" do
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.start(%{seed: 1, policy: %{delay_p: 1.0, max_delay: 60_000}})
      s = sink()

      {micros, _} =
        :timer.tc(fn ->
          @net.send(s, :slow)
          @time.advance(60_000)
        end)

      assert drained(s) == [:slow]
      assert micros < 100_000, "a virtual delay took #{micros}us of real time"
    end

    test "a later undelayed message cannot overtake an earlier delayed one" do
      # The ordering guarantee, and the whole reason for the FIFO clamp: Erlang
      # never reorders within an ordered pair, so neither may this.
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.start(%{seed: 1, policy: %{delay_p: 1.0, max_delay: 50}})
      s = sink()

      @net.send(s, :first)
      :ok = @net.set_policy(%{delay_p: 0.0})
      @net.send(s, :second)

      assert drained(s) == [], "the undelayed message overtook the delayed one"

      @time.advance(100)
      assert drained(s) == [:first, :second]
    end

    test "nothing overtakes a delayed message on the same node-to-node link, whoever sent it" do
      # Distribution carries everything from one node to another on a single
      # connection, in the order it was handed over. A process sending on
      # another's behalf (ra's leader does this when its own send would block)
      # must not see its message overtaken by its principal's later ones.
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.start(%{seed: 1, policy: %{delay_p: 1.0, max_delay: 50}})
      s = sink()
      me = self()

      helper =
        spawn(fn ->
          receive do: (:go ->
                         @net.send(s, :from_helper)
                         send(me, :sent))
        end)

      :ok = @net.place(:na, [me, helper])
      :ok = @net.place(:nb, [s])

      send(helper, :go)
      assert_receive :sent
      :ok = @net.set_policy(%{delay_p: 0.0})
      @net.send(s, :from_me)

      assert drained(s) == [], "a later message overtook a delayed one on the same link"

      @time.advance(100)
      assert drained(s) == [:from_helper, :from_me]
    end

    test "with no virtual clock the delay is a real one, so the module works outside a run" do
      # `eta_time` already delegates `send_after/3` to `erlang` with no clock
      # running, so a hand-driven network delays for real rather than silently
      # delivering at once — which is what a harness predating `eta_run` needs.
      :ok = @net.start(%{seed: 1, policy: %{delay_p: 1.0, max_delay: 30}})
      s = sink()

      @net.send(s, :real_delay)

      assert drained(s) == [], "delivered immediately with no clock"
      assert %{delayed: 1} = @net.stats()

      Process.sleep(80)
      assert drained(s) == [:real_delay]
    end

    test "cutting a channel loses what was in flight on it" do
      :ok = @time.start(%{start_ms: 0})
      :ok = @net.start(%{seed: 1, policy: %{delay_p: 1.0, max_delay: 50}})
      s = sink()

      @net.send(s, :in_flight)
      assert @net.in_flight() == 1

      :ok = @net.cut(self(), s)
      @time.advance(100)

      assert drained(s) == []
      assert %{cancelled: 1, dropped: 1} = @net.stats()
    end
  end

  # ---------------------------------------------------------------------------
  # Determinism
  # ---------------------------------------------------------------------------

  describe "the fault schedule" do
    test "is a function of the seed" do
      run = fn seed ->
        :ok = @net.start(%{seed: seed, policy: %{drop_p: 0.4}})
        s = sink()
        for i <- 1..60, do: @net.send(s, {:m, i})
        got = for {:m, i} <- drained(s), do: i
        @net.stop()
        got
      end

      assert run.(7) == run.(7)
      assert run.(7) != run.(8)
    end

    test "starting a network resets it" do
      :ok = @net.start(%{seed: 1, policy: %{drop_p: 1.0}})
      s = sink()
      @net.send(s, :lost)
      assert %{dropped: 1} = @net.stats()

      :ok = @net.start(%{seed: 1})
      assert %{dropped: 0, delivered: 0} = @net.stats()
      assert @net.policy().drop_p == 0.0
    end
  end

  describe "one network per VM" do
    test "starting over another live process's network raises rather than clobbering it" do
      owner = spawn_link(fn -> receive do: (:stop -> :ok) end)
      :ok = :erpc.call(node(), fn -> :ok end)

      # Start it from a process that stays alive, so the table has a live owner.
      me = self()

      spawn_link(fn ->
        :ok = @net.start(%{seed: 1})
        send(me, :started)
        receive do: (:stop -> :ok)
      end)

      assert_receive :started, 1_000

      assert_raise ErlangError, fn -> @net.start(%{seed: 2}) end

      send(owner, :stop)
    end
  end
end
