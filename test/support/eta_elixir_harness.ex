defmodule EtaElixir.Harness do
  @moduledoc """
  An Elixir `eta_harness` implementation that drives `EtaElixir.Counter`.

  The harness starts the counter, generates `:increment` and `:get`
  operations, and checks that the observed state is consistent. There is no
  planted bug — the SUT is correct, and the assertion is that the same seed
  produces one result.

  Driver-side code, so it does not `use Eta` and is never transformed — the
  same division of labour the Erlang harnesses keep.
  """

  @behaviour :eta_harness

  @impl true
  def init(seed, _config) do
    {:ok, pid} = EtaElixir.Counter.start_link([])
    {:ok, %{counter: pid, seed: seed, clients: []}}
  end

  # The counter *and every op process*. `eta_run` adopts exactly the pids this
  # returns after each op — a `spawn_op` process the harness does not list here
  # is never released from its gate, so its operation silently never runs.
  # (The facade-era harnesses had exactly that bug, and nothing reported it:
  # the runs stayed clean and deterministic, minus their client ops.)
  @impl true
  def processes(%{counter: pid, clients: clients}) do
    [pid | clients]
  end

  @impl true
  def generate(_state, rand0) do
    {roll, rand1} = :rand.uniform_s(rand0)
    op = if roll < 0.6, do: :increment, else: :get
    {op, rand1}
  end

  @impl true
  def execute(:increment, %{counter: pid} = state) do
    EtaElixir.Counter.increment(pid)
    state
  end

  def execute(:get, %{counter: pid} = state) do
    client = :eta_run.spawn_op(fn -> EtaElixir.Counter.get(pid) end)
    %{state | clients: [client | state.clients]}
  end

  @impl true
  def check(%{counter: pid}) do
    case :eta_observe.read(pid) do
      %{count: n} when is_integer(n) and n >= 0 -> :ok
      other -> {:violation, %{property: :counter_state, detail: other}}
    end
  end

  @impl true
  def terminate(%{counter: pid}) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl true
  def labels(%{counter: pid}) do
    %{pid => :counter}
  end
end
