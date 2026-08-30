defmodule EtaElixir.Counter do
  @moduledoc """
  A simple GenServer counter — the Elixir SUT for `eta`.

  Written as fully idiomatic Elixir: `use GenServer`, `GenServer.start_link/2`,
  `GenServer.cast/2`, `GenServer.call/3`, `Process.send_after/3`, `send/2` —
  no facade, no renamed call sites, no `:gen_server` qualification. The beam
  rewrite (`Eta.Beam`) points all of it at `eta_sched`, `eta_net` and
  `eta_time` after compilation, the same substitution `eta_transform` makes
  for the Erlang SUTs.

  `use GenServer` matters beyond idiom: it declares
  `-behaviour('Elixir.GenServer')`, which is the attribute the transform's
  reply pass must recognise for `handle_call/3` routing — so this module is
  the coverage for that gate, while `EtaElixir.Worker` keeps the raw
  `@behaviour :gen_server` form to cover the other. Its injected default
  callbacks are transformed along with everything else, because the rewrite
  works on post-expansion abstract format.

  `@eta_observe :all` publishes the state on every callback return.
  """

  use Eta
  use GenServer

  @eta_observe :all

  @tick_ms 50

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def increment(server) do
    GenServer.cast(server, :increment)
  end

  def get(server) do
    GenServer.call(server, :get, 5000)
  end

  def send_tick(server) do
    send(server, :tick)
  end

  def init(_opts) do
    Eta.label(:counter)
    _ = Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{count: 0}}
  end

  def handle_call(:get, _from, state) do
    {:reply, state.count, state}
  end

  def handle_cast(:increment, state) do
    Eta.log({:incremented, state.count + 1})
    {:noreply, %{state | count: state.count + 1}}
  end

  def handle_info(:tick, state) do
    Eta.log(:tick)
    _ = Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Eta.log({:unexpected, msg})
    {:noreply, state}
  end

  def terminate(_reason, _state), do: :ok
  def code_change(_old, state, _extra), do: {:ok, state}
end
