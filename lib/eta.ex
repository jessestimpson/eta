defmodule Eta do
  @moduledoc """
  Elixir support for `eta`, without parse_transform.

  `use Eta` provides a set of macros that route timer, spawn, and network calls
  through `eta`'s virtualized versions when `:eta` is a compile-time dependency,
  and through the Elixir stdlib otherwise. This means the same source compiles
  under both a DST build and a release build, with no parse_transform and no
  deprecation warnings.

  ## How it works

  Each macro (`Eta.send_after/3`, `Eta.spawn/1`, `Eta.send/2`, `Eta.cast/2`,
  etc.) checks at compile time whether `:eta` is available. If it is, the macro
  expands to the `:eta_*` call. If it isn't, the macro expands to the stdlib
  equivalent. The check is `Code.ensure_loaded?(:eta_time)`, evaluated once at
  compile time — there is no runtime overhead.

  `use Eta` also installs a `@before_compile` callback that wraps `gen_server`
  callback bodies to publish state (when `@eta_observe` is set) and route
  `handle_call/3` replies through `:eta_net`. This is the Elixir equivalent of
  the observe and reply-routing passes in `eta_transform`, done at the Elixir
  AST level via `Module.get_definition/2` rather than at the Erlang AST level.

  ## What you write

  Instead of `Process.send_after/3`, write `Eta.send_after/3`. Instead of
  `GenServer.cast/2`, write `Eta.cast/2`. Instead of `send(pid, msg)`, write
  `Eta.send(pid, msg)`. Each macro expands to the right thing depending on
  whether `:eta` is a dependency.

      defmodule MyServer do
        use Eta
        @behaviour :gen_server

        @eta_observe :all

        def init(_) do
          Eta.label(:my_server)
          _ = Eta.send_after(self(), :tick, 50)
          {:ok, %{count: 0}}
        end

        def handle_call(:get, _from, state) do
          {:reply, state.count, state}
        end

        def handle_cast(:tick, state) do
          Eta.log({:tick, state.count})
          {:noreply, %{state | count: state.count + 1}}
        end
      end

  ## What is not supported

  **`receive ... after` is not virtualized.** The parse transform rewrites this
  language construct; without it, a `receive ... after` timeout runs on the real
  clock. Use `Eta.send_after/3` to send a message to yourself and match on it in
  a plain `receive` instead.

  **`gen_statem` state timeouts are not virtualized.** The parse transform
  intercepts `{state_timeout, ...}` actions before OTP sees them; without it,
  state timeouts run on the real clock. Erlang modules using `gen_statem`
  should continue to use the parse transform via `eta.hrl`.

  **The `!` operator is not rewritten.** Use `Eta.send/2` instead.
  """

  defmacro __using__(_opts) do
    quote do
      require Eta
      @before_compile Eta

      Module.register_attribute(__MODULE__, :eta_observe, persist: true)
      Module.register_attribute(__MODULE__, :eta_net, persist: true)
      Module.register_attribute(__MODULE__, :eta_after, persist: true)
    end
  end

  @doc false
  # Whether `:eta` is available at compile time. Each macro calls this to decide
  # which branch to expand. A process dictionary key (`:__eta_dst_override__`)
  # can force the result, for testing the non-DST expansion path.
  def dst? do
    case Process.get(:__eta_dst_override__) do
      nil -> Code.ensure_loaded?(:eta_time)
      val -> val
    end
  end

  # -------------------------------------------------------------------------
  # Timer / clock
  # -------------------------------------------------------------------------

  @doc """
  Sends `msg` to `dest` after `ms` milliseconds.

  Expands to `:eta_time.send_after/3` when `:eta` is available, or
  `Process.send_after/3` otherwise. Note the argument order matches
  `Process.send_after/3` (`dest, msg, ms`); the swap to `:eta_time`'s
  `Time, Dest, Msg` order is handled by the macro.
  """
  defmacro send_after(dest, msg, ms) do
    if dst?() do
      quote do: :eta_time.send_after(unquote(ms), unquote(dest), unquote(msg))
    else
      quote do: Process.send_after(unquote(dest), unquote(msg), unquote(ms))
    end
  end

  @doc """
  Cancels a timer returned by `send_after/3`.
  """
  defmacro cancel_timer(ref) do
    if dst?() do
      quote do: :eta_time.cancel_timer(unquote(ref))
    else
      quote do: Process.cancel_timer(unquote(ref))
    end
  end

  @doc """
  Monotonic time in native units.
  """
  defmacro monotonic_time do
    if dst?() do
      quote do: :eta_time.monotonic_time()
    else
      quote do: :erlang.monotonic_time()
    end
  end

  # -------------------------------------------------------------------------
  # Spawn
  # -------------------------------------------------------------------------

  @doc """
  Spawns a process running `fun`, gated by the scheduler.

  Expands to `:eta_sched.spawn/1` or `Kernel.spawn/1`.
  """
  defmacro spawn(fun) do
    if dst?() do
      quote do: :eta_sched.spawn(unquote(fun))
    else
      quote do: Kernel.spawn(unquote(fun))
    end
  end

  @doc """
  Spawns a linked process running `fun`, gated by the scheduler.
  """
  defmacro spawn_link(fun) do
    if dst?() do
      quote do: :eta_sched.spawn_link(unquote(fun))
    else
      quote do: Kernel.spawn_link(unquote(fun))
    end
  end

  @doc """
  Spawns a monitored process running `fun`, gated by the scheduler.
  """
  defmacro spawn_monitor(fun) do
    if dst?() do
      quote do: :eta_sched.spawn_monitor(unquote(fun))
    else
      quote do: Kernel.spawn_monitor(unquote(fun))
    end
  end

  # -------------------------------------------------------------------------
  # Network
  # -------------------------------------------------------------------------

  @doc """
  Sends `msg` to `dest`, routed through the simulated network.

  Expands to `:eta_net.send/2` or `Kernel.send/2`.
  """
  defmacro send(dest, msg) do
    if dst?() do
      quote do: :eta_net.send(unquote(dest), unquote(msg))
    else
      quote do: Kernel.send(unquote(dest), unquote(msg))
    end
  end

  @doc """
  Casts `msg` to `server`, routed through the simulated network.
  """
  defmacro cast(server, msg) do
    if dst?() do
      quote do: :eta_net.cast(unquote(server), unquote(msg))
    else
      quote do: GenServer.cast(unquote(server), unquote(msg))
    end
  end

  @doc """
  Calls `server` with `req`, routing both legs through the simulated network.
  """
  defmacro call(server, req, timeout \\ 5000) do
    if dst?() do
      quote do: :eta_net.call(unquote(server), unquote(req), unquote(timeout))
    else
      quote do: GenServer.call(unquote(server), unquote(req), unquote(timeout))
    end
  end

  @doc """
  Replies to a `handle_call/3` `from`, routed through the simulated network.
  """
  defmacro reply(from, reply) do
    if dst?() do
      quote do: :eta_net.reply(unquote(from), unquote(reply))
    else
      quote do: GenServer.reply(unquote(from), unquote(reply))
    end
  end

  @doc """
  Monitors `pid`, routed through the simulated network.
  """
  defmacro monitor(pid) do
    if dst?() do
      quote do: :eta_net.monitor(:process, unquote(pid))
    else
      quote do: Process.monitor(unquote(pid))
    end
  end

  @doc """
  Demonitors `ref`, routed through the simulated network.
  """
  defmacro demonitor(ref) do
    if dst?() do
      quote do: :eta_net.demonitor(unquote(ref))
    else
      quote do: Process.demonitor(unquote(ref))
    end
  end

  # -------------------------------------------------------------------------
  # GenServer starts
  # -------------------------------------------------------------------------

  @doc """
  Starts a linked GenServer, gated by the scheduler.
  """
  defmacro start_link(mod, args, opts \\ []) do
    if dst?() do
      quote do: :eta_sched.start_link(unquote(mod), unquote(args), unquote(opts))
    else
      quote do: GenServer.start_link(unquote(mod), unquote(args), unquote(opts))
    end
  end

  @doc """
  Starts an unlinked GenServer, gated by the scheduler.
  """
  defmacro start(mod, args, opts \\ []) do
    if dst?() do
      quote do: :eta_sched.start(unquote(mod), unquote(args), unquote(opts))
    else
      quote do: GenServer.start(unquote(mod), unquote(args), unquote(opts))
    end
  end

  # -------------------------------------------------------------------------
  # Logging
  # -------------------------------------------------------------------------

  @doc """
  Names the calling process for `:eta_log`. Call once, where the process starts.

  The Elixir equivalent of `?ETA_LABEL(Label)` in Erlang.
  """
  defmacro label(value) do
    if dst?() do
      quote do: :eta_log.label(unquote(value))
    else
      :ok
    end
  end

  @doc """
  Records an event on `:eta_log`, returning its sequence number.

  The Elixir equivalent of `?ETA_LOG(Event)` in Erlang.
  """
  defmacro log(value) do
    if dst?() do
      quote do: :eta_log.log(unquote(value))
    else
      0
    end
  end

  # -------------------------------------------------------------------------
  # @before_compile — observe and reply routing
  # -------------------------------------------------------------------------

  @doc false
  defmacro __before_compile__(env) do
    module = env.module

    if not dst?() do
      nil
    else
      behaviours = Module.get_attribute(module, :behaviour) || []
      observe = Module.get_attribute(module, :eta_observe)
      is_gen_server = :gen_server in behaviours
      net_enabled = Module.get_attribute(module, :eta_net) != false

      if is_gen_server and observe != nil do
        wrap_gen_server(module, observe, net_enabled)
      else
        nil
      end
    end
  end

  # Wraps gen_server callbacks to publish state and route replies.
  #
  # For `handle_call/3`: the second argument (From) is bound to a fresh
  # variable, and the body is wrapped in `__eta_reply__(from, body)` which
  # intercepts `{:reply, R, S}` returns and routes them through `:eta_net`.
  #
  # For observe: each callback body is wrapped so the return value's state is
  # published to the process dictionary via `__eta_publish__/1`.
  defp wrap_gen_server(module, observe, net_enabled) do
    callbacks = [
      {:init, 1},
      {:handle_call, 3},
      {:handle_cast, 2},
      {:handle_info, 2},
      {:handle_continue, 2},
      {:code_change, 3}
    ]

    wrapped =
      callbacks
      |> Enum.filter(fn {name, arity} -> Module.defines?(module, {name, arity}) end)
      |> Enum.flat_map(fn {name, arity} ->
        {:v1, :def, _meta, clauses} = Module.get_definition(module, {name, arity})
        Module.delete_definition(module, {name, arity})

        Enum.map(clauses, fn {_cmeta, args, guards, body} ->
          {new_args, new_body} = wrap_clause(name, arity, args, body, observe, net_enabled)
          build_def(name, new_args, guards, new_body)
        end)
      end)

    helpers = gen_server_helpers()
    {:__block__, [], helpers ++ wrapped}
  end

  # Wraps a single clause. For handle_call/3, keeps the original `from` variable
  # so the callback body can reference it for async replies (Eta.reply/2). The
  # reply router uses the same variable.
  defp wrap_clause(:handle_call, 3, [req, from, state] = args, body, observe, net_enabled) do
    new_body =
      body
      |> maybe_publish(observe)
      |> maybe_route_reply(net_enabled, from)

    {args, new_body}
  end

  defp wrap_clause(_name, _arity, args, body, observe, _net_enabled) do
    new_body = maybe_publish(body, observe)
    {args, new_body}
  end

  # Wraps a body so the return value's state is published to the process
  # dictionary. Inert when observe is nil.
  defp maybe_publish(body, nil), do: body

  defp maybe_publish(body, _observe) do
    quote do
      result = unquote(body)
      Eta.__publish__(result)
      result
    end
  end

  @doc false
  # Extracts and publishes the state from a gen_server callback return value.
  # Patterns match every shape a gen_server callback can return, with the state
  # in the right position for each.
  @dialyzer {:nowarn_function, __publish__: 1}
  def __publish__({:ok, s}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:ok, s, _}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:noreply, s}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:noreply, s, _}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:reply, _, s}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:reply, _, s, _}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:stop, _, s}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__({:stop, _, _, s}), do: :erlang.put(:eta_observe.key(), s)
  def __publish__(_), do: :ok

  # Wraps a body so `{:reply, R, S}` returns route through `:eta_net.reply/2`.
  # Inert when net is disabled.
  defp maybe_route_reply(body, false, _from), do: body

  defp maybe_route_reply(body, true, from) do
    quote do
      Eta.__route_reply__(unquote(from), unquote(body))
    end
  end

  @doc false
  # Routes a `handle_call/3` reply through `:eta_net`. The patterns are
  # intentionally broad — they cover every reply shape a `handle_call/3`
  # callback can return, and Dialyzer's per-SUT type inference can't see that.
  @dialyzer {:nowarn_function, __route_reply__: 2}
  def __route_reply__(from, {:reply, r, s}) do
    :eta_net.reply(from, r)
    {:noreply, s}
  end

  def __route_reply__(from, {:reply, r, s, x}) do
    :eta_net.reply(from, r)
    {:noreply, s, x}
  end

  def __route_reply__(from, {:stop, reason, r, s}) do
    :eta_net.reply(from, r)
    {:stop, reason, s}
  end

  def __route_reply__(_from, other), do: other

  # The helper functions generated alongside the wrapped callbacks.
  # (Currently none — the wrapping is inline — but kept as a hook for future
  # helpers like the observe record-field extraction.)
  defp gen_server_helpers do
    []
  end

  # Builds a `def` AST from args, guards, and body. Uses `unquote_splicing`
  # so each element of `args` becomes a separate function argument, not a
  # single list argument. Guards from `Module.get_definition/2` are a list of
  # AST expressions; combine them with `and` into a single guard expression.
  defp build_def(name, args, [], body) do
    quote do
      def unquote(name)(unquote_splicing(args)) do
        unquote(body)
      end
    end
  end

  defp build_def(name, args, guards, body) do
    guard_expr = combine_guards(guards)

    quote do
      def unquote(name)(unquote_splicing(args)) when unquote(guard_expr) do
        unquote(body)
      end
    end
  end

  defp combine_guards([single]), do: single
  defp combine_guards([h | t]), do: {:and, [], [h, combine_guards(t)]}
end
