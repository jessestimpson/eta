defmodule EtaElixir.Counter do
  @moduledoc """
  A simple GenServer counter — the Elixir SUT for `eta`.

  Written as ordinary Elixir: `Process.send_after/3`, `send/2`,
  `:gen_server.cast/2` — no facade, no renamed call sites. The beam rewrite
  (`Eta.Beam`) points them at `eta_time` and `eta_net` after compilation, the
  same substitution `eta_transform` makes for the Erlang SUTs.

  The one non-idiom is `:gen_server` rather than `GenServer`: the rewrite
  tables carry the Erlang MFAs today and no `'Elixir.*'` entries yet, so the
  SUT calls the layer the tables match. When the `'Elixir.*'` table lands,
  this module switching to `GenServer.call/2` and friends is its acceptance
  test.

  `@eta_observe :all` publishes the state on every callback return, and the
  transform's `handle_call` pass routes replies through `eta_net` — both keyed
  off the persisted attributes `use Eta` registers.
  """

  use Eta
  @behaviour :gen_server

  @eta_observe :all

  @tick_ms 50

  def start_link(opts \\ []) do
    :gen_server.start_link(__MODULE__, opts, [])
  end

  def increment(server) do
    :gen_server.cast(server, :increment)
  end

  def get(server) do
    :gen_server.call(server, :get, 5000)
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
