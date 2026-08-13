defmodule EtaElixir.Worker do
  @moduledoc """
  A GenServer worker that exercises the full `Eta.*` macro surface.

  Unlike `EtaElixir.Counter`, which only uses `send_after`, `cast`, `call`,
  `send`, `start_link`, `label`, and `log`, this module also exercises:

  - `Eta.spawn_link/1` — spawns a linked helper process
  - `Eta.spawn/1` — spawns an unlinked worker for async replies
  - `Eta.monitor/1` — monitors the helper
  - `Eta.demonitor/1` — demonitors on detach
  - `Eta.cancel_timer/1` — cancels the old tick timer on each tick
  - `Eta.monotonic_time/0` — records a timestamp on each tick
  - `Eta.reply/2` — async reply from a spawned worker
  - `Eta.start/3` — unlinked GenServer start
  - `handle_continue/2` — deferred initialization
  - `handle_call/3` with guards — `when state.alive`
  - `{:stop, :normal, :ok, state}` return from `handle_call/3`
  - `handle_info({:DOWN, ...}, ...)` — monitor notification
  """

  use Eta
  @behaviour :gen_server

  @eta_observe :all

  @tick_ms 50

  # -----------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------

  def start_link(opts \\ []) do
    Eta.start_link(__MODULE__, opts, opts)
  end

  def start(opts \\ []) do
    Eta.start(__MODULE__, opts, opts)
  end

  def health(server) do
    Eta.call(server, :health, 5000)
  end

  def measure(server) do
    Eta.call(server, :measure, 5000)
  end

  def detach(server) do
    Eta.call(server, :detach, 5000)
  end

  def stop(server) do
    Eta.call(server, :stop, 5000)
  end

  # -----------------------------------------------------------------------
  # Callbacks
  # -----------------------------------------------------------------------

  def init(_opts) do
    Eta.label(:worker)
    timer_ref = Eta.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       timer_ref: timer_ref,
       tick_count: 0,
       alive: true,
       helper: nil,
       mon_ref: nil,
       last_monotonic: 0
     }, {:continue, :setup}}
  end

  def handle_continue(:setup, state) do
    helper = Eta.spawn_link(fn -> helper_loop(0) end)
    mon_ref = Eta.monitor(helper)
    {:noreply, %{state | helper: helper, mon_ref: mon_ref}}
  end

  # Guard clause: health check when helper is alive.
  def handle_call(:health, from, state) when state.alive do
    {:reply, {:ok, state.tick_count}, state}
  end

  # Fallback: health check when helper is dead.
  def handle_call(:health, from, state) do
    {:reply, {:degraded, state.tick_count}, state}
  end

  # Async reply: spawn a worker that calls Eta.reply/2 later.
  def handle_call(:measure, from, state) do
    Eta.spawn(fn ->
      result = {:measured, Eta.monotonic_time()}
      Eta.reply(from, result)
    end)

    {:noreply, state}
  end

  # Detach: demonitor the helper.
  def handle_call(:detach, from, state) do
    if state.mon_ref, do: Eta.demonitor(state.mon_ref)
    {:reply, :ok, %{state | mon_ref: nil}}
  end

  # Stop: returns {:stop, :normal, :ok, state}.
  def handle_call(:stop, from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_info(:tick, state) do
    Eta.cancel_timer(state.timer_ref)
    new_ref = Eta.send_after(self(), :tick, @tick_ms)
    now = Eta.monotonic_time()
    Eta.log({:tick, state.tick_count, now})

    {:noreply,
     %{state | timer_ref: new_ref, tick_count: state.tick_count + 1, last_monotonic: now}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if ref == state.mon_ref do
      Eta.log({:helper_down, reason})
      {:noreply, %{state | alive: false}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}
  def terminate(_reason, _state), do: :ok
  def code_change(_old, state, _extra), do: {:ok, state}

  # -----------------------------------------------------------------------
  # Helper process
  # -----------------------------------------------------------------------

  defp helper_loop(n) do
    receive do
      :stop ->
        :ok

      {:work, from} ->
        Eta.reply(from, {:worker_result, n})
        helper_loop(n + 1)
    end
  end
end
