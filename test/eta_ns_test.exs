defmodule EtaNsTest do
  @moduledoc """
  A namespace per simulated node, and `rpc` between nodes.

  Three simulated nodes are one VM, so a system started on each of them registers
  the same names, creates the same named tables and writes the same
  `persistent_term` keys. `eta_ns` gives each node its own, with the VM's as the
  fallback, and `eta_rpc` runs an `rpc` on the node it names. The bar:

  1. **Each node sees its own.** The same name on two nodes is two things.
  2. **The VM is still there.** A name a node never made resolves to the VM's.
  3. **Nothing changes off a node.** A process on no node, or a run with no
     network, gets the BIFs.
  4. **`rpc` runs where it says.** On the named node, over the network, and it
     fails the way `rpc` fails.
  """
  use ExUnit.Case, async: false

  @net :eta_net
  @f :eta_ns_fixture

  setup do
    on_exit(fn ->
      @net.stop()
      :eta_time.stop()
    end)

    :ok
  end

  # Runs `fun` in a fresh process placed on `node`, and returns its result.
  defp on(node, fun) do
    ref = async_on(node, fun)
    await(ref)
  end

  defp async_on(node, fun) do
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
    ref
  end

  defp await(ref, timeout \\ 2_000) do
    receive do
      {^ref, result} -> result
    after
      timeout -> flunk("no answer")
    end
  end

  # A process on `node` that stays alive for the rest of the test, registered as
  # `name` by itself.
  defp registered_on(node, name) do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go ->
            true = @f.reg(name)
            send(parent, :registered)
            hold(parent)
        end
      end)

    # Killed with its test, so a message that arrives later lands nowhere.
    on_exit(fn -> Process.exit(pid, :kill) end)
    :ok = @net.place(node, [pid])
    send(pid, :go)
    assert_receive :registered
    pid
  end

  # Anything it receives goes to the test that started it. Never to itself: it
  # would take its own report as a message, report that, and so on, building an
  # ever-deeper term until the VM runs out of memory.
  defp hold(owner) do
    receive do
      {:__take__, from, ref} ->
        send(from, {ref, :taken})
        hold(owner)

      msg ->
        send(owner, {:held, self(), msg})
        hold(owner)
    end
  end

  defp uniq(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start do
    :ok = @net.start(%{seed: 1})
  end

  describe "registered names" do
    setup do
      start()
    end

    test "the same name on two nodes is two processes" do
      name = uniq(:ns)
      a = registered_on(:a, name)
      b = registered_on(:b, name)

      assert a != b
      assert on(:a, fn -> @f.where(name) end) == a
      assert on(:b, fn -> @f.where(name) end) == b
      assert on(:c, fn -> @f.where(name) end) == :undefined
      assert Process.whereis(name) == nil, "nothing was registered under the bare name"
    end

    test "a node's own names come back without the prefix" do
      name = uniq(:ns)
      _ = registered_on(:a, name)
      assert name in on(:a, &@f.names/0)
      refute name in on(:b, &@f.names/0)

      pid = registered_on(:b, name)

      assert on(:b, fn -> :eta_ns.process_info(pid, :registered_name) end) ==
               {:registered_name, name}
    end

    test "a name a node never registered is the VM's" do
      name = uniq(:vm)
      Process.register(self(), name)
      assert on(:a, fn -> @f.where(name) end) == self()
    end

    test "a send by name reaches the node's own process" do
      name = uniq(:ns)
      a = registered_on(:a, name)
      b = registered_on(:b, name)
      :erlang.trace(a, true, [:receive])
      :erlang.trace(b, true, [:receive])

      on(:a, fn -> @f.send_named(name, :to_a) end)
      on(:a, fn -> @f.send_named({name, :b}, :to_b) end)

      assert_receive {:trace, ^a, :receive, :to_a}
      assert_receive {:trace, ^b, :receive, :to_b}
      refute_receive {:trace, ^b, :receive, :to_a}
    end

    test "a timer addressed by name fires at the node's own process" do
      name = uniq(:ns)
      b = registered_on(:b, name)
      :erlang.trace(b, true, [:receive])
      on(:b, fn -> @f.named_timer(1, name, :tick) end)
      assert_receive {:trace, ^b, :receive, :tick}
    end

    test "measuring the stack is still the BIF" do
      assert is_integer(on(:a, &@f.stack_size/0))
    end
  end

  describe "named ETS tables" do
    setup do
      start()
    end

    test "the same name on two nodes is two tables" do
      name = uniq(:tab)
      parent = self()

      # Tables die with their owner, so the owners stay alive for the test.
      for node <- [:a, :b] do
        pid =
          spawn(fn ->
            receive do
              :go ->
                :ok = @f.table(name)
                send(parent, {:made, node})
                Process.sleep(:infinity)
            end
          end)

        :ok = @net.place(node, [pid])
        send(pid, :go)
        assert_receive {:made, ^node}
      end

      assert on(:a, fn -> @f.read(name) end) == [{:k, :a}]
      assert on(:b, fn -> @f.read_all(name) end) == [{:k, :b}]
      assert :ets.whereis(name) == :undefined
    end

    test "a table a node never made is the VM's" do
      name = uniq(:vm_tab)
      :ets.new(name, [:named_table, :public])
      :ets.insert(name, {:k, :vm})
      assert on(:a, fn -> @f.read(name) end) == [{:k, :vm}]
    end
  end

  describe "persistent_term" do
    setup do
      start()
    end

    test "each node has its own value, and falls back to the VM's" do
      key = {__MODULE__, make_ref()}
      on(:a, fn -> @f.pt_put(key, :a) end)
      on(:b, fn -> @f.pt_put(key, :b) end)

      assert on(:a, fn -> @f.pt_get(key) end) == :a
      assert on(:b, fn -> @f.pt_get(key) end) == :b
      assert on(:c, fn -> @f.pt_get(key) end) == :undefined

      :persistent_term.put(key, :vm)
      assert on(:c, fn -> @f.pt_get(key) end) == :vm
      assert on(:a, fn -> @f.pt_get(key) end) == :a
    end
  end

  describe "off a node" do
    test "with no network, the calls are the BIFs" do
      name = uniq(:plain)
      assert @f.reg(name)
      assert Process.whereis(name) == self()
      assert @f.where(name) == self()
      Process.unregister(name)
    end

    test "a process on no node sees the VM's namespace, unless it acts for one" do
      start()
      name = uniq(:ns)
      a = registered_on(:a, name)
      assert @f.where(name) == :undefined
      assert @net.with_node(:a, fn -> @f.where(name) end) == a
    end
  end

  describe "gated starts" do
    test "the same named server starts once on each node" do
      start()
      {:module, _} = Code.ensure_loaded(:eta_net_echo)
      name = uniq(:echo)
      parent = self()
      # The scheduler first: a spawn with none running is a plain one.
      sched = :eta_sched.new(%{seed: 1})

      starter = fn node ->
        pid =
          :eta_sched.spawn(fn ->
            {:ok, server} = :eta_net_echo.start_link(name)
            send(parent, {:started, node, server})
          end)

        :ok = @net.place(node, [pid])
        pid
      end

      a = starter.(:a)
      b = starter.(:b)

      sched =
        sched
        |> :eta_sched.register([a, b])
        |> :eta_sched.run(2_000)

      assert_receive {:started, :a, server_a}
      assert_receive {:started, :b, server_b}
      :ok = :eta_sched.release(sched)

      assert server_a != server_b
      assert @net.with_node(:a, fn -> @f.where(name) end) == server_a
      assert @net.with_node(:b, fn -> @f.where(name) end) == server_b
    end
  end

  describe "rpc" do
    setup do
      start()
      # A node is up once something is on it; `rpc` to one that isn't fails.
      for n <- [:a, :b, :c], do: on(n, fn -> :ok end)
      :ok
    end

    test "runs on the node it names" do
      assert on(:a, fn -> @f.rpc(:b, @f, :whoami, []) end) == :b
      assert on(:a, fn -> @f.erpc(:c, @f, :whoami, []) end) == :c
      assert on(:a, fn -> @f.erpc_fun(:b, fn -> @f.whoami() end) end) == :b
    end

    test "sees the target node's namespace" do
      key = {__MODULE__, make_ref()}
      on(:b, fn -> @f.pt_put(key, :bs) end)
      assert on(:a, fn -> @f.rpc(:b, @f, :pt_get, [key]) end) == :bs
    end

    test "travels the network, and connects as it goes" do
      assert on(:a, fn -> @net.nodes() end) == []
      assert on(:a, fn -> @f.rpc(:b, @f, :whoami, []) end) == :b
      assert on(:a, fn -> @net.nodes() end) == [:b]
      assert %{delivered: delivered} = @net.stats()
      # The reply is the worker's exit, a signal rather than a message.
      assert delivered >= 1, "the request"
    end

    test "reports what the function did, as rpc and erpc each do" do
      assert on(:a, fn -> @f.rpc(:b, @f, :raise, [:throw]) end) == :thrown

      assert {:badrpc, {:EXIT, {:broken, [_ | _]}}} =
               on(:a, fn -> @f.rpc(:b, @f, :raise, [:error]) end)

      assert on(:a, fn -> @f.rpc(:b, @f, :raise, [:exit]) end) == {:badrpc, {:EXIT, :gone}}

      assert on(:a, fn -> catch_throw(@f.erpc(:b, @f, :raise, [:throw])) end) == :thrown

      assert {:exception, :broken, [_ | _]} =
               on(:a, fn -> catch_error(@f.erpc(:b, @f, :raise, [:error])) end)

      assert on(:a, fn -> catch_exit(@f.erpc(:b, @f, :raise, [:exit])) end) == {:exception, :gone}
    end

    test "fails as nodedown across a partition" do
      :ok = @net.partition(:a, :b)
      assert on(:a, fn -> @f.rpc(:b, @f, :whoami, []) end) == {:badrpc, :nodedown}
      assert on(:a, fn -> catch_error(@f.erpc(:b, @f, :whoami, [])) end) == {:erpc, :noconnection}
    end

    test "a partition while the call is out ends it" do
      ref = async_on(:a, fn -> @f.rpc(:b, @f, :stall, []) end)
      Process.sleep(50)
      :ok = @net.partition(:a, :b)
      assert await(ref) == {:badrpc, :nodedown}
    end

    test "times out, and the worker goes with it" do
      assert on(:a, fn -> @f.rpc(:b, @f, :stall, []) end) == {:badrpc, :timeout}
      assert on(:a, fn -> catch_error(@f.erpc(:b, @f, :stall, [])) end) == {:erpc, :timeout}
    end

    test "a cast runs on the node and nothing waits" do
      key = {__MODULE__, make_ref()}
      assert on(:a, fn -> @f.rpc_cast(:b, @f, :pt_put, [key, :cast]) end) == true
      Process.sleep(50)
      assert @net.with_node(:b, fn -> @f.pt_get(key) end) == :cast
    end

    test "a call to a node the network does not know is the real one" do
      assert on(:a, fn -> @f.rpc(:nowhere@nohost, @f, :whoami, []) end) == {:badrpc, :nodedown}
    end
  end

  describe "monitoring a name on a simulated node" do
    setup do
      start()
      for n <- [:a, :b, :c], do: on(n, fn -> :ok end)
      :ok
    end

    test "nothing holds it on a live node: noproc, and the nodes connect" do
      name = uniq(:nobody)
      assert on(:a, fn -> @f.monitor_name(name, :b) end) == {{name, :b}, :noproc}
      assert on(:a, fn -> @net.nodes() end) == [:b]
    end

    test "nothing holds it on the caller's own node: noproc" do
      name = uniq(:nobody)
      assert on(:a, fn -> @f.monitor_name(name, :a) end) == {{name, :a}, :noproc}
    end

    test "the node was killed: noconnection, not badarg" do
      name = uniq(:server)
      registered_on(:b, name)
      :ok = @net.kill_node(:b)
      assert on(:a, fn -> @f.monitor_name(name, :b) end) == {{name, :b}, :noconnection}
    end

    test "the node is across a cut: noconnection" do
      :ok = @net.partition(:a, :c)
      assert on(:a, fn -> @f.monitor_name(uniq(:nobody), :c) end) |> elem(1) == :noconnection
    end
  end

  describe "distributed spawn" do
    setup do
      start()
      for n <- [:a, :b, :c], do: on(n, fn -> :ok end)
      :ok
    end

    test "the child runs on the node it names" do
      me = self()
      pid = on(:a, fn -> @f.spawn_on(:b, me) end)
      assert_receive {:node_of, ^pid, :b}
      pid = on(:a, fn -> @f.spawn_fun_on(:c, me) end)
      assert_receive {:node_of, ^pid, :c}
    end

    test "to the caller's own node is a local spawn" do
      me = self()
      pid = on(:a, fn -> @f.spawn_on(:a, me) end)
      assert_receive {:node_of, ^pid, :a}
    end

    test "connects, as distribution does" do
      assert on(:a, fn -> @net.nodes() end) == []
      me = self()
      on(:a, fn -> @f.spawn_on(:b, me) end)
      assert_receive {:node_of, _, :b}
      assert on(:a, fn -> @net.nodes() end) == [:b]
    end

    test "across a partition the child exits noconnection" do
      :ok = @net.partition(:a, :b)
      assert on(:a, fn -> @f.spawn_monitor_on(:b) end) == :noconnection
      # And with the link up, the same spawn runs to completion.
      assert on(:a, fn -> @f.spawn_monitor_on(:c) end) == :normal
    end

    test "a node the network does not know is the real spawn" do
      # No run is active, so it delegates to the VM, which cannot reach it.
      assert on(:a, fn -> @f.spawn_monitor_on(:nowhere@nohost) end) == :noconnection
    end
  end
end
