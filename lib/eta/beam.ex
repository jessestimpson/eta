defmodule Eta.Beam do
  @moduledoc """
  Applies `eta_transform` to already-compiled Elixir modules, beam by beam.

  Elixir has no `parse_transform` hook of its own, and the one it inherits
  from the Erlang compiler is deprecated — "Elixir will no longer support
  Erlang-based transforms in future versions" — so the transform runs *after*
  compilation instead of during it. For each opted-in module:

  1. The Erlang abstract format is read back out of the beam's `debug_info`
     chunk, through the same stable protocol Dialyzer uses. This is the exact
     form `eta_transform:parse_transform/2` takes from `erlc`, so
  2. the transform runs on it **unchanged**. It lands better than it has any
     right to: the Elixir compiler's inliner already lowers `send/2`,
     `spawn/1`, `Process.monitor/1` and even `Process.send_after/3` — with the
     argument reorder — to the `:erlang` calls the rewrite tables match, and
     `receive do ... after` compiles to the same abstract form the `after`
     pass expands. Because abstract format is post-macro-expansion, code
     injected by `use GenServer` is covered too, which no source-level rewrite
     of the user's module could claim.
  3. The rewritten forms are compiled and the beam is put back where it was.

  A module opts in by carrying a persisted `@eta true` attribute, which is
  what `use Eta` plants. The rewrite stamps its output with
  `-eta_transformed(true)`, and a stamped beam is skipped on sight — the
  callback-wrapping passes are not idempotent, so transforming twice must be
  impossible rather than discouraged. Mix recompiling a module produces a
  fresh unstamped beam, which is precisely the signal to transform it again.

  ## Prototype boundaries, deliberately

  - **The `'Elixir.*'` rewrite tables cover `GenServer` and the clock reads.
    `Task` and `Agent` are the named gap**: their spawns and waits happen
    inside Elixir's stdlib where nothing can gate them, so their entry points
    raise while a scheduler is active (`eta_sched:unsupported/2`) rather than
    quietly running outside the schedule, until `instrument/1` has rewritten
    the module itself.
  - The rewritten beam is compiled fresh from forms, so the Elixir-specific
    chunks (`Docs`, `ExCk`) are dropped. Harmless in a `:dst` profile, whose
    beams exist to be simulated, not documented.
  - A beam compiled without `debug_info` cannot be transformed and says so,
    rather than silently shipping real-clock code into a simulation.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  @marker :eta
  @stamp :eta_transformed

  @typedoc "What `transform/1` did to one beam."
  @type outcome :: :transformed | :not_opted_in | :already_transformed | {:error, term()}

  @doc """
  Transforms every opted-in `.beam` under `dir`.

  Returns `{path, outcome}` per beam, in no promised order.
  """
  @spec transform_path(Path.t()) :: [{Path.t(), outcome()}]
  def transform_path(dir) do
    dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(&{&1, transform(&1)})
  end

  @doc """
  Transforms one beam file in place, if it opted in and is not already stamped.
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
  Rewrites modules the project does not own, in memory, for this VM only.

  `use Eta` reaches only code you can edit. Everything else a system runs on —
  a dependency's GenServers, `Registry`, `Task`, OTP's `:supervisor` and `:pg` —
  spawns and waits where no transform of your code goes, and a process spawned
  that way is adopted but never released: it has no mailbox traffic to make it
  runnable. This puts those modules under the same rewrite, from the outside.

  Each module's code is read from the code path, transformed and loaded with
  `:code.load_binary/3`. Nothing on disk changes, so a dependency's source and
  its compiled beams stay exactly as they were. The rewrites are inert outside
  a run, so the rest of the VM, which shares these modules, is unaffected.

  Call it once, before the first run. Returns `{module, outcome}` per module.
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
