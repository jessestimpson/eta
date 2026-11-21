defmodule Mix.Tasks.Compile.Eta do
  @shortdoc "Applies eta's DST transform to opted-in Elixir modules"

  @moduledoc """
  A Mix compiler that runs `eta_transform` over the beams that the `:elixir`
  compiler produced.

  `Eta.Beam` performs the rewrite. This task calls `Eta.Beam.transform_path/1`
  with `Mix.Project.compile_path()` and reports the result in the form that Mix
  expects.

  ## Configuration

  In the project that uses `eta`, append `:eta` to the compilers in the simulation
  profile only:

      def project do
        [
          # ...
          compilers: Mix.compilers() ++ if(Mix.env() == :dst, do: [:eta], else: []),
          deps: [{:eta, "~> 0.1", only: :dst}]
        ]
      end

  The condition on `Mix.env()` is required. `eta` is a dependency of the `:dst`
  environment only, so an unconditional `:eta` compiler is an unknown task in
  every other environment.

  No other configuration is needed. This configuration corresponds to the
  `{d, 'DST'}` profile of rebar3. A module opts in with `use Eta`, as an Erlang
  module opts in by including the header.

  ## Behaviour

  - Mix compiles dependencies before the application. When this task runs, both
    `eta_transform` and the beams that opted in exist.
  - A beam that is already stamped is skipped. A repeated run of the task
    therefore transforms nothing.
  - A module that Mix recompiles later has no stamp. The next run of the task
    transforms it again.

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
