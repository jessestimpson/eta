defmodule EtaDiskTest do
  @moduledoc """
  `:eta_disk` — the simulated disk.

  The claims under test: data that a system synced survives a crash, data that
  it did not sync is lost or torn as the seed decides, and with no disk running
  the rewritten `file` calls behave as `file` does.
  """
  use ExUnit.Case, async: false

  @disk :eta_disk
  @fix :eta_disk_fixture
  @seeds 1..60

  setup do
    dir = Path.join(System.tmp_dir!(), "eta_disk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      @disk.stop()
      :eta_net.stop()
      :eta_time.stop()
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp file(dir, seed, name \\ "f") do
    sub = Path.join(dir, Integer.to_string(seed))
    File.mkdir_p!(sub)
    String.to_charlist(Path.join(sub, name))
  end

  # Runs `fun` once for each seed, with a fresh disk, and returns the results.
  defp each_seed(policy \\ %{}, fun) do
    for seed <- @seeds do
      :ok = @disk.start(%{seed: seed, policy: policy})
      fun.(seed)
    end
  end

  describe "inert" do
    test "with no disk running, the rewritten calls behave as file does", %{dir: dir} do
      refute @disk.running()
      f = file(dir, 0)

      assert {:ok, :ok} = @fix.append(f, "abc", false)
      assert :ok = @fix.replace(f, "xyz", :all)
      assert {:ok, "xyz"} = @fix.read(f)
      assert :ok = @fix.remove(f, true)
      assert {:error, :enoent} = @fix.read(f)
    end
  end

  describe "a crash" do
    test "keeps synced contents and a prefix of unsynced contents", %{dir: dir} do
      results =
        each_seed(fn seed ->
          f = file(dir, seed)
          {:ok, :ok} = @fix.append(f, "synced.", true)
          :ok = @fix.create(f ++ ~c".dirsync", true)
          {:ok, :ok} = @fix.append(f, "unsynced", false)
          # Every reader sees unsynced data until the crash.
          assert {:ok, "synced.unsynced"} = @fix.read(f)

          :ok = @disk.crash(node())
          {:ok, left} = @fix.read(f)
          left
        end)

      for left <- results do
        assert String.starts_with?(left, "synced.")
        assert String.starts_with?("synced.unsynced", left)
      end

      # The seed decides. Over the seeds, every outcome occurs.
      assert "synced." in results
      assert "synced.unsynced" in results
      assert Enum.any?(results, &(byte_size(&1) in 8..14)), "no torn write in #{inspect(results)}"
    end

    test "loses nothing that was synced", %{dir: dir} do
      each_seed(fn seed ->
        f = file(dir, seed)
        :ok = @fix.create(f, true)
        :ok = @fix.overwrite(f, "first", true)
        {:ok, :ok} = @fix.append(f, ".second", true)
        :ok = @disk.crash(node())
        assert {:ok, "first.second"} = @fix.read(f)
        assert %{files_lost: 0, files_torn: 0, ops_undone: 0, crashes: 1} = @disk.stats()
      end)
    end

    test "leaves an overwritten file as it was or as it became", %{dir: dir} do
      results =
        each_seed(fn seed ->
          f = file(dir, seed)
          :ok = @fix.create(f, true)
          :ok = @fix.overwrite(f, "old contents", true)
          :ok = @fix.overwrite(f, "new", false)
          :ok = @disk.crash(node())
          {:ok, left} = @fix.read(f)
          left
        end)

      assert Enum.sort(Enum.uniq(results)) == ["new", "old contents"]
    end

    test "undoes directory operations that the directory sync did not cover", %{dir: dir} do
      results =
        each_seed(fn seed ->
          kept = file(dir, seed, "kept")
          gone = file(dir, seed, "gone")
          new = file(dir, seed, "new")
          :ok = @fix.create(kept, false)
          :ok = @fix.create(gone, true)
          # The sync of the directory covers both creations.
          :ok = @fix.remove(gone, false)
          :ok = @fix.create(new, false)
          :ok = @disk.crash(node())
          {@fix.read(kept), @fix.read(gone), @fix.read(new)}
        end)

      for {kept, gone, new} <- results do
        # `kept` was created before the sync of the directory. Its contents
        # were never synced, so a prefix of them remains.
        assert {:ok, left} = kept
        assert String.starts_with?("created", left)
        # The removal comes before the creation of `new`. A crash keeps a
        # prefix of the operations, so `new` exists only if `gone` is gone.
        case {gone, new} do
          # The contents of `gone` were never synced, so a removal that is
          # undone restores a file with no contents.
          {{:ok, ""}, {:error, :enoent}} -> :ok
          {{:error, :enoent}, {:error, :enoent}} -> :ok
          {{:error, :enoent}, {:ok, _}} -> :ok
        end
      end

      shapes = Enum.uniq(for {_, gone, new} <- results, do: {elem(gone, 0), elem(new, 0)})
      assert length(shapes) == 3, "the seeds produced only #{inspect(shapes)}"
    end

    test "an atomic replace leaves the old file or the new file", %{dir: dir} do
      for sync <- [:none, :file, :all] do
        results =
          each_seed(fn seed ->
            f = file(dir, seed, "replace_#{sync}")
            :ok = @fix.create(f, true)
            :ok = @fix.overwrite(f, "old", true)
            :ok = @fix.replace(f, "new", sync)
            :ok = @disk.crash(node())
            {:ok, left} = @fix.read(f)
            left
          end)

        case sync do
          # Everything was synced.
          :all -> assert Enum.uniq(results) == ["new"]
          # The rename may be lost. The contents of the new file may not.
          :file -> assert Enum.sort(Enum.uniq(results)) == ["new", "old"]
          # A system that renames an unsynced file can lose the contents of
          # both. This is the bug that the sync of the temporary file prevents.
          :none -> assert Enum.any?(results, &(&1 not in ["new", "old"]))
        end
      end
    end

    test "is a function of the seed", %{dir: dir} do
      run = fn tag ->
        each_seed(fn seed ->
          f = file(dir, seed, tag)
          {:ok, :ok} = @fix.append(f, "a long run of unsynced bytes", false)
          :ok = @disk.crash(node())
          {@fix.read(f), @disk.stats()}
        end)
      end

      assert run.("one") == run.("two")
    end
  end

  describe "kill_node" do
    test "crashes the disk of the node it kills, and of no other", %{dir: dir} do
      results =
        each_seed(fn seed ->
          :ok = :eta_time.start(%{seed: seed})
          :ok = :eta_net.start(%{seed: seed})
          a = spawn(fn -> Process.sleep(:infinity) end)
          b = spawn(fn -> Process.sleep(:infinity) end)
          :ok = :eta_net.place(:na, [a])
          :ok = :eta_net.place(:nb, [b])
          fa = file(dir, seed, "a")
          fb = file(dir, seed, "b")
          # The creation of each file is made durable, so that only the
          # contents are at stake.
          :ok = :eta_net.with_node(:na, fn -> @fix.create(fa, true) end)
          :ok = :eta_net.with_node(:na, fn -> @fix.overwrite(fa, "", true) end)
          :ok = :eta_net.with_node(:nb, fn -> @fix.create(fb, true) end)
          :ok = :eta_net.with_node(:nb, fn -> @fix.overwrite(fb, "", true) end)
          {:ok, :ok} = :eta_net.with_node(:na, fn -> @fix.append(fa, "unsynced", false) end)
          {:ok, :ok} = :eta_net.with_node(:nb, fn -> @fix.append(fb, "unsynced", false) end)

          :ok = :eta_net.kill_node(:na)
          assert {:ok, "unsynced"} = @fix.read(fb)
          {:ok, left} = @fix.read(fa)
          Process.exit(b, :kill)
          left
        end)

      assert "" in results
      assert "unsynced" in results
    end

    test "keeps the files when the policy says so", %{dir: dir} do
      each_seed(%{lose_on_kill: false}, fn seed ->
        :ok = :eta_time.start(%{seed: seed})
        :ok = :eta_net.start(%{seed: seed})
        a = spawn(fn -> Process.sleep(:infinity) end)
        :ok = :eta_net.place(:na, [a])
        f = file(dir, seed)
        {:ok, :ok} = :eta_net.with_node(:na, fn -> @fix.append(f, "unsynced", false) end)
        :ok = :eta_net.kill_node(:na)
        assert {:ok, "unsynced"} = @fix.read(f)
      end)
    end
  end

  describe "errors" do
    test "a failed write stores a prefix and a failed sync leaves the data unsynced", %{dir: dir} do
      results =
        each_seed(%{error_p: 0.5}, fn seed ->
          f = file(dir, seed)
          # The file is created and made durable with no errors, so that only
          # the append is under test.
          :ok = @disk.set_policy(%{})
          :ok = @fix.create(f, true)
          :ok = @fix.overwrite(f, "", true)
          :ok = @disk.set_policy(%{error_p: 0.5})
          result = @fix.append(f, "0123456789", true)
          {:ok, written} = @fix.read(f)
          :ok = @disk.crash(node())
          {:ok, left} = @fix.read(f)
          {result, written, left}
        end)

      for {result, written, left} <- results do
        case result do
          {:ok, :ok} ->
            assert written == "0123456789"
            assert left == "0123456789"

          {:ok, {:error, :eio}} ->
            assert written == "0123456789"
            assert String.starts_with?(written, left)

          {{:error, :enospc}, _} ->
            assert String.starts_with?("0123456789", written)
            assert byte_size(written) < 10
        end
      end

      kinds = Enum.uniq(for {result, _, _} <- results, do: result)
      assert {:ok, :ok} in kinds
      assert {:ok, {:error, :eio}} in kinds
      assert Enum.any?(kinds, &match?({{:error, :enospc}, _}, &1))
    end

    test "a failed rename changes nothing", %{dir: dir} do
      results =
        each_seed(%{error_p: 0.5}, fn seed ->
          f = file(dir, seed)
          File.write!(f, "old")
          # The fixture writes the temporary file first. Only the rename is
          # under test, so the errors are switched on for the rename alone.
          :ok = @disk.set_policy(%{})
          tmp = f ++ ~c".tmp"
          File.write!(tmp, "new")
          :ok = @disk.set_policy(%{error_p: 0.5})
          result = :eta_file.rename(tmp, f)
          {result, File.read!(f), File.exists?(tmp)}
        end)

      for r <- results do
        assert r in [{:ok, "new", false}, {{:error, :eio}, "old", true}]
      end

      assert length(Enum.uniq(results)) == 2
    end

    test "an unknown policy key is refused" do
      assert_raise ErlangError, fn -> @disk.start(%{policy: %{eror_p: 0.1}}) end
    end
  end

  describe "under a run" do
    @opts %{max_ops: 6, max_steps: 4_000, preload: [:eta]}

    test "a run reports the disk only when it installed one" do
      without = :eta_run.run(:eta_2pc, Map.put(@opts, :seed, 5))
      assert without.disk == %{}
      refute @disk.running()

      with_disk = :eta_run.run(:eta_2pc, Map.merge(@opts, %{seed: 5, disk: true}))
      assert %{crashes: 0, syncs: 0} = with_disk.disk
      # A disk that nothing wrote to changes nothing about the run.
      assert without.trace == with_disk.trace
      refute @disk.running()
    end
  end
end
