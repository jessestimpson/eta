defmodule EtaInstrumentTest do
  @moduledoc """
  Running a system whose stack the project does not own.

  `Eta.Beam.instrument/1` rewrites compiled modules in memory, and the tests below
  it pin what a real supervision tree needs from the scheduler once that stack is
  on the schedule: supervisors start, a child killed mid-start is reported, and
  `release/1` sends nothing to the servers it lets go.
  """
  use ExUnit.Case, async: false

  @fixture """
  defmodule EtaInstrumentFixture do
    def now, do: System.monotonic_time(:millisecond)
  end
  """

  @mod EtaInstrumentFixture
  @compile {:no_warn_undefined, EtaInstrumentFixture}

  defmodule EmptySup do
    @behaviour :supervisor
    @impl true
    def init(_), do: {:ok, {%{strategy: :one_for_one}, []}}
  end

  defmodule SuicidalInit do
    use GenServer
    @impl true
    def init(_) do
      Process.exit(self(), :kill)
      Process.sleep(:infinity)
    end
  end

  defmodule Forwarder do
    use GenServer
    @impl true
    def init(parent), do: {:ok, parent}
    @impl true
    def handle_info(message, parent) do
      send(parent, {:forwarded, message})
      {:noreply, parent}
    end
  end

  setup_all do
    :ok = :eta_run.preload([])

    dir = Path.join(System.tmp_dir!(), "eta_instrument_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "fixture.ex")
    File.write!(src, @fixture)

    orig = Code.compiler_options()[:debug_info]

    try do
      Code.put_compiler_option(:debug_info, true)
      {:ok, _, _} = Kernel.ParallelCompiler.compile_to_path([src], dir, return_diagnostics: true)
    after
      Code.put_compiler_option(:debug_info, orig)
    end

    Code.prepend_path(dir)

    on_exit(fn ->
      Code.delete_path(dir)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir, beam: Path.join(dir, "Elixir.EtaInstrumentFixture.beam")}
  end

  defp under_scheduler(fun) do
    sched = :eta_sched.new(%{seed: 1})
    parent = self()
    caller = :eta_sched.spawn(fn -> send(parent, {:result, fun.()}) end)

    sched =
      sched
      |> :eta_sched.register([caller])
      |> :eta_sched.run(2000)

    :ok = :eta_sched.release(sched)

    receive do
      {:result, r} -> r
    after
      2000 -> flunk("the gated caller never finished")
    end
  end

  describe "instrument/1" do
    test "rewrites in memory, leaves the beam alone, and lets calls through", %{beam: beam} do
      on_disk = File.read!(beam)

      sched = :eta_sched.new()

      try do
        assert {:eta_sched, {:unsupported, {@mod, :now, 0}, _}} =
                 catch_error(:eta_sched.unsupported({@mod, :now, 0}, []))
      after
        :eta_sched.release(sched)
      end

      assert [{@mod, :instrumented}] = Eta.Beam.instrument([@mod])
      assert File.read!(beam) == on_disk

      :ok = :eta_time.start(%{start_ms: 1234})

      try do
        assert @mod.now() == 1234
      after
        :eta_time.stop()
      end

      sched = :eta_sched.new()

      try do
        assert is_integer(:eta_sched.unsupported({@mod, :now, 0}, []))
      after
        :eta_sched.release(sched)
      end

      assert [{@mod, :already_transformed}] = Eta.Beam.instrument([@mod])
    end

    test "skips a module `mix compile.eta` already rewrote on disk", %{dir: dir} do
      src = Path.join(dir, "stamped.ex")
      File.write!(src, "defmodule EtaInstrumentStamped do\n  use Eta\nend\n")
      orig = Code.compiler_options()[:debug_info]

      try do
        Code.put_compiler_option(:debug_info, true)

        {:ok, _, _} =
          Kernel.ParallelCompiler.compile_to_path([src], dir, return_diagnostics: true)
      after
        Code.put_compiler_option(:debug_info, orig)
      end

      :transformed = Eta.Beam.transform(Path.join(dir, "Elixir.EtaInstrumentStamped.beam"))
      :code.purge(EtaInstrumentStamped)
      :code.delete(EtaInstrumentStamped)

      assert [{EtaInstrumentStamped, :already_transformed}] =
               Eta.Beam.instrument([EtaInstrumentStamped])
    end

    test "reports a module it cannot find" do
      assert [{EtaNoSuchModule, {:error, {:no_object_code, EtaNoSuchModule}}}] =
               Eta.Beam.instrument([EtaNoSuchModule])
    end
  end

  describe "gated starts" do
    test "a supervisor starts, despite the idle hibernation OTP 28 asks for" do
      assert {:ok, pid} =
               under_scheduler(fn ->
                 :eta_sched.start(:supervisor, {:self, EmptySup, []}, [])
               end)

      assert Supervisor.which_children(pid) == []
      Process.exit(pid, :kill)
    end

    test "a parent trapping exits hears about a child killed mid-start" do
      assert {:error, :killed} =
               under_scheduler(fn ->
                 Process.flag(:trap_exit, true)
                 :eta_sched.start_link(SuicidalInit, [], [])
               end)
    end

    test "an unlinked parent hears about a child killed mid-start" do
      assert {:error, :killed} =
               under_scheduler(fn -> :eta_sched.start(SuicidalInit, [], []) end)
    end
  end

  describe "eta_ets" do
    setup do
      table = :ets.new(:eta_ets_test, [:set, :public])
      ordered = :ets.new(:eta_ets_ordered, [:ordered_set, :public])
      refs = for _ <- 1..200, do: make_ref()
      for ref <- refs, do: :ets.insert(table, {ref, :v})
      for n <- 1..5, do: :ets.insert(ordered, {n, 6 - n})
      {:ok, table: table, ordered: ordered, refs: refs}
    end

    test "sorts a hash-based table under a run", %{table: table, refs: refs} do
      sorted = refs |> Enum.map(&{&1, :v}) |> Enum.sort()
      sched = :eta_sched.new()

      try do
        assert :eta_ets.tab2list(table) == sorted
        assert :eta_ets.select(table, [{:"$1", [], [:"$1"]}]) == sorted
        assert :eta_ets.match_object(table, {:_, :v}) == sorted
        assert :eta_ets.foldl(&[&1 | &2], [], table) == Enum.reverse(sorted)
      after
        :eta_sched.release(sched)
      end
    end

    test "leaves an ordered_set's own order alone", %{ordered: ordered} do
      # Selecting the value gives 5..1, the key order, which sorting would undo.
      sched = :eta_sched.new()

      try do
        assert :eta_ets.select(ordered, [{{:_, :"$1"}, [], [:"$1"]}]) == [5, 4, 3, 2, 1]
      after
        :eta_sched.release(sched)
      end
    end

    test "is inert with no scheduler running", %{table: table} do
      refute :eta_sched.active()
      assert :eta_ets.tab2list(table) == :ets.tab2list(table)
    end

    test "raises as ets does for a missing table" do
      assert_raise ArgumentError, fn -> :eta_ets.tab2list(:eta_no_such_table) end
    end
  end

  test "release/1 sends nothing to a server it lets go" do
    parent = self()
    assert {:ok, pid} = under_scheduler(fn -> :eta_sched.start(Forwarder, parent, []) end)

    refute_receive {:forwarded, _}, 100
    GenServer.stop(pid)
  end
end
