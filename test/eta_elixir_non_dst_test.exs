defmodule EtaElixirNonDstTest do
  @moduledoc """
  Tests for the non-DST macro expansion path.

  These tests compile modules at runtime using `Code.compile_string` with
  `dst?()` forced to `false`. This loads Elixir compiler modules that can
  interfere with `eta_run`'s `modules_loaded` tracking, so they live in a
  separate file from the determinism tests.
  """

  use ExUnit.Case, async: false

  describe "non-DST macro expansion" do
    test "Eta.dst?/0 returns true in this build" do
      assert Eta.dst?() == true
    end

    test "macros expand to stdlib when dst?() is false" do
      # Force dst?() to return false, compile a module, then verify the
      # compiled code calls stdlib functions, not :eta_* functions.
      Process.put(:__eta_dst_override__, false)

      Code.compile_string("""
      defmodule EtaElixir.NonDstTest do
        use Eta

        def test_send_after do
          Eta.send_after(self(), :tick, 0)
        end

        def test_monotonic_time do
          Eta.monotonic_time()
        end

        def test_send(dest, msg) do
          Eta.send(dest, msg)
        end
      end
      """)

      Process.delete(:__eta_dst_override__)

      # With dst?() false, send_after expands to Process.send_after.
      # A 0ms timer should deliver almost immediately.
      ref = EtaElixir.NonDstTest.test_send_after()
      assert is_reference(ref)
      assert_receive :tick, 1000

      # monotonic_time expands to :erlang.monotonic_time/0.
      assert is_integer(EtaElixir.NonDstTest.test_monotonic_time())

      # send expands to Kernel.send/2.
      EtaElixir.NonDstTest.test_send(self(), :hello)
      assert_receive :hello, 1000

      # Cleanup.
      :code.purge(EtaElixir.NonDstTest)
      :code.delete(EtaElixir.NonDstTest)
    end

    test "non-DST module does not call :eta_* functions" do
      Process.put(:__eta_dst_override__, false)

      # Enable debug_info so beam_lib can read the abstract code.
      Code.put_compiler_option(:debug_info, true)

      [{EtaElixir.NonDstBeamTest, beam_binary}] =
        Code.compile_string("""
        defmodule EtaElixir.NonDstBeamTest do
          use Eta

          def test_send_after do
            Eta.send_after(self(), :tick, 0)
          end

          def test_cast(server, msg) do
            Eta.cast(server, msg)
          end

          def test_spawn do
            Eta.spawn(fn -> :ok end)
          end
        end
        """)

      Process.delete(:__eta_dst_override__)

      # Inspect the beam abstract code to verify no :eta_* calls are present.
      {:ok, {EtaElixir.NonDstBeamTest, [abstract_code: {:raw_abstract_v1, abstract}]}} =
        :beam_lib.chunks(beam_binary, [:abstract_code])

      abstract_binary = :erlang.term_to_binary(abstract)

      # The compiled code should NOT reference eta_time, eta_net, eta_sched,
      # or eta_log modules.
      refute :binary.match(abstract_binary, "eta_time") != :nomatch,
             "non-DST module calls :eta_time"

      refute :binary.match(abstract_binary, "eta_net") != :nomatch,
             "non-DST module calls :eta_net"

      refute :binary.match(abstract_binary, "eta_sched") != :nomatch,
             "non-DST module calls :eta_sched"

      refute :binary.match(abstract_binary, "eta_log") != :nomatch,
             "non-DST module calls :eta_log"

      :code.purge(EtaElixir.NonDstBeamTest)
      :code.delete(EtaElixir.NonDstBeamTest)
    end
  end
end
