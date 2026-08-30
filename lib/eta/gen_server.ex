defmodule Eta.GenServer do
  @moduledoc """
  Where `GenServer.start_link/3` and `GenServer.start/3` land after the
  rewrite.

  Elixir's `GenServer` pops the `:name` option out of the options list and
  builds the `gen`-style server name — `{:local, atom}`, `{:global, term}`,
  `{:via, module, term}` — before OTP ever sees the call. That translation
  happens inside the Elixir stdlib, where no transform of user code reaches,
  so this module reproduces it — the same dispatch `GenServer`'s private
  `do_start` performs — and hands the result to `eta_sched`'s gated starts.

  The client functions have no counterpart here on purpose: `GenServer.call`,
  `cast` and `reply` speak the same wire protocol as `gen_server`'s, so
  `eta_transform` points them straight at `eta_net`, sharing the targets the
  Erlang rewrites use.

  `eta_sched` delegates to `gen_server` when no scheduler is running, so a
  module rewritten to land here behaves normally outside a simulation.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  @doc "`GenServer.start_link/2,3`, gated by the scheduler."
  def start_link(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    do_start(:start_link, module, init_arg, options)
  end

  @doc "`GenServer.start/2,3`, gated by the scheduler."
  def start(module, init_arg, options \\ []) when is_atom(module) and is_list(options) do
    do_start(:start, module, init_arg, options)
  end

  # `GenServer.do_start/4`'s dispatch with `:eta_sched` in the place of
  # `:gen` — including raising `ArgumentError` on a bad `:name`, so a misuse
  # fails identically in and out of a simulation.
  defp do_start(kind, module, init_arg, options) do
    case Keyword.pop(options, :name) do
      {nil, opts} ->
        apply(:eta_sched, kind, [module, init_arg, opts])

      {atom, opts} when is_atom(atom) ->
        apply(:eta_sched, kind, [{:local, atom}, module, init_arg, opts])

      {{:global, _term} = tuple, opts} ->
        apply(:eta_sched, kind, [tuple, module, init_arg, opts])

      {{:via, via_module, _term} = tuple, opts} when is_atom(via_module) ->
        apply(:eta_sched, kind, [tuple, module, init_arg, opts])

      {other, _} ->
        raise ArgumentError, """
        expected :name option to be one of the following:

          * nil
          * atom
          * {:global, term}
          * {:via, module, term}

        Got: #{inspect(other)}
        """
    end
  end
end
