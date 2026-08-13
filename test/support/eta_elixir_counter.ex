defmodule EtaElixir.Counter do
  @moduledoc """
  A simple GenServer counter — the Elixir SUT for `eta`.

  Uses `Eta.*` macros instead of stdlib calls: `Eta.send_after/3` instead of
  `Process.send_after/3`, `Eta.cast/2` instead of `GenServer.cast/2`,
  `Eta.start_link/3` instead of `GenServer.start_link/3`, and `Eta.send/2`
  instead of `send/2`. Each macro expands to the `:eta_*` call when `:eta`
  is available, or to the stdlib call otherwise.

  `@eta_observe :all` publishes the state on every callback return, and the
  `@before_compile` callback in `Eta` wraps `handle_call/3` to route replies
  through `:eta_net`.
  """

  use Eta
  @behaviour :gen_server

  @eta_observe :all

  @tick_ms 50

  def start_link(opts \\ []) do
    Eta.start_link(__MODULE__, opts, opts)
  end

  def increment(server) do
    Eta.cast(server, :increment)
  end

  def get(server) do
    Eta.call(server, :get, 5000)
  end

  def send_tick(server) do
    Eta.send(server, :tick)
  end

  def init(_opts) do
    Eta.label(:counter)
    _ = Eta.send_after(self(), :tick, @tick_ms)
    {:ok, %{count: 0}}
  end

  def handle_call(:get, from, state) do
    {:reply, state.count, state}
  end

  def handle_cast(:increment, state) do
    Eta.log({:incremented, state.count + 1})
    {:noreply, %{state | count: state.count + 1}}
  end

  def handle_info(:tick, state) do
    Eta.log(:tick)
    _ = Eta.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Eta.log({:unexpected, msg})
    {:noreply, state}
  end

  def terminate(_reason, _state), do: :ok
  def code_change(_old, state, _extra), do: {:ok, state}
end
