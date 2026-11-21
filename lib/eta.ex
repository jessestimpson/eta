defmodule Eta do
  @moduledoc """
  Elixir support for `eta`. `use Eta` gives an Elixir module what
  `include/eta.hrl` gives an Erlang module.

  `use Eta` does not rewrite the module. `use Eta` sets the persisted attribute
  `@eta true`. `mix compile.eta` (see `Mix.Tasks.Compile.Eta`) transforms every
  module that has this attribute.

  ## Example

      use Eta                      # opt in, with every default pass
      use Eta, net: false          # take no part in the simulated network
      use Eta, after: false        # keep `receive ... after` on the real clock
      use Eta, observe: :all       # republish state on every callback return

  ## Options

  The options control the optional passes of the transform.

  | Option | Accepted values | Effect | Module attribute |
  |---|---|---|---|
  | `:net` | a boolean | `false` keeps the module out of the simulated network. | `@eta_net` |
  | `:after` | a boolean | `false` keeps `receive ... after` on the real clock. | `@eta_after` |
  | `:observe` | `:all` or `{record_name, [field]}` | Republishes the state on every callback return. | `@eta_observe` |

  Each option becomes a persisted module attribute. The attribute reaches the
  abstract format of the compiled module in the form that the gating passes of
  `eta_transform` match for Erlang. `observe: :all` in Elixir and
  `-eta_observe(all).` in Erlang compile to the same attribute.

  `use Eta` raises `ArgumentError` at the `use` site, when the module compiles,
  in these cases:

  - the options are not a keyword list;
  - an option is unknown;
  - an option has a value that the pass does not accept.

  A module with an invalid option therefore does not compile into a module that
  is simulated differently from what the options state.

  ## Builds without eta

  `eta` is a test-only dependency. A shipped module that contains `use Eta`
  refers to an undefined module in every build outside the `:dst` profile. Define
  one wrapper module in the project. The wrapper does for Elixir what
  `include/myapp_eta.hrl` does for Erlang:

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

  The modules of the project write `use MyApp.Eta, observe: :all` and call
  `MyApp.Eta.label/1` and `MyApp.Eta.log/1`. In every build except `:dst`, the
  wrapper expands as follows, and the compiled modules do not refer to `eta`:

  | Call | Expansion outside `:dst` |
  |---|---|
  | `use MyApp.Eta, opts` | nothing; the options are discarded |
  | `MyApp.Eta.label(value)` | `:ok` |
  | `MyApp.Eta.log(event)` | `0` |

  These expansions match the expansions of `include/eta.hrl` without `DST`.

  ## Limitations

  - Outside `:dst`, the argument of `log` is not compiled. A variable that is used
    only inside a `log` call is then unused, and the compiler reports it. Bind such
    a variable to `_`.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
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
  Names the calling process on the simulation timeline. Call `label/1` once, where
  the process starts. `label/1` is the Elixir equivalent of `?ETA_LABEL(Label)`.
  See `eta_log`.

  `label/1` is a macro and not a function. The `MyApp.Eta` wrapper can therefore
  expand it to `:ok` outside the `:dst` build, and the compiled module contains no
  call to `eta`.
  """
  defmacro label(value) do
    quote do
      :eta_log.label(unquote(value))
    end
  end

  @doc """
  Records an event on the simulation timeline and returns the sequence number of
  the event. `log/1` is the Elixir equivalent of `?ETA_LOG(Event)`. See `eta_log`.
  """
  defmacro log(event) do
    quote do
      :eta_log.log(unquote(event))
    end
  end
end
