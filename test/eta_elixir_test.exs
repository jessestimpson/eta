defmodule DstElixirTest do
  @moduledoc """
  `Eta.Beam` — running `eta_transform` on modules the Elixir compiler built.

  Elixir compiles to the same Erlang abstract format `erlc` hands a
  `parse_transform`, and its inliner lowers `send/2`, `spawn/1`,
  `Process.monitor/1` and `Process.send_after/3` to the very `:erlang` calls
  the rewrite tables match — so the claim under test is that the transform
  applies to Elixir modules *unchanged*, given a mechanism that reaches the
  abstract format. `@compile {:parse_transform, ...}` is that mechanism today
  and is deprecated upstream, so `Eta.Beam` goes in after compilation instead,
  through the beam's `debug_info` chunk.

  These tests compile real Elixir source at run time — the same freshness
  argument `DstAfterTest` makes for its Erlang SUTs: a beam-rewriting test
  that exercises yesterday's beams is not a regression suite. One pipeline
  runs in `setup_all`, twice, and the tests read its outcomes:

  - calls land on `eta_net`/`eta_time`/`eta_sched` (via the imports chunk,
    the `DstHrlTest` trick);
  - the stamp makes a second pass a no-op, because the callback-wrapping
    passes are not idempotent and "transformed twice" must be unrepresentable;
  - opting out and not opting in both leave exactly what they should;
  - and the rewritten code *runs*: a 60-second Elixir `receive ... after`
    resolves by advancing the virtual clock, in milliseconds of real time.

  The named gap is asserted too: `'Elixir.GenServer'` survives untouched,
  because no `'Elixir.*'` entries exist in the rewrite tables yet. When that
  table work lands, the assertion below is the one to flip.
  """
  use ExUnit.Case, async: false

  # The SUT exists only after `setup_all` compiles it.
  @compile {:no_warn_undefined, EtaElixirSut}

  @fixtures """
  defmodule EtaElixirSut do
    use Eta

    def kick(pid) do
      send(pid, :hello)
      Process.send_after(pid, :later, 5_000)
      :timer.sleep(1)
      _ref = Process.monitor(pid)
      spawn(fn -> :ok end)
      GenServer.cast(pid, :poke)
    end

    def wait(timeout) do
      receive do
        :cancel -> :cancelled
      after
        timeout -> :timed_out
      end
    end
  end

  defmodule EtaElixirOptOut do
    use Eta
    @eta_net false

    def kick(pid) do
      send(pid, :hello)
      Process.send_after(pid, :later, 5_000)
    end
  end

  defmodule EtaElixirPlain do
    def ping(pid), do: send(pid, :ping)
  end
  """

  @no_debug_fixture """
  defmodule EtaElixirNoDebug do
    use Eta
    def ping(pid), do: send(pid, :ping)
  end
  """

  setup_all do
    dir = Path.join(System.tmp_dir!(), "eta_elixir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    src = Path.join(dir, "fixtures.ex")
    File.write!(src, @fixtures)

    nodbg_src = Path.join(dir, "no_debug.ex")
    File.write!(nodbg_src, @no_debug_fixture)

    # `mix compile` builds with debug info; compiling at *run time* defaults it
    # off, so it is set explicitly both ways here — on for the fixtures that
    # stand in for ordinary project modules, off for the one pinning the
    # refusal. Global compiler state, hence restored and `async: false`.
    orig = Code.compiler_options()[:debug_info]

    try do
      Code.put_compiler_option(:debug_info, true)
      {:ok, _, _} = Kernel.ParallelCompiler.compile_to_path([src], dir, return_diagnostics: true)

      Code.put_compiler_option(:debug_info, false)

      {:ok, _, _} =
        Kernel.ParallelCompiler.compile_to_path([nodbg_src], dir, return_diagnostics: true)
    after
      Code.put_compiler_option(:debug_info, orig)
    end

    plain_before = File.read!(Path.join(dir, "Elixir.EtaElixirPlain.beam"))

    pass1 = run_pass(dir)
    sut_after_pass1 = File.read!(Path.join(dir, "Elixir.EtaElixirSut.beam"))
    pass2 = run_pass(dir)

    {:ok,
     dir: dir,
     pass1: pass1,
     pass2: pass2,
     plain_before: plain_before,
     sut_after_pass1: sut_after_pass1}
  end

  defp run_pass(dir) do
    Map.new(Eta.Beam.transform_path(dir), fn {path, outcome} ->
      {Path.basename(path), outcome}
    end)
  end

  defp beam(mod), do: "#{mod}.beam"

  # Every module this beam calls into — the imports chunk, as in DstHrlTest.
  defp calls(dir, mod) do
    file = dir |> Path.join(beam(mod)) |> String.to_charlist()
    {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(file, [:imports])
    imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  describe "the mechanism" do
    test "an opted-in module's calls are pointed at eta", %{dir: dir, pass1: pass1} do
      assert pass1[beam(EtaElixirSut)] == :transformed

      called = calls(dir, EtaElixirSut)

      # `send/2`, `Process.monitor/1` — inlined by Elixir to `:erlang` calls
      # the net pass rewrites.
      assert :eta_net in called
      # `Process.send_after/3` (inlined, arguments reordered), `:timer.sleep/1`,
      # and the armed `receive ... after`.
      assert :eta_time in called
      # `spawn/1`, inlined to `:erlang.spawn/1`.
      assert :eta_sched in called

      refute :timer in called,
             "timer:sleep/1 survived the rewrite"
    end

    test "the Elixir stdlib delegations are still the named gap", %{dir: dir} do
      # `GenServer.cast/2` delegates inside Elixir's stdlib, where no transform
      # of user code reaches, and the rewrite tables carry no 'Elixir.*'
      # entries yet. This is the prototype's boundary, pinned so the table
      # work has a test to flip when it lands.
      assert :"Elixir.GenServer" in calls(dir, EtaElixirSut)
    end

    test "a module that did not opt in is untouched", %{
      dir: dir,
      pass1: pass1,
      plain_before: plain_before
    } do
      assert pass1[beam(EtaElixirPlain)] == :not_opted_in

      assert File.read!(Path.join(dir, beam(EtaElixirPlain))) == plain_before,
             "a beam with no `use Eta` was rewritten"
    end

    test "the stamp makes a second pass free, not fatal", %{
      dir: dir,
      pass2: pass2,
      sut_after_pass1: sut_after_pass1
    } do
      # The passes that wrap callbacks are not idempotent, so this is a
      # correctness property rather than an optimisation.
      assert pass2[beam(EtaElixirSut)] == :already_transformed

      assert File.read!(Path.join(dir, beam(EtaElixirSut))) == sut_after_pass1,
             "a stamped beam changed on the second pass"
    end

    test "@eta_net false opts out of the network pass and keeps the clock", %{
      dir: dir,
      pass1: pass1
    } do
      # The same split `-eta_net(false).` gives an Erlang module: sends stay
      # raw, but timers still land on `eta_time` — proof the persisted Elixir
      # attribute reaches the gating pass in the shape it already matches.
      assert pass1[beam(EtaElixirOptOut)] == :transformed

      called = calls(dir, EtaElixirOptOut)
      refute :eta_net in called, "@eta_net false did not disable the network pass"
      assert :eta_time in called
    end

    test "a beam without debug info is refused by name", %{pass1: pass1} do
      # Silently skipping it would ship real-clock code into a simulation with
      # nothing reporting it — the failure mode the transform's defaults exist
      # to prevent.
      assert pass1[beam(EtaElixirNoDebug)] == {:error, :debug_info_missing}
    end
  end

  describe "the rewritten code runs" do
    setup %{dir: dir} do
      # Load the transformed beam explicitly rather than trusting whichever
      # version the compiler left in the VM.
      file = Path.join(dir, beam(EtaElixirSut))
      :code.purge(EtaElixirSut)

      {:module, EtaElixirSut} =
        :code.load_binary(EtaElixirSut, String.to_charlist(file), File.read!(file))

      :ok = :eta_time.start()
      on_exit(fn -> :eta_time.stop() end)
      :ok
    end

    test "a 60s Elixir receive-after resolves by advancing the clock" do
      parent = self()

      {result, elapsed} =
        real_ms(fn ->
          pid = spawn(fn -> send(parent, {:result, self(), EtaElixirSut.wait(60_000)}) end)
          await_armed()
          assert :eta_time.next_deadline() == 60_000
          assert :eta_time.advance_to_next()
          await(pid)
        end)

      assert result == :timed_out
      assert :eta_time.now_ms() == 60_000

      assert elapsed < 1_000,
             "a virtual 60s timeout cost #{elapsed}ms of real time"
    end
  end

  describe "the mix compiler task" do
    test "reports noop over a compile path with nothing opted in" do
      # eta's own build: Erlang modules and this library's Elixir surface,
      # none carrying the marker. Also the proof the walk is harmless to run
      # over beams that want nothing from it.
      assert Mix.Tasks.Compile.Eta.run([]) == {:noop, []}
    end
  end

  defp real_ms(fun) do
    t0 = System.monotonic_time(:millisecond)
    r = fun.()
    {r, System.monotonic_time(:millisecond) - t0}
  end

  defp await(pid, timeout \\ 2_000) do
    receive do
      {:result, ^pid, r} -> r
    after
      timeout -> :no_answer
    end
  end

  # Wait for the SUT process to reach its receive and arm its virtual timer.
  defp await_armed(deadline \\ 200)
  defp await_armed(0), do: flunk("the SUT never armed a virtual timer")

  defp await_armed(n) do
    if :eta_time.pending() > 0 do
      :ok
    else
      Process.sleep(1)
      await_armed(n - 1)
    end
  end
end
