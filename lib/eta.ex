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
        defmacro __using__(opts) do
          if Mix.env() == :dst do
            quote do
              use Eta, unquote(opts)
            end
          end
        end
      end

  Your modules say `use MyApp.Eta`, and every build except `:dst` compiles
  them with no relationship to this library at all.

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
end
