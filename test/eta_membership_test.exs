defmodule EtaMembershipTest do
  @moduledoc """
  Node identity and membership under `eta_net`.

  A system on a simulated node asks `node()` who it is, `nodes()` who it can
  reach, and `net_kernel` to tell it when that changes. In one VM the real BIFs
  give every simulated node the same answers, so `eta_transform` points them at
  `eta_net`, which answers from its topology. These tests hold that to:

  1. **Inert without a network.** The real answers, unchanged.
  2. **Distribution's shape.** A placed node joins a full mesh; partitions,
     kills and `disconnect_node/1` take connections down with the events real
     distribution delivers, and heals, restarts and `connect_node/1` bring them
     back.
  3. **Guards agree with bodies.** `node()` in a guard compares against the
     simulated node, and `node(X)` in a guard is refused rather than answered
     wrongly.
  """
  use ExUnit.Case, async: false

  @net :eta_net
  @m :eta_net_membership
  @compile {:no_warn_undefined, EtaMembershipFixture}

  setup do
    on_exit(fn ->
      @net.stop()
      :eta_time.stop()
    end)

    :ok
  end

  # Runs `fun` in a fresh process placed on `node` and returns its result. A
  # process on no node is on no link, so membership questions have to be asked
  # from one that is.
  defp on(node, fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          :go -> send(parent, {ref, fun.()})
        end
      end)

    :ok = @net.place(node, [pid])
    send(pid, :go)

    receive do
      {^ref, result} -> result
    after
      2_000 -> flunk("no answer from the process on #{inspect(node)}")
    end
  end

  # A process on `node` that subscribes with `subscribe` and keeps whatever it is
  # sent until `taken/1` asks for it.
  defp watcher(node, subscribe \\ &@m.subscribe/0) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          :go ->
            :ok = subscribe.()
            send(parent, {ref, :subscribed})
            watch([])
        end
      end)

    :ok = @net.place(node, [pid])
    send(pid, :go)

    receive do
      {^ref, :subscribed} -> pid
    after
      2_000 -> flunk("the watcher on #{inspect(node)} never subscribed")
    end
  end

  defp watch(msgs) do
    receive do
      {:__take__, from, ref} ->
        send(from, {ref, Enum.reverse(msgs)})
        watch([])

      {:__run__, from, ref, fun} ->
        send(from, {ref, fun.()})
        watch(msgs)

      msg ->
        watch([msg | msgs])
    end
  end

  defp taken(pid) do
    ref = make_ref()
    send(pid, {:__take__, self(), ref})

    receive do
      {^ref, msgs} -> msgs
    after
      1_000 -> flunk("the watcher never answered")
    end
  end

  # Runs `fun` inside an existing watcher, for something it has to do itself.
  defp run_in(pid, fun) do
    ref = make_ref()
    send(pid, {:__run__, self(), ref, fun})

    receive do
      {^ref, result} -> result
    after
      1_000 -> flunk("the watcher never ran it")
    end
  end

  # Every node placed, then every pair connected, as a cluster is once its
  # nodes have found each other.
  defp mesh(nodes) do
    :ok = @net.start(%{seed: 1})
    for n <- nodes, do: on(n, fn -> :ok end)
    connect_all(nodes)
  end

  defp connect_all(nodes) do
    for a <- nodes, b <- nodes, a < b, do: true = on(a, fn -> @m.connect(b) end)
    :ok
  end

  # ---------------------------------------------------------------------------

  describe "with no network running" do
    test "the rewritten calls give the real answers" do
      assert @m.whoami() == node()
      assert @m.whoami_qualified() == node()
      assert @m.node_of(self()) == node()
      assert @m.peers() == Node.list()
      assert @m.alive() == Node.alive?()
      assert @m.local_by_function_guard(node()) == :local
      assert @m.local_by_function_guard(:elsewhere) == :remote
    end

    test "send_nosuspend delivers to a local process" do
      assert @m.nosuspend(self(), :hello)
      assert_receive :hello
    end
  end

  describe "node identity" do
    setup do
      :ok = @net.start(%{seed: 1})
    end

    test "a placed process is on its simulated node, anything else on the real one" do
      assert on(:a, &@m.whoami/0) == :a
      assert on(:b, &@m.whoami_qualified/0) == :b
      assert @m.whoami() == node()
    end

    test "with_node/2 answers for a process on no node, and only inside it" do
      assert @net.with_node(:a, fn -> @m.whoami() end) == :a
      assert @m.whoami() == node()
    end

    test "a pid keeps its node after it dies, even when the node is killed" do
      parent = self()
      pid = spawn(fn -> receive(do: (_ -> send(parent, :never))) end)
      :ok = @net.place(:a, [pid])
      assert @m.node_of(pid) == :a

      :ok = @net.kill_node(:a)
      refute Process.alive?(pid)
      assert @m.node_of(pid) == :a
    end

    test "a pid the network never placed is on the real node" do
      assert @m.node_of(spawn(fn -> :ok end)) == node()
    end

    test "is_alive/0 is true on a simulated node" do
      assert on(:a, &@m.alive/0)
    end
  end

  describe "connections" do
    test "a placed node starts with none, and connect_node/1 makes them" do
      :ok = @net.start(%{seed: 1})
      for n <- [:a, :b, :c], do: on(n, fn -> :ok end)
      assert on(:a, &@m.peers/0) == []

      connect_all([:a, :b, :c])
      assert on(:a, &@m.peers/0) == [:b, :c]
      assert on(:c, &@m.peers/0) == [:a, :b]
      assert on(:b, &@m.peers_with_this/0) == [:b, :a, :c]
    end

    test "connecting tells the subscribers on both sides" do
      :ok = @net.start(%{seed: 1})
      wa = watcher(:a)
      wb = watcher(:b)
      assert on(:a, fn -> @m.connect(:b) end)
      assert taken(wa) == [{:nodeup, :b}]
      assert taken(wb) == [{:nodeup, :a}]

      assert on(:b, fn -> @m.connect(:a) end)
      assert taken(wa) == [], "already connected, so nothing happened"
    end

    test "a partition disconnects both sides, and a heal leaves them disconnected" do
      mesh([:a, :b, :c])
      wa = watcher(:a)
      wb = watcher(:b)

      :ok = @net.partition(:a, :b)
      assert taken(wa) == [{:nodedown, :b}]
      assert taken(wb) == [{:nodedown, :a}]
      assert on(:a, &@m.peers/0) == [:c]
      refute on(:a, fn -> @m.connect(:b) end), "not across a partition"

      :ok = @net.heal_partition(:a, :b)
      assert taken(wa) == []
      assert on(:a, &@m.peers/0) == [:c]

      assert on(:a, fn -> @m.connect(:b) end)
      assert taken(wa) == [{:nodeup, :b}]
      assert taken(wb) == [{:nodeup, :a}]
    end

    test "with `learns`, only one side finds out" do
      mesh([:a, :b])
      wa = watcher(:a)
      wb = watcher(:b)

      :ok = @net.partition(:a, :b, %{learns: :a})
      assert taken(wa) == [{:nodedown, :b}]
      assert taken(wb) == []
      assert on(:a, &@m.peers/0) == []
      assert on(:b, &@m.peers/0) == [:a]

      # a closed its end, so b hears the connection is gone once packets flow again.
      :ok = @net.heal_partition(:a, :b)
      assert taken(wb) == [{:nodedown, :a}]
      assert on(:b, &@m.peers/0) == []

      assert on(:a, fn -> @m.connect(:b) end)
      assert taken(wa) == [{:nodeup, :b}]
      assert taken(wb) == [{:nodeup, :a}]
    end

    test "a killed node goes down for its peers, and a replacement starts unconnected" do
      mesh([:a, :b])
      wa = watcher(:a)

      :ok = @net.kill_node(:b)
      assert taken(wa) == [{:nodedown, :b}]
      assert on(:a, &@m.peers/0) == []
      refute on(:a, fn -> @m.connect(:b) end), "nothing is running on b"

      on(:b, fn -> :ok end)
      assert taken(wa) == []
      assert on(:b, fn -> @m.connect(:a) end)
      assert taken(wa) == [{:nodeup, :b}]
    end

    test "a restarted node stays apart from a peer it is still partitioned from" do
      mesh([:a, :b])
      :ok = @net.partition(:a, :b)
      :ok = @net.kill_node(:b)
      on(:b, fn -> :ok end)
      refute on(:b, fn -> @m.connect(:a) end)
    end

    test "nodedown_reason names what happened" do
      mesh([:a, :b, :c])
      wa = watcher(:a, &@m.subscribe_with_reason/0)

      :ok = @net.partition(:a, :b)
      :ok = @net.kill_node(:c)

      assert taken(wa) == [
               {:nodedown, :b, [nodedown_reason: :net_tick_timeout]},
               {:nodedown, :c, [nodedown_reason: :connection_closed]}
             ]
    end

    test "each subscription gets its own copy, and unsubscribing stops one" do
      mesh([:a, :b])
      wa = watcher(:a)
      :ok = run_in(wa, &@m.subscribe/0)

      :ok = @net.partition(:a, :b)
      assert taken(wa) == [{:nodedown, :b}, {:nodedown, :b}]

      :ok = run_in(wa, fn -> @net.monitor_nodes(false) end)
      :ok = @net.heal_partition(:a, :b)
      assert on(:a, fn -> @m.connect(:b) end)
      assert taken(wa) == [{:nodeup, :b}]
    end

    test "a subscriber that dies is forgotten" do
      mesh([:a, :b])
      wa = watcher(:a)
      ref = Process.monitor(wa)
      Process.exit(wa, :kill)
      assert_receive {:DOWN, ^ref, :process, ^wa, :killed}
      :ok = @net.notify_exit(wa, :killed)

      :ok = @net.partition(:a, :b)
      assert %{signalled: 0} = @net.stats()
    end
  end

  describe "monitor_node/2" do
    test "fires once, when the connection is lost" do
      mesh([:a, :b])
      wa = watcher(:a, fn -> :ok end)
      true = run_in(wa, fn -> @m.watch_node(:b) end)

      :ok = @net.partition(:a, :b)
      assert taken(wa) == [{:nodedown, :b}]

      :ok = @net.heal_partition(:a, :b)
      assert on(:a, fn -> @m.connect(:b) end)
      :ok = @net.partition(:a, :b)
      assert taken(wa) == [], "the watch went with the first nodedown"
    end

    test "a node it cannot reach is down at once" do
      mesh([:a])
      wa = watcher(:a, fn -> :ok end)
      true = run_in(wa, fn -> @m.watch_node(:nowhere) end)
      assert taken(wa) == [{:nodedown, :nowhere}]
    end

    test "connects first, as distribution does" do
      :ok = @net.start(%{seed: 1})
      on(:b, fn -> :ok end)
      wa = watcher(:a, fn -> :ok end)
      true = run_in(wa, fn -> @m.watch_node(:b) end)
      assert on(:a, &@m.peers/0) == [:b]
      :ok = @net.kill_node(:b)
      assert taken(wa) == [{:nodedown, :b}]
    end
  end

  describe "connecting and disconnecting" do
    test "disconnect_node/1 takes the connection down on both sides" do
      mesh([:a, :b])
      wa = watcher(:a)
      wb = watcher(:b)

      assert on(:a, fn -> @m.disconnect(:b) end)
      assert taken(wa) == [{:nodedown, :b}]
      assert taken(wb) == [{:nodedown, :a}]
      assert on(:b, &@m.peers/0) == []

      refute on(:a, fn -> @m.disconnect(:b) end), "nothing left to disconnect"
    end

    test "connect_node/1 brings it back, and says no across a cut or to a dead node" do
      mesh([:a, :b, :c])
      wa = watcher(:a)
      assert on(:a, fn -> @m.disconnect(:b) end)
      _ = taken(wa)

      assert on(:a, fn -> @m.connect(:b) end)
      assert taken(wa) == [{:nodeup, :b}]

      :ok = @net.cut(:c, :a)
      assert on(:a, fn -> @m.disconnect(:c) end)
      refute on(:a, fn -> @m.connect(:c) end), "a one-way cut still stops a connection"

      refute on(:a, fn -> @m.connect(:nowhere) end)
      assert on(:a, fn -> @m.ping(:b) end) == :pong
      assert on(:a, fn -> @m.ping(:nowhere) end) == :pang
      assert on(:a, fn -> @m.connect(:a) end), "a node is always connected to itself"
    end

    test "a plain send reconnects, as distribution does" do
      mesh([:a, :b])
      wa = watcher(:a)
      wb = watcher(:b)
      assert on(:a, fn -> @m.disconnect(:b) end)
      _ = taken(wa)
      _ = taken(wb)

      on(:a, fn -> @net.send(wb, :hello) end)
      assert taken(wa) == [{:nodeup, :b}]
      assert taken(wb) == [{:nodeup, :a}, :hello]
    end

    test "disconnecting fires noconnection at the monitors across it" do
      mesh([:a, :b])
      wb = watcher(:b)
      wa = watcher(:a)
      mref = run_in(wa, fn -> @net.monitor(:process, wb) end)

      assert on(:a, fn -> @m.disconnect(:b) end)
      assert {:DOWN, mref, :process, wb, :noconnection} in taken(wa)
    end
  end

  describe "send_nosuspend" do
    test "delivers between connected nodes, by pid or by {Name, Node}" do
      mesh([:a, :b])
      wb = watcher(:b)
      name = :"eta_membership_#{System.unique_integer([:positive])}"
      Process.register(wb, name)

      assert on(:a, fn -> @m.nosuspend(wb, :by_pid) end)
      assert on(:a, fn -> @m.nosuspend({name, :b}, :by_name) end)
      assert taken(wb) == [:by_pid, :by_name]

      assert on(:a, fn -> @m.nosuspend({:nobody_here, :b}, :lost) end),
             "distribution loses a send to a name nobody holds, and says nothing"
    end

    test "an alias for a local name follows whoever holds it on that node" do
      mesh([:a, :b])
      local = :"eta_membership_#{System.unique_integer([:positive])}"
      :ok = @net.register_name(:b, :their_name, {:local, local})

      first = watcher(:b)
      Process.register(first, local)
      assert on(:a, fn -> @m.nosuspend({:their_name, :b}, :one) end)
      assert taken(first) == [:one]

      Process.unregister(local)
      second = watcher(:b)
      Process.register(second, local)
      assert on(:a, fn -> @m.nosuspend({:their_name, :b}, :two) end)
      assert taken(second) == [:two]
      assert taken(first) == []

      elsewhere = watcher(:a)
      Process.unregister(local)
      Process.register(elsewhere, local)
      assert @net.whereis_name(:b, :their_name) == :undefined
    end

    test "a real name only answers for the node its holder is on" do
      mesh([:a, :b, :c])
      wb = watcher(:b)
      name = :"eta_membership_#{System.unique_integer([:positive])}"
      Process.register(wb, name)

      assert on(:a, fn -> @m.nosuspend({name, :c}, :wrong_node) end)
      assert taken(wb) == []
    end

    test "noconnect refuses to send to a node it is not connected to" do
      mesh([:a, :b])
      wb = watcher(:b)
      assert on(:a, fn -> @m.disconnect(:b) end)
      _ = taken(wb)

      refute on(:a, fn -> @m.nosuspend_noconnect(wb, :refused) end)
      assert on(:a, fn -> @net.send(wb, :refused, [:noconnect]) end) == :noconnect
      assert taken(wb) == []
      assert on(:a, &@m.peers/0) == []
    end

    test "a busy link refuses send_nosuspend but not a plain send" do
      mesh([:a, :b])
      wb = watcher(:b)
      :ok = @net.set_policy(%{busy_p: 1.0, busy_ms: 60_000})

      refute on(:a, fn -> @m.nosuspend(wb, :refused) end)
      assert on(:a, fn -> @net.send(wb, :nosuspend_opt, [:nosuspend]) end) == :nosuspend
      on(:a, fn -> @net.send(wb, :plain) end)

      assert taken(wb) == [:plain]
      assert %{busy: 2, dropped: 0} = @net.stats()
    end

    test "a busy spell ends" do
      mesh([:a, :b])
      wb = watcher(:b)
      :ok = @net.set_policy(%{busy_p: 1.0, busy_ms: 1})
      refute on(:a, fn -> @m.nosuspend(wb, :refused) end)

      :ok = @net.set_policy(%{busy_p: 0.0})
      Process.sleep(5)
      assert on(:a, fn -> @m.nosuspend(wb, :through) end)
      assert taken(wb) == [:through]
    end

    test "busy is a property of a link, so an attached process is never refused" do
      :ok = @net.start(%{seed: 1, policy: %{busy_p: 1.0, busy_ms: 60_000}})
      on(:a, fn -> :ok end)
      wb = watcher(:b)
      :ok = @net.attach(:b, [wb])

      assert on(:a, fn -> @m.nosuspend(wb, :through) end)
      assert taken(wb) == [{:nodeup, :a}, :through], "without noconnect, it connects first"
    end
  end

  describe "node() in a guard" do
    setup do
      mesh([:a, :b])
    end

    test "compares against the simulated node, in every kind of clause" do
      for f <- [
            &@m.local_by_function_guard/1,
            &@m.local_by_case_guard/1,
            &@m.local_by_if/1,
            &@m.local_by_try_guard/1,
            &@m.nested/1
          ] do
        assert on(:a, fn -> f.(:a) end) == :local, inspect(f)
        assert on(:a, fn -> f.(:b) end) == :remote, inspect(f)
      end
    end

    test "in a receive" do
      assert on(:a, fn ->
               send(self(), {:node, :a})
               @m.local_by_receive_guard()
             end) == :local

      assert on(:a, fn ->
               send(self(), {:node, :b})
               @m.local_by_receive_guard()
             end) == :remote
    end

    test "in an anonymous function, read by whoever calls it" do
      f = @m.local_by_fun_guard()
      assert on(:a, fn -> f.(:a) end) == :local
      assert on(:b, fn -> f.(:a) end) == :remote
    end

    test "node(X) in a guard is refused at compile time" do
      src = """
      -module(eta_membership_refused).
      -export([local/1]).
      local(P) when node(P) =:= node() -> true;
      local(_) -> false.
      """

      assert {:eta_net, {:node_in_guard, 3, _}} = transform_error(src)
    end

    test "-eta_net(false) keeps a module out of it" do
      src = """
      -module(eta_membership_opted_out).
      -eta_net(false).
      -export([local/1]).
      local(P) when node(P) =:= node() -> true;
      local(_) -> false.
      """

      assert transform_error(src) == :none
    end
  end

  describe "Elixir" do
    @fixture """
    defmodule EtaMembershipFixture do
      def me, do: Node.self()
      def peers, do: Node.list()
      def connect(n), do: Node.connect(n)
      def disconnect(n), do: Node.disconnect(n)
      def ping(n), do: Node.ping(n)
      def alive?, do: Node.alive?()
      def local?(n) when n == node(), do: true
      def local?(_), do: false
      def mine?(pid), do: node(pid) == node()
    end
    """

    setup do
      dir = Path.join(System.tmp_dir!(), "eta_membership_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      src = Path.join(dir, "fixture.ex")
      File.write!(src, @fixture)
      orig = Code.compiler_options()[:debug_info]

      try do
        Code.put_compiler_option(:debug_info, true)

        {:ok, _, _} =
          Kernel.ParallelCompiler.compile_to_path([src], dir, return_diagnostics: true)
      after
        Code.put_compiler_option(:debug_info, orig)
      end

      Code.prepend_path(dir)
      [{EtaMembershipFixture, :instrumented}] = Eta.Beam.instrument([EtaMembershipFixture])

      on_exit(fn ->
        :code.purge(EtaMembershipFixture)
        :code.delete(EtaMembershipFixture)
        Code.delete_path(dir)
        File.rm_rf!(dir)
      end)

      mesh([:a, :b])
    end

    test "Node and the inlined BIFs answer for the simulated node" do
      f = EtaMembershipFixture
      assert on(:a, &f.me/0) == :a
      assert on(:a, &f.peers/0) == [:b]
      assert on(:a, &f.alive?/0)
      assert on(:a, fn -> f.local?(:a) end)
      refute on(:a, fn -> f.local?(:b) end)
      assert on(:a, fn -> f.mine?(self()) end)

      assert on(:a, fn -> f.disconnect(:b) end)
      assert on(:a, &f.peers/0) == []
      assert on(:a, fn -> f.connect(:b) end)
      assert on(:a, fn -> f.ping(:b) end) == :pong
    end
  end

  defp transform_error(src) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(src))

    forms =
      tokens
      |> Enum.chunk_while(
        [],
        fn
          {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
          tok, acc -> {:cont, [tok | acc]}
        end,
        fn acc -> {:cont, acc} end
      )
      |> Enum.reject(&(&1 == []))
      |> Enum.map(fn toks ->
        {:ok, form} = :erl_parse.parse_form(toks)
        form
      end)

    try do
      _ = :eta_transform.parse_transform(forms, [])
      :none
    catch
      :error, reason -> reason
    end
  end
end
