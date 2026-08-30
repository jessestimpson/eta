defmodule EtaElixir.Lease do
  @moduledoc """
  A lease machine — the Elixir `gen_statem` SUT for `eta`.

  Elixir has no `gen_statem` wrapper, so this is what real Elixir state
  machines look like: `@behaviour :gen_statem`, qualified `:gen_statem` calls,
  callbacks returning the ordinary action tuples. Nothing here needs an
  `'Elixir.*'` table entry — the calls are already the Erlang forms the tables
  match — so this module is the proof that the statem passes apply to
  Elixir-generated abstract format unchanged.

  Written in `state_functions` mode deliberately: it is the half of the pass
  where the state is the *function's name*, so the transform finds the
  callbacks by their exports — and Elixir exports every `def`, which is
  exactly the surface worth exercising. (`eta_state_timeout_sut` covers
  `handle_event_function` on the Erlang side.)

  **There are no `info` clauses**, on purpose and copied from
  `eta_state_timeout_sut`: the virtual deadline arrives as an ordinary `info`
  event, so this machine dies of `function_clause` unless the delivery clause
  `eta_transform` prepends goes before its own. A catch-all here would hide
  the failure this module exists to catch.

  The machine itself: `:acquire` grants the lease and arms a state time-out;
  `:release` returns to `:free`, which must cancel the deadline (a state
  change cancels); an expiry that fires returns to `:free` and counts itself.
  `expiries <= grants` is the harness's invariant.
  """

  use Eta, observe: :all
  @behaviour :gen_statem

  @lease_ms 100

  # -----------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------

  # `owner` gets a message on every expiry — the directed tests' probe. The
  # harness passes nil and reads state through `:eta_observe` instead.
  def start_link(owner \\ nil) do
    :gen_statem.start_link(__MODULE__, owner, [])
  end

  def acquire(pid), do: :gen_statem.call(pid, :acquire, 5000)
  def status(pid), do: :gen_statem.call(pid, :status, 5000)
  def release(pid), do: :gen_statem.cast(pid, :release)

  # -----------------------------------------------------------------------
  # Callbacks
  # -----------------------------------------------------------------------

  def callback_mode, do: :state_functions

  def init(owner) do
    Eta.label(:lease)
    {:ok, :free, %{owner: owner, grants: 0, expiries: 0}}
  end

  # --- :free -------------------------------------------------------------

  def free({:call, from}, :acquire, data) do
    grants = data.grants + 1
    Eta.log({:granted, grants})

    {:next_state, :held, %{data | grants: grants},
     [{:reply, from, {:granted, grants}}, {:state_timeout, @lease_ms, :expire}]}
  end

  def free({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, {:free, data.grants, data.expiries}}]}
  end

  def free(:cast, :release, _data), do: :keep_state_and_data

  # --- :held -------------------------------------------------------------

  def held({:call, from}, :acquire, _data) do
    {:keep_state_and_data, [{:reply, from, :busy}]}
  end

  def held({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, {:held, data.grants, data.expiries}}]}
  end

  # A state change, which must cancel the armed deadline.
  def held(:cast, :release, data) do
    Eta.log(:released)
    {:next_state, :free, data}
  end

  def held(:state_timeout, :expire, data) do
    Eta.log({:expired, data.grants})
    if data.owner, do: send(data.owner, {:expired, data.grants})
    {:next_state, :free, %{data | expiries: data.expiries + 1}}
  end

  def terminate(_reason, _state, _data), do: :ok
end
