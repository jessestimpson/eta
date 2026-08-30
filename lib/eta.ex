defmodule Eta do
  @moduledoc """
  The Elixir face of `eta` — the same contract `include/eta.hrl` gives Erlang,
  reached by `use` instead of by header.

  `use Eta` rewrites nothing by itself. It plants a persisted `@eta true`
  attribute, which is how `mix compile.eta` (see `Mix.Tasks.Compile.Eta`)
  recognises a module that wants the transform, and its options gate the
  transform's optional passes:

      use Eta                      # opt in, with every default pass
      use Eta, net: false          # take no part in the simulated network
      use Eta, after: false        # keep `receive ... after` on the real clock
      use Eta, observe: :all       # republish state on every callback return

  Each option becomes a persisted module attribute (`@eta_net`, `@eta_after`,
  `@eta_observe`), which reaches the compiled module's abstract format in
  exactly the shape `eta_transform`'s Erlang gating passes already match — an
  `observe: :all` here and an `-eta_observe(all).` there are the same
  attribute by the time either is compiled. An unknown option, or a value the
  pass cannot honour, raises `ArgumentError` where the `use` is written
  rather than compiling into a module that silently is not simulated the way
  it claims.

  ## Keeping eta out of every other build

  `eta` is a test-only dependency, so `use Eta` written directly in a shipped
  module is an undefined module the moment the `:dst` profile is off. The
  answer is the wrapper trick `include/myapp_eta.hrl` plays for Erlang — one
  module of your own:

      defmodule MyApp.Eta do
        @dst Mix.env() == :dst

        defmacro __using__(opts) do
          if @dst do
            quote do
              use Eta, unquote(opts)
            end
          end
        end

        defmacro label(value) do
          if @dst, do: quote(do: Eta.label(unquote(value))), else: :ok
        end

        defmacro log(event) do
          if @dst, do: quote(do: Eta.log(unquote(event))), else: 0
        end
      end

  Your modules say `use MyApp.Eta, observe: :all` and call `MyApp.Eta.label/1`
  and `MyApp.Eta.log/1`, and every build except `:dst` compiles them with no
  relationship to this library at all — the options vanish along with the
  `use` they were written on. The wrapper's no-op expansions mirror what
  `include/eta.hrl` does without `DST`, stranded-variable gotcha included: a
  variable used only inside a `log` becomes unused when the call compiles
  away, so bind it to `_` if it exists for the log alone.
  """

  @options [:net, :after, :observe]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      Eta.__setup__(__MODULE__, opts)
    end
  end

  @doc false
  # Runs in the host module's compile, with the options evaluated — so a bad
  # option is a compile error at the `use` site, whatever build produced it.
  def __setup__(module, opts) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError,
            "`use Eta` expects a keyword list of options, got: #{inspect(opts)}"
    end

    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)} for `use Eta`; " <>
                "valid options are #{inspect(@options)}"
    end

    for attr <- [:eta, :eta_net, :eta_after, :eta_observe] do
      Module.register_attribute(module, attr, persist: true)
    end

    Module.put_attribute(module, :eta, true)
    for {key, value} <- opts, do: put_option(module, key, value)
    :ok
  end

  defp put_option(module, :net, value) when is_boolean(value),
    do: Module.put_attribute(module, :eta_net, value)

  defp put_option(module, :after, value) when is_boolean(value),
    do: Module.put_attribute(module, :eta_after, value)

  defp put_option(module, :observe, :all),
    do: Module.put_attribute(module, :eta_observe, :all)

  # The record form `-eta_observe({Record, Fields})` exists for Erlang record
  # states; an Elixir module with a record state (via `Record`) may want it too.
  defp put_option(module, :observe, {record, fields} = value)
       when is_atom(record) and is_list(fields) do
    if Enum.all?(fields, &is_atom/1) do
      Module.put_attribute(module, :eta_observe, value)
    else
      bad_option(:observe, value)
    end
  end

  defp put_option(_module, key, value), do: bad_option(key, value)

  defp bad_option(key, value) do
    expected =
      case key do
        :observe -> ":all or {record_name, [field]}"
        _ -> "a boolean"
      end

    raise ArgumentError,
          "invalid value for the #{inspect(key)} option of `use Eta`: " <>
            "expected #{expected}, got: #{inspect(value)}"
  end

  @doc """
  Names the calling process on the simulation timeline. Call once, where the
  process starts. The Elixir face of `?ETA_LABEL(Label)`; see `eta_log`.

  A macro rather than a function so the `MyApp.Eta` wrapper can compile it
  away outside the `:dst` build — there is no call for the transform to
  rewrite when the goal is to not exist at all.
  """
  defmacro label(value) do
    quote do
      :eta_log.label(unquote(value))
    end
  end

  @doc """
  Records an event on the simulation timeline, returning its sequence number.
  The Elixir face of `?ETA_LOG(Event)`; see `eta_log`.
  """
  defmacro log(event) do
    quote do
      :eta_log.log(unquote(event))
    end
  end
end
