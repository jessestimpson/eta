defmodule EtaElixir.Worker do
  @moduledoc """
  A GenServer worker that exercises the full rewritten stdlib surface.

  Unlike `EtaElixir.Counter`, which only uses `Process.send_after/3`, `send/2`
  and the basic GenServer client functions, this module also exercises:

  - `spawn_link/1` — spawns a linked helper process
  - `spawn/1` — spawns an unlinked worker for async replies
  - `Process.monitor/1` — monitors the helper
  - `Process.demonitor/1` — demonitors on detach
  - `Process.cancel_timer/1` — cancels the old tick timer on each tick
  - `System.monotonic_time/0` — records a timestamp on each tick
  - `GenServer.reply/2` — async reply from a spawned worker
  - `GenServer.start/2` — unlinked GenServer start
  - `GenServer.start_link/3` with `name:` — the shim's option translation
  - `handle_continue/2` — deferred initialization
  - `handle_call/3` with guards — `when state.alive`
  - `{:stop, :normal, :ok, state}` return from `handle_call/3`
  - `handle_info({:DOWN, ...}, ...)` — monitor notification

  Every call is written plainly: the Elixir compiler inlines the
  `Process`/`System`/`Kernel` forms to the `:erlang` MFAs the rewrite tables
  match, and the `'Elixir.GenServer'` entries cover the rest. The one
  deliberate non-idiom is `@behaviour :gen_server` in place of
  `use GenServer` — `EtaElixir.Counter` covers that gate, and this module
  keeps the raw declaration covered.
  """

  use Eta
  @behaviour :gen_server

  @eta_observe :all

  @tick_ms 50

  # -----------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def start_named(name, opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  def health(server) do
    GenServer.call(server, :health, 5000)
  end

  def measure(server) do
    GenServer.call(server, :measure, 5000)
  end

  def detach(server) do
    GenServer.call(server, :detach, 5000)
  end

  def stop(server) do
    GenServer.call(server, :stop, 5000)
  end

  # -----------------------------------------------------------------------
  # Callbacks
  # -----------------------------------------------------------------------

  def init(_opts) do
    Eta.label(:worker)
    timer_ref = Process.send_after(self(), :tick, @tick_ms)

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
    helper = spawn_link(fn -> helper_loop(0) end)
    mon_ref = Process.monitor(helper)
    {:noreply, %{state | helper: helper, mon_ref: mon_ref}}
  end

  # Guard clause: health check when helper is alive.
  def handle_call(:health, _from, state) when state.alive do
    {:reply, {:ok, state.tick_count}, state}
  end

  # Fallback: health check when helper is dead.
  def handle_call(:health, _from, state) do
    {:reply, {:degraded, state.tick_count}, state}
  end

  # Async reply: spawn a worker that replies later. The reply travels through
  # `eta_net`, because the rewrite covers `GenServer.reply/2` wherever it is
  # called from — including a process the callback spawned.
  def handle_call(:measure, from, state) do
    spawn(fn ->
      result = {:measured, System.monotonic_time()}
      GenServer.reply(from, result)
    end)

    {:noreply, state}
  end

  # Detach: demonitor the helper.
  def handle_call(:detach, _from, state) do
    if state.mon_ref, do: Process.demonitor(state.mon_ref)
    {:reply, :ok, %{state | mon_ref: nil}}
  end

  # Stop: returns {:stop, :normal, :ok, state}, whose reply leg the
  # `handle_call` pass routes before gen_server sees the stop.
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_info(:tick, state) do
    Process.cancel_timer(state.timer_ref)
    new_ref = Process.send_after(self(), :tick, @tick_ms)
    now = System.monotonic_time()
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
        GenServer.reply(from, {:worker_result, n})
        helper_loop(n + 1)
    end
  end
end
