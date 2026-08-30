defmodule Eta do
  @moduledoc """
  The Elixir face of `eta` — the same contract `include/eta.hrl` gives Erlang,
  reached by attribute instead of by header.

  `use Eta` rewrites nothing by itself. It plants a persisted `@eta true`
  attribute, which is how `mix compile.eta` (see `Mix.Tasks.Compile.Eta`)
  recognises a module that wants the transform, and it registers the attributes
  that gate the transform's optional passes:

      use Eta                 # opt in
      @eta_net false          # take no part in the simulated network
      @eta_after false        # keep `receive ... after` on the real clock
      @eta_observe :all       # republish state on every callback return

  Persisted attributes reach the compiled module's abstract format in exactly
  the shape `eta_transform`'s Erlang gating passes already match — an
  `@eta_net false` here and an `-eta_net(false).` there are the same attribute
  by the time either is compiled.

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

  Your modules say `use MyApp.Eta` and call `MyApp.Eta.label/1` and
  `MyApp.Eta.log/1`, and every build except `:dst` compiles them with no
  relationship to this library at all. The wrapper's no-op expansions mirror
  what `include/eta.hrl` does without `DST`, stranded-variable gotcha
  included: a variable used only inside a `log` becomes unused when the call
  compiles away, so bind it to `_` if it exists for the log alone.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :eta, persist: true)
      Module.register_attribute(__MODULE__, :eta_net, persist: true)
      Module.register_attribute(__MODULE__, :eta_after, persist: true)
      Module.register_attribute(__MODULE__, :eta_observe, persist: true)
      @eta true
    end
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
