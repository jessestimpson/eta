defmodule Eta.Beam do
  @moduledoc """
  Applies `eta_transform` to compiled Elixir modules, one beam file at a time.

  Elixir has no `parse_transform` hook of its own. The hook that Elixir inherits
  from the Erlang compiler is deprecated: "Elixir will no longer support
  Erlang-based transforms in future versions". The transform therefore runs after
  compilation, not during it.

  ## Steps

  For each module that opted in:

  1. `Eta.Beam` reads the Erlang abstract format from the `debug_info` chunk of
     the beam. It uses the stable protocol that Dialyzer uses. The result has the
     same form as the input that `eta_transform:parse_transform/2` receives from
     `erlc`.
  2. `Eta.Beam` runs the transform on the abstract format without changes to the
     transform.
  3. `Eta.Beam` compiles the rewritten forms and writes the beam to its original
     path.

  The transform for Erlang applies to Elixir modules for these reasons:

  - The inliner of the Elixir compiler lowers `send/2`, `spawn/1` and
    `Process.monitor/1` to the `:erlang` calls that the rewrite tables match.
  - Up to Elixir 1.19, the inliner also lowers `Process.send_after/3` to the
    `:erlang` call, with the arguments reordered. From Elixir 1.20, an entry in the
    rewrite tables reorders the arguments.
  - `receive do ... after` compiles to the abstract form that the `after` pass
    expands.
  - The abstract format is produced after macro expansion. The transform therefore
    covers the code that `use GenServer` injects. A rewrite of the source of the
    module would not cover that code.

  ## Opt-in and stamp

  A module opts in with the persisted attribute `@eta true`, which `use Eta`
  sets.

  The rewrite stamps its output with `-eta_transformed(true)`. `Eta.Beam` skips a
  stamped beam. The passes that wrap callbacks are not idempotent, so the stamp
  makes a second transform of the same beam impossible. When Mix recompiles a
  module, the new beam has no stamp, and `Eta.Beam` transforms it again.

  ## Limitations

  - The `'Elixir.*'` rewrite tables cover `GenServer` and the clock reads. They
    do not cover `Task` and `Agent`. The spawns and waits of `Task` and `Agent`
    are inside the Elixir standard library, where the transform cannot gate them.
    The entry points of `Task` and `Agent` therefore raise while a scheduler is
    active (`eta_sched:unsupported/2`), so that they do not run outside the
    schedule. After `instrument/1` has rewritten the module itself, the entry
    points no longer raise.
  - The rewritten beam is compiled from forms, so the Elixir-specific chunks
    (`Docs`, `ExCk`) are dropped. A `:dst` profile uses its beams for simulation
    and not for documentation.
  - A beam that was compiled without `debug_info` cannot be transformed.
    `transform/1` returns an error for such a beam, so that code on the real clock
    does not enter a simulation unreported.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  @marker :eta
  @stamp :eta_transformed

  @typedoc "What `transform/1` did to one beam."
  @type outcome :: :transformed | :not_opted_in | :already_transformed | {:error, term()}

  @doc """
  Transforms every `.beam` file under `dir` that opted in.

  Returns one `{path, outcome}` tuple per beam file. The order of the list is not
  specified.
  """
  @spec transform_path(Path.t()) :: [{Path.t(), outcome()}]
  def transform_path(dir) do
    dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(&{&1, transform(&1)})
  end

  @doc """
  Transforms one beam file in place, if the module opted in and the beam is not
  stamped.

  Returns one of these outcomes:

  | Outcome | Meaning |
  |---|---|
  | `:transformed` | The beam was rewritten on disk. If the module was loaded, the new code was loaded too. |
  | `:not_opted_in` | The module has no `@eta true` attribute. |
  | `:already_transformed` | The beam has the stamp. |
  | `{:error, reason}` | The beam could not be read, has no debug information, or could not be transformed or compiled. |
  """
  @spec transform(Path.t()) :: outcome()
  def transform(path) when is_binary(path) do
    file = String.to_charlist(path)

    with {:ok, attrs} <- attributes(file),
         :opted_in <- status(attrs),
         {:ok, mod, forms} <- abstract_code(file),
         {:ok, rewritten} <- run_transform(mod, forms),
         {:ok, ^mod, bin} <- compile(stamp(rewritten)) do
      File.write!(path, bin)
      reload(mod, file, bin)
      :transformed
    end
  end

  @doc """
  Rewrites modules that the project does not own, in memory, for this VM only.

  `use Eta` applies only to code that the project can edit. A system also runs on
  other code: the GenServers of a dependency, `Registry`, `Task`, and
  `:supervisor` and `:pg` from OTP. That code spawns and waits where the transform
  of the modules of the project has no effect. The scheduler adopts a process that
  is spawned there but never releases it, because the process has no message
  traffic that makes it runnable. `instrument/1` applies the same rewrite to those
  modules.

  For each module, `instrument/1` does the following:

  1. It reads the code of the module from the code path.
  2. It transforms the code.
  3. It loads the result with `:code.load_binary/3`.

  No file on disk changes, so the source and the compiled beams of a dependency
  stay as they were. The rewritten calls delegate to the original functions
  outside a run, so the rest of the VM, which shares these modules, is not
  affected.

  Call `instrument/1` once, before the first run. It returns one
  `{module, outcome}` tuple per module. The outcome is `:instrumented`,
  `:already_transformed`, or an error term.
  """
  @spec instrument([module()]) :: [{module(), :instrumented | :already_transformed | term()}]
  def instrument(modules) when is_list(modules) do
    results = Enum.map(modules, &{&1, instrument_one(&1)})
    :eta_sched.instrumented(for {m, :instrumented} <- results, do: m)
    results
  end

  defp instrument_one(mod) do
    with false <- loaded_stamped?(mod),
         {^mod, bin, file} <- object_code(mod),
         {:ok, attrs} <- attributes(bin),
         false <- Keyword.has_key?(attrs, @stamp),
         {:ok, ^mod, forms} <- abstract_code(bin),
         {:ok, rewritten} <- run_transform(mod, forms),
         {:ok, ^mod, out} <- compile(stamp(rewritten)) do
      # `kernel` and `stdlib` live in sticky directories, which refuse a load.
      :code.unstick_mod(mod)
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, file, out)
      :instrumented
    else
      true -> :already_transformed
      other -> other
    end
  end

  # Both copies count. This rewrite never reaches the disk, so a module instrumented
  # here is stamped only once loaded, and one `mix compile.eta` rewrote is stamped
  # on disk, loaded or not.
  defp loaded_stamped?(mod) do
    :erlang.module_loaded(mod) and Keyword.has_key?(mod.module_info(:attributes), @stamp)
  end

  defp object_code(mod) do
    case :code.get_object_code(mod) do
      {^mod, _bin, _file} = found -> found
      :error -> {:error, {:no_object_code, mod}}
    end
  end

  # The cheap read — the attributes chunk answers "should this beam be touched
  # at all?" without decompressing debug info, and most beams in a compile path
  # answer no.
  defp attributes(file) do
    case :beam_lib.chunks(file, [:attributes], [:allow_missing_chunks]) do
      {:ok, {_mod, [attributes: attrs]}} when is_list(attrs) -> {:ok, attrs}
      # `beam_lib:strip/1` removes the whole chunk, and a stripped beam
      # carries no marker — which reads as "did not opt in", not as damage.
      {:ok, {_mod, [attributes: :missing_chunk]}} -> {:ok, []}
      {:error, :beam_lib, why} -> {:error, {:unreadable, why}}
    end
  end

  # The chunk normalises every attribute value to a list, so `@eta true`
  # arrives as `eta: [true]`. The stamp is checked before the marker: a
  # transformed beam still carries the marker, and the stamp is what says the
  # work is done.
  defp status(attrs) do
    cond do
      Keyword.has_key?(attrs, @stamp) -> :already_transformed
      attrs[@marker] == [true] -> :opted_in
      true -> :not_opted_in
    end
  end

  defp abstract_code(file) do
    case :beam_lib.chunks(file, [:debug_info]) do
      # `debug_info: false` at compile time — the chunk exists, holding `:none`.
      {:ok, {_mod, [debug_info: {:debug_info_v1, _backend, :none}]}} ->
        {:error, :debug_info_missing}

      {:ok, {mod, [debug_info: {:debug_info_v1, backend, data}]}} ->
        case backend.debug_info(:erlang_v1, mod, data, []) do
          {:ok, forms} -> {:ok, mod, forms}
          {:error, why} -> {:error, {:no_abstract_code, why}}
        end

      {:ok, {_mod, [debug_info: :none]}} ->
        {:error, :debug_info_missing}

      {:error, :beam_lib, why} ->
        {:error, {:unreadable, why}}
    end
  end

  # The transform refuses some modules by raising — `gen_event` is refused at
  # compile time, deliberately — and here "compile time" is a `with` chain, so
  # the raise becomes a value the caller can report per module.
  defp run_transform(mod, forms) do
    {:ok, :eta_transform.parse_transform(forms, [])}
  catch
    :error, reason -> {:error, {:transform, mod, reason}}
  end

  # Attributes may not follow function definitions, so the stamp goes directly
  # after `-module(...)`, which every form list has exactly one of.
  defp stamp(forms) do
    Enum.flat_map(forms, fn
      {:attribute, anno, :module, _} = m -> [m, {:attribute, anno, @stamp, true}]
      form -> [form]
    end)
  end

  # `:debug_info` again, so a rewritten beam still explains itself to
  # `beam_lib` — and so the stamp, not the debug info's presence, is what
  # marks a beam as done.
  defp compile(forms) do
    case :compile.forms(forms, [:debug_info, :return_errors, :return_warnings]) do
      {:ok, mod, bin, _warnings} -> {:ok, mod, bin}
      {:error, errors, _warnings} -> {:error, {:compile_forms, errors}}
    end
  end

  # The Elixir compiler loads many modules into its own VM as it compiles, and
  # `mix test` runs in that VM — so a beam rewritten only on disk can be
  # shadowed by its untransformed self for the whole run. Nothing of the
  # application is running at compile time, which is what makes the purge safe.
  defp reload(mod, file, bin) do
    if :erlang.module_loaded(mod) do
      :code.purge(mod)
      {:module, ^mod} = :code.load_binary(mod, file, bin)
    end

    :ok
  end
end
