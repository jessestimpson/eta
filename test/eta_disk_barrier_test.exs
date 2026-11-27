defmodule EtaDiskBarrierTest do
  @moduledoc """
  The `barrier` value of the `sync` key of the policy of `:eta_disk`, and
  `:eta_disk.flush/0`.

  Under the policy, a sync of a file records the contents of the file and makes
  nothing durable, as `fcntl(F_BARRIERFSYNC)` does on macOS. `flush/0` makes the
  recorded contents of the node durable, as `fcntl(F_FULLFSYNC)` does.

  The claims under test:

  1. **A crash loses synced data that was not flushed**, and never data that
     was flushed.
  2. **A crash keeps a prefix of the syncs.** A file has the contents of one of
     its syncs or its durable contents. No write is torn, and no data that was
     written after the last sync remains.
  3. **The prefix is one prefix for all files of the node.** A later sync of
     one file is not kept when an earlier sync of another file is lost.
  4. **A rename moves the syncs of a file, and a delete drops them.**
  5. **`flush/0` acts on the node of the caller only.**
  6. **The `durable` policy is the default and is unchanged.** `flush/0`
     changes nothing under it, and does nothing with no disk running.

  Each file exists and is empty before the disk starts, so the creation of the
  file and the empty contents are durable.
  """
  use ExUnit.Case, async: false

  @disk :eta_disk
  @fix :eta_disk_fixture
  @seeds 1..90

  setup do
    dir = Path.join(System.tmp_dir!(), "eta_disk_barrier_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      @disk.stop()
      :eta_net.stop()
      :eta_time.stop()
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  # Runs `fun` once for each seed with a fresh disk under `policy`. `fun`
  # receives the names of the files `names`, which exist and are empty.
  defp each_seed(dir, names, policy \\ %{sync: :barrier}, fun) do
    for seed <- @seeds do
      sub = Path.join(dir, Integer.to_string(seed))
      File.mkdir_p!(sub)

      files =
        for name <- names do
          path = Path.join(sub, name)
          File.write!(path, "")
          String.to_charlist(path)
        end

      :ok = @disk.start(%{seed: seed, policy: policy})
      fun.(files)
    end
  end

  defp append(file, data, sync), do: {:ok, :ok} = @fix.append(file, data, sync)

  defp read(file) do
    case @fix.read(file) do
      {:ok, contents} -> contents
      {:error, :enoent} -> :enoent
    end
  end

  describe "a crash under the barrier policy" do
    test "leaves the contents of a sync or the durable contents", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          append(f, "one.", true)
          append(f, "two.", true)
          append(f, "tail", false)
          # Every reader sees the data until the crash.
          assert read(f) == "one.two.tail"

          :ok = @disk.crash(node())
          read(f)
        end)

      assert Enum.sort(Enum.uniq(results)) == ["", "one.", "one.two."]
    end

    test "loses nothing that was flushed", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          append(f, "one.", true)
          :ok = @disk.flush()
          append(f, "two.", true)
          append(f, "tail", false)

          :ok = @disk.crash(node())
          read(f)
        end)

      assert Enum.sort(Enum.uniq(results)) == ["one.", "one.two."]
    end

    test "a flush covers the last sync and not a later write", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          append(f, "one.", true)
          append(f, "tail", false)
          :ok = @disk.flush()

          :ok = @disk.crash(node())
          read(f)
        end)

      assert Enum.uniq(results) == ["one."]
    end

    test "keeps one prefix of the syncs over all files", %{dir: dir} do
      results =
        each_seed(dir, ["a", "b"], fn [a, b] ->
          append(a, "a1.", true)
          append(b, "b1.", true)
          append(a, "a2.", true)

          :ok = @disk.crash(node())
          {read(a), read(b)}
        end)

      # The 4 prefixes of the 3 syncs. `{"", "b1."}` and `{"a1.a2.", ""}` would
      # keep a later sync without an earlier one.
      assert Enum.sort(Enum.uniq(results)) ==
               [{"", ""}, {"a1.", ""}, {"a1.", "b1."}, {"a1.a2.", "b1."}]
    end

    test "a sync that finds the contents of the previous sync records nothing", %{dir: dir} do
      each_seed(dir, ["f"], fn [f] ->
        append(f, "one.", true)
        append(f, "", true)
        append(f, "", true)

        :ok = @disk.crash(node())
        stats = @disk.stats()
        assert stats.barriers_kept + stats.barriers_undone == 1
      end)
    end

    test "is a function of the seed", %{dir: dir} do
      run = fn ->
        each_seed(dir, ["a", "b"], fn [a, b] ->
          append(a, "a1.", true)
          append(b, "b1.", true)
          append(a, "a2.", true)
          :ok = @disk.crash(node())
          {read(a), read(b)}
        end)
      end

      assert run.() == run.()
    end

    test "counts the syncs that it kept and undid, and tears no file", %{dir: dir} do
      stats =
        each_seed(dir, ["a", "b"], fn [a, b] ->
          append(a, "a1.", true)
          append(b, "b1.", true)
          append(a, "a2.", true)
          :ok = @disk.flush()
          append(a, "a3.", true)
          append(b, "b2.", true)

          :ok = @disk.crash(node())
          @disk.stats()
        end)

      for s <- stats do
        assert s.flushes == 1
        assert s.syncs == 5
        assert s.barriers_kept + s.barriers_undone == 2
        assert s.files_torn == 0
      end

      assert Enum.any?(stats, &(&1.barriers_kept == 2))
      assert Enum.any?(stats, &(&1.barriers_undone == 2))
      assert Enum.any?(stats, &(&1.barriers_kept == 1))
    end
  end

  describe "a rename and a delete under the barrier policy" do
    test "a rename moves the syncs of the file", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          g = f ++ ~c".moved"
          append(f, "one.", true)
          :ok = @fix.move(f, g, true)

          :ok = @disk.crash(node())
          {read(f), read(g)}
        end)

      # The directory was synced, so the rename is durable. The sync of the
      # file is kept or lost under the new name.
      assert Enum.sort(Enum.uniq(results)) == [{:enoent, ""}, {:enoent, "one."}]
    end

    test "a rename that the crash undoes moves the syncs back", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          g = f ++ ~c".moved"
          append(f, "one.", true)
          :ok = @fix.move(f, g, false)

          :ok = @disk.crash(node())
          {read(f), read(g)}
        end)

      assert MapSet.new(results) ==
               MapSet.new([{"", :enoent}, {"one.", :enoent}, {:enoent, ""}, {:enoent, "one."}])
    end

    test "a rename drops the syncs of the file that it replaces", %{dir: dir} do
      results =
        each_seed(dir, ["old", "new"], fn [old, new] ->
          append(old, "old.", true)
          append(new, "new.", true)
          :ok = @disk.flush()
          append(old, "old2.", true)
          # The file that is renamed has contents that are not durable, so the
          # crash decides its contents under the name `old`.
          append(new, "tail", false)
          :ok = @fix.move(new, old, true)

          :ok = @disk.crash(node())
          read(old)
        end)

      # The rename is durable, and the file under the name has the flushed
      # contents of the file that was renamed. The sync of the replaced file
      # does not come back.
      assert Enum.uniq(results) == ["new."]
    end

    test "a delete drops the syncs of the file", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          append(f, "one.", true)
          :ok = @fix.remove(f, false)

          :ok = @disk.crash(node())
          read(f)
        end)

      # A crash that undoes the delete restores the durable contents.
      assert MapSet.new(results) == MapSet.new(["", :enoent])
    end

    test "a file that is created again does not get the syncs of the deleted file", %{dir: dir} do
      results =
        each_seed(dir, ["f"], fn [f] ->
          append(f, "one.", true)
          :ok = @fix.remove(f, true)
          append(f, "again", false)

          :ok = @disk.crash(node())
          read(f)
        end)

      # The delete is durable. The crash keeps or undoes the creation, and the
      # contents of the new file were never synced.
      assert MapSet.new(results) == MapSet.new(["", :enoent])
    end
  end

  describe "flush/0" do
    test "acts on the node of the caller only", %{dir: dir} do
      results =
        each_seed(dir, ["a", "b"], fn [fa, fb] ->
          seed = :erlang.unique_integer([:positive])
          :ok = :eta_time.start(%{seed: seed})
          :ok = :eta_net.start(%{seed: seed})
          a = spawn(fn -> Process.sleep(:infinity) end)
          b = spawn(fn -> Process.sleep(:infinity) end)
          :ok = :eta_net.place(:na, [a])
          :ok = :eta_net.place(:nb, [b])

          {:ok, :ok} = :eta_net.with_node(:na, fn -> @fix.append(fa, "a.", true) end)
          {:ok, :ok} = :eta_net.with_node(:nb, fn -> @fix.append(fb, "b.", true) end)
          :ok = :eta_net.with_node(:na, fn -> @disk.flush() end)

          :ok = @disk.crash(:na)
          :ok = @disk.crash(:nb)
          Process.exit(a, :kill)
          Process.exit(b, :kill)
          {read(fa), read(fb)}
        end)

      assert Enum.sort(Enum.uniq(results)) == [{"a.", ""}, {"a.", "b."}]
    end

    test "does nothing and returns ok with no disk running" do
      refute @disk.running()
      assert @disk.flush() == :ok
    end

    test "changes nothing under the durable policy", %{dir: dir} do
      run = fn flush ->
        each_seed(dir, ["f"], %{}, fn [f] ->
          append(f, "synced.", true)
          _ = flush and @disk.flush()
          append(f, "unsynced", false)
          :ok = @disk.crash(node())
          {read(f), Map.drop(@disk.stats(), [:flushes])}
        end)
      end

      assert run.(true) == run.(false)
    end
  end

  describe "random operations under a run" do
    @sut :eta_disk_barrier_sut
    @opts %{max_ops: 30, max_steps: 4_000, preload: [:eta], disk: %{policy: %{sync: :barrier}}}

    test "a crash leaves the flushed contents and a prefix of the syncs, for 300 seeds", %{
      dir: dir
    } do
      opts = Map.merge(@opts, %{config: %{dir: dir}, audit: true})

      assert :eta_run.sweep(@sut, Enum.to_list(1..300), opts) == %{outcome: :ok, runs: 300}
    end

    test "the runs sync, flush, keep syncs and undo syncs", %{dir: dir} do
      disks =
        for seed <- 1..40 do
          result = :eta_run.run(@sut, Map.merge(@opts, %{seed: seed, config: %{dir: dir}}))
          assert result.outcome == :ok
          assert result.ops == 30
          assert result.disk.crashes == 1
          assert result.disk.files_torn == 0
          result.disk
        end

      total = fn key -> disks |> Enum.map(& &1[key]) |> Enum.sum() end
      # Measured over the 40 seeds: 476 syncs, 122 flushes, 42 syncs kept, 36
      # syncs undone and 56 files changed by a crash.
      assert total.(:syncs) > 300
      assert total.(:flushes) > 60
      assert total.(:barriers_kept) >= 20
      assert total.(:barriers_undone) >= 20
      assert total.(:files_lost) > 25
    end

    test "under the durable policy, the same harness finds a violation", %{dir: dir} do
      # The model of the harness is the model of the barrier policy. Under
      # the durable policy a crash keeps unsynced data, which the model does
      # not allow. The harness can therefore fail.
      opts = Map.merge(@opts, %{config: %{dir: dir}, disk: %{policy: %{sync: :durable}}})
      sweep = :eta_run.sweep(@sut, Enum.to_list(1..50), opts)

      assert {:violation, %{property: :barrier_prefix}} = sweep.outcome
      assert sweep.shrunk.verified
    end
  end

  describe "the policy" do
    test "the default value of sync is durable" do
      :ok = @disk.start(%{})
      assert @disk.policy().sync == :durable
    end

    test "under the durable policy a sync is durable without a flush", %{dir: dir} do
      results =
        each_seed(dir, ["f"], %{sync: :durable}, fn [f] ->
          append(f, "one.", true)
          :ok = @disk.crash(node())
          read(f)
        end)

      assert Enum.uniq(results) == ["one."]
    end

    test "an unknown value of sync is refused" do
      assert_raise ErlangError, fn -> @disk.start(%{policy: %{sync: :full}}) end
    end
  end
end
