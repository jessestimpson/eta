defmodule EtaElixir.LeaseHarness do
  @moduledoc """
  An `eta_harness` implementation that drives `EtaElixir.Lease`.

  Generates `:acquire`, `:release` and `:status` operations. The interesting
  interleavings are the races the schedule manufactures between a `:release`
  and the lease's own expiry — the deadline the virtual clock jumps to when
  nothing is runnable. The invariant is the one the machine keeps by
  construction: every expiry belongs to a grant, so `expiries <= grants`.

  Driver-side code: no `use Eta`, never transformed.
  """

  @behaviour :eta_harness

  @impl true
  def init(_seed, _config) do
    {:ok, pid} = EtaElixir.Lease.start_link(nil)
    {:ok, %{lease: pid, clients: []}}
  end

  # The lease and every op process — see the note in `EtaElixir.Harness`:
  # a `spawn_op` pid not listed here is never released from its gate.
  @impl true
  def processes(%{lease: pid, clients: clients}) do
    [pid | clients]
  end

  @impl true
  def generate(_state, rand0) do
    {roll, rand1} = :rand.uniform_s(rand0)

    op =
      cond do
        roll < 0.45 -> :acquire
        roll < 0.75 -> :release
        true -> :status
      end

    {op, rand1}
  end

  @impl true
  def execute(:acquire, %{lease: pid} = state) do
    client = :eta_run.spawn_op(fn -> EtaElixir.Lease.acquire(pid) end)
    %{state | clients: [client | state.clients]}
  end

  def execute(:release, %{lease: pid} = state) do
    EtaElixir.Lease.release(pid)
    state
  end

  def execute(:status, %{lease: pid} = state) do
    client = :eta_run.spawn_op(fn -> EtaElixir.Lease.status(pid) end)
    %{state | clients: [client | state.clients]}
  end

  @impl true
  def check(%{lease: pid}) do
    # For a gen_statem, the observed term is the data, not the state name.
    case :eta_observe.read(pid) do
      %{grants: g, expiries: e} when is_integer(g) and is_integer(e) and e <= g ->
        :ok

      other ->
        {:violation, %{property: :lease_data, detail: other}}
    end
  end

  @impl true
  def terminate(%{lease: pid}) do
    try do
      GenServer.stop(pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @impl true
  def labels(%{lease: pid}) do
    %{pid => :lease}
  end
end
