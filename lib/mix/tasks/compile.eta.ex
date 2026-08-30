defmodule Mix.Tasks.Compile.Eta do
  @shortdoc "Applies eta's DST transform to opted-in Elixir modules"

  @moduledoc """
  A Mix compiler that runs `eta_transform` over the beams the `:elixir`
  compiler just produced. The rewriting itself lives in `Eta.Beam`; this task
  is the plumbing that points it at `Mix.Project.compile_path()` and reports
  what happened in the shape Mix expects.

  ## Wiring it up

  In the project using `eta`, append `:eta` to the compilers in the simulation
  profile only:

      def project do
        [
          # ...
          compilers: Mix.compilers() ++ if(Mix.env() == :dst, do: [:eta], else: []),
          deps: [{:eta, "~> 0.1", only: :dst}]
        ]
      end

  The gate matters: with `eta` a `:dst`-only dependency, an unconditional
  `:eta` compiler is an unknown task in every other environment. Gated, this
  is the whole configuration — the counterpart of rebar3's
  `{d, 'DST'}` profile — and a module opts in with `use Eta` the way an
  Erlang module opts in by including the header.

  Deps compile before the app, so by the time this task runs, both
  `eta_transform` and the opted-in beams exist. A module Mix recompiles later
  comes back unstamped and is transformed again on the next pass; beams
  already stamped are skipped, so running the task repeatedly is free.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  use Mix.Task.Compiler

  @impl true
  def run(_args) do
    results = Eta.Beam.transform_path(Mix.Project.compile_path())

    errors =
      for {path, {:error, reason}} <- results do
        diagnostic(path, reason)
      end

    transformed = for {path, :transformed} <- results, do: path

    cond do
      errors != [] ->
        Enum.each(errors, &Mix.shell().error("#{&1.file}: #{&1.message}"))
        {:error, errors}

      transformed == [] ->
        {:noop, []}

      true ->
        Mix.shell().info("Transformed #{length(transformed)} module(s) with eta_transform")
        {:ok, []}
    end
  end

  defp diagnostic(path, reason) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "eta",
      file: Path.absname(path),
      position: 0,
      severity: :error,
      message: "eta_transform failed: #{inspect(reason)}"
    }
  end
end
