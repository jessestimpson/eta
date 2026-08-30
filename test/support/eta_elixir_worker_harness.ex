defmodule EtaElixir.WorkerHarness do
  @moduledoc """
  An `eta_harness` implementation that drives `EtaElixir.Worker`.

  Generates `:health`, `:measure`, and `:detach` operations against the
  worker, and checks that the observed state is consistent. Driver-side code:
  no `use Eta`, never transformed.
  """

  @behaviour :eta_harness

  @impl true
  def init(_seed, _config) do
    {:ok, pid} = EtaElixir.Worker.start_link([])
    {:ok, %{worker: pid}}
  end

  @impl true
  def processes(%{worker: pid}) do
    [pid]
  end

  @impl true
  def generate(_state, rand0) do
    {roll, rand1} = :rand.uniform_s(rand0)

    op =
      cond do
        roll < 0.4 -> :health
        roll < 0.8 -> :measure
        true -> :detach
      end

    {op, rand1}
  end

  @impl true
  def execute(:health, %{worker: pid} = state) do
    _ = :eta_run.spawn_op(fn -> EtaElixir.Worker.health(pid) end)
    state
  end

  def execute(:measure, %{worker: pid} = state) do
    _ = :eta_run.spawn_op(fn -> EtaElixir.Worker.measure(pid) end)
    state
  end

  def execute(:detach, %{worker: pid} = state) do
    _ = :eta_run.spawn_op(fn -> EtaElixir.Worker.detach(pid) end)
    state
  end

  @impl true
  def check(%{worker: pid}) do
    case :eta_observe.read(pid) do
      %{alive: alive, tick_count: n}
      when is_boolean(alive) and is_integer(n) and n >= 0 ->
        :ok

      other ->
        {:violation, %{property: :worker_state, detail: other}}
    end
  end

  @impl true
  def terminate(%{worker: pid}) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl true
  def labels(%{worker: pid}) do
    %{pid => :worker}
  end
end
