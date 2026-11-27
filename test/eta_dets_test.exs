defmodule EtaDetsTest do
  @moduledoc """
  `eta_dets:delete_object/2`, and the rewrite of `dets:delete_object/2`.

  The claims under test:

  1. **`eta_transform` rewrites `dets:delete_object/2`.** A transformed module
     has no import of `dets:delete_object/2`, and its call deletes the object
     from a table that `eta_dets:open_file/2` opened.
  2. **`eta_dets:delete_object/2` equals `dets:delete_object/2`.** One script of
     inserts, deletions and lookups gives equal results with `dets` and with
     `eta_dets`, for the table types `set`, `bag` and `duplicate_bag`. The
     script deletes an object that is stored, an object with a stored key and
     another value, and an object with a key that is not stored.
  3. **The deletion is written to the file.** After a close and a reopen, the
     deleted object is absent.
  """
  use ExUnit.Case, async: false

  @tab :eta_dets_test_tab

  setup do
    dir = Path.join(System.tmp_dir!(), "eta_dets_test_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp file(dir, name), do: String.to_charlist(Path.join(dir, name))

  # The same calls for `:dets` and for `:eta_dets`. Lookups are sorted, because
  # the order of the objects of a bag is not part of the claim.
  defp script(mod, type, file) do
    look = fn -> for key <- [1, 2, 3, 9], do: {key, Enum.sort(mod.lookup(@tab, key))} end

    {:ok, @tab} = mod.open_file(@tab, file: file, type: type)
    :ok = mod.insert(@tab, [{1, :a}, {1, :b}, {2, :c}, {2, :c}, {3, :d}])

    steps = [
      {:initial, look.()},
      {:stored, mod.delete_object(@tab, {1, :a}), look.()},
      {:other_value, mod.delete_object(@tab, {3, :other}), look.()},
      {:absent_key, mod.delete_object(@tab, {9, :x}), look.()},
      {:every_instance, mod.delete_object(@tab, {2, :c}), look.()}
    ]

    :ok = mod.close(@tab)
    {:ok, @tab} = mod.open_file(@tab, file: file, type: type)
    reopened = look.()
    :ok = mod.close(@tab)

    steps ++ [{:reopened, reopened}]
  end

  test "eta_transform rewrites dets:delete_object/2" do
    {:ok, {_, [imports: imports]}} =
      :beam_lib.chunks(:code.which(:eta_dets_user), [:imports])

    assert {:eta_dets, :delete_object, 2} in imports
    refute Enum.any?(imports, &match?({:dets, _, _}, &1))
  end

  test "a transformed module deletes the object from the table of eta_dets", %{dir: dir} do
    {:ok, @tab} = :eta_dets_user.open(@tab, file(dir, "user"), :set)
    :ok = :eta_dets_user.put(@tab, [{1, :a}, {2, :b}])

    assert :ok = :eta_dets_user.drop(@tab, {1, :other})
    assert :eta_dets_user.get(@tab, 1) == [{1, :a}]

    assert :ok = :eta_dets_user.drop(@tab, {1, :a})
    assert :eta_dets_user.get(@tab, 1) == []
    assert :eta_dets_user.get(@tab, 2) == [{2, :b}]

    :ok = :eta_dets_user.close(@tab)
  end

  for type <- [:set, :bag, :duplicate_bag] do
    test "eta_dets:delete_object/2 equals dets:delete_object/2 for a #{type} table", %{dir: dir} do
      type = unquote(type)
      real = script(:dets, type, file(dir, "real"))
      simulated = script(:eta_dets, type, file(dir, "simulated"))

      assert simulated == real
    end
  end

  test "the script deletes objects, so the comparison is not vacuous", %{dir: dir} do
    steps = script(:dets, :duplicate_bag, file(dir, "real"))

    assert {:initial, [{1, [{1, :a}, {1, :b}]}, {2, [{2, :c}, {2, :c}]}, {3, [{3, :d}]}, {9, []}]} =
             hd(steps)

    assert {:reopened, [{1, [{1, :b}]}, {2, []}, {3, [{3, :d}]}, {9, []}]} = List.last(steps)
  end
end
