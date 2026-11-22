-module(eta_net).

-compile(
    {nowarn_deprecated_function, [
        {gen_fsm, send_event, 2},
        {gen_fsm, send_all_state_event, 2}
    ]}
).

%% `monitor/2,3`, `demonitor/1,2` and the node functions are the API names,
%% shadowing the auto-imported BIFs. The originals are always reached qualified.
-compile(
    {no_auto_import, [
        monitor/2,
        monitor/3,
        demonitor/1,
        demonitor/2,
        node/0,
        node/1,
        nodes/0,
        nodes/1,
        is_alive/0,
        disconnect_node/1
    ]}
).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
A simulated network: seeded message loss, delay and partitions between processes
in one VM.

`eta_sched` decides which process runs. `eta_time` decides when a timer fires.
Neither module decides whether a message arrives. This module delivers the
messages that a system sends, and it can drop, delay or cut them.

With no network running, every function delegates to the function that it
replaces. A module built with `eta_transform` therefore behaves normally outside
a simulation. A network runs only when a harness starts one, with
`eta_net:start/1` or the `net` option of `eta_run:run/2`.

## Example

A send reaches `send/2` in one of three ways:

```erlang
Peer ! {replicate, Batch}.                     %% eta_transform rewrites this send
eta_net:send(Peer, {replicate, Batch}).        %% a direct call
myapp_link:send(Peer, {replicate, Batch}).     %% a call from a transport module
```

Use the transform, unless the system already has a transport module. In that
case, call `send/2` from the transport module and do not include the
`eta_transform` header.

## Requirements

- Route every send between two processes in the same way. If some sends between
  two processes go through this module and other sends go direct, a direct
  message can overtake a delayed message. Real Erlang never reorders the
  messages of one ordered pair of processes, so the result is a failure that the
  system cannot produce. The transform rewrites a whole module, so either every
  send of the module is routed or none is. A transport module is routed one call
  site at a time, and one `Pid ! ack` that is not routed breaks the requirement.
- Build the callee of `call/3` with `eta_transform`. See `call/3`.
- Declare the topology before the system creates monitors. See `monitor/2`.

## Model

The network produces only the faults that real Erlang produces. Distribution
guarantees that the messages between one ordered pair of processes arrive in
send order. Distribution does not guarantee delivery. A channel is one ordered
pair of processes. For each message on a channel, the network does one of the
following:

- It delivers the message.
- It drops the message.
- It delays the message.
- It drops the message because the channel is cut. A cut lasts until it is
  healed.

The network never reorders the messages of one channel.

Between two simulated nodes, the network also keeps the order of the link. Every
message from node A to node B travels on one connection, in the order in which
the senders handed the messages to the connection. A message is therefore never
delivered before a message that was scheduled earlier on the same link. A
delayed message delays the messages that follow it on the link, as on a TCP
connection. This rule covers a process that sends on behalf of another process.
The leader in ra does so when the send of the leader would block. Without the
rule, a later message of the other process could overtake that message.

A delay is virtual. A delayed message is a timer of `eta_time`, so the delay
takes no real time.

A perfect policy has `drop_p` and `delay_p` at 0.0. A network with a perfect
policy and no cut behaves as no network does. A run with `drop_p => 0.0` can
therefore serve as a control run.

The network decides the outcome of a send in this order:

1. A cut drops the message.
2. A pending `drop_next/3` or `drop_matching/5` drops the message.
3. The random policy drops, delays or delivers the message. See `set_policy/1`.

## Topology

A topology states which simulated node each process is on. A process has two
properties:

- **Located.** The process is on a simulated node. A located process receives
  the link events of the node and dies when the node is killed.
- **Faultable.** The network may drop or delay the messages of the process. A
  send is faulted only when both ends are faultable and the ends are on
  different simulated nodes.

| Process | Located | Faultable |
|---|---|---|
| Placed with `place/2` | Yes | Yes |
| Attached with `attach/2` | Yes | No |
| Neither placed nor attached, with a topology declared | No | No |
| Any process, with no topology declared | No | Yes |

A topology is declared by the first call to `place/2`, `attach/2` or
`register_name/3`. With no topology declared, every send is faultable.

A child process inherits the node and the faultable property of its parent. See
`inherit/2`.

`attach/2` exists for a process that must be on a node and must not have its
messages faulted. An example is a node that runs a member, an elector and a
connector under one supervisor:

- Only the member sends messages to its peers over the network.
- The elector coordinates with its peers through a durable store. A send of the
  elector stands for a store operation. A database commits or returns an error.
  A database does not lose a request. A dropped send of the elector is therefore
  a failure that the store cannot produce, and the divergence that follows has
  the same symptoms as a replication defect.
- The connector receives `nodedown` and `nodeup` and must die with its node. The
  connector must therefore be located.

The alternative is to place every process and to narrow the `scope` of the
policy until the store traffic is excluded. That alternative must be corrected
by hand each time the system adds a message. The topology states where the
network is for every run. The `scope` states which traffic one run may fault.

## Faults

| Function | Fault |
|---|---|
| `set_policy/1` | Random loss, delay and busy links, drawn from the seed. |
| `cut/2`, `heal/2` | One direction of a channel or of a link drops every message. No link event is delivered. |
| `partition/3`, `heal_partition/3` | Both directions are cut, and the link events are delivered. |
| `kill_node/2` | Every located process of a simulated node dies, and the link events are delivered. |
| `drop_next/3`, `drop_matching/5` | A fixed number of messages on one channel are dropped. |
| `disconnect_node/1` | The connection between two simulated nodes is closed. |

Prefer `partition/3` to `cut/2` for a link failure. A real link failure delivers
`nodedown` to both ends, and systems start recovery from that event. A fault
that only drops messages produces a state that no network produces. See
`partition/3`.

## Events

A link failure delivers two kinds of link event in addition to the lost
messages:

- **Node signals.** `partition/3`, `heal_partition/3` and `kill_node/2` take a
  `signal` option. The signal is sent to every located process on the affected
  side. See `partition/3` for the forms of a signal.
- **Synthetic `noconnection` DOWNs.** Every simulated monitor held across a
  failing link fires `{'DOWN', Ref, process, Object, noconnection}`. The target
  of such a monitor is still alive in the same VM, so a VM monitor does not
  fire. See `monitor/2` and `kill_node/2`.

A process subscribed with `monitor_nodes/1` also receives `{nodedown, Node}` and
`{nodeup, Node}`. See "Node identity".

Link events are delivered as follows:

- A link event is sent directly and is not routed. A cut therefore cannot drop
  the event that reports the cut.
- The calling driver sends every link event before the call returns, in a
  deterministic order. The schedule then decides when each process receives the
  event, as for any other message.
- A link event draws nothing from the fault generator. Adding a signal does not
  change which messages are dropped.

## Monitors

`eta_transform` points `erlang:monitor/2,3` and `erlang:demonitor/1,2` at this
module. A monitor between two processes on different simulated nodes is a
simulated monitor. A simulated monitor fires `noconnection` when its link fails.
Every other monitor is a VM monitor. See `monitor/2`.

## Node identity

In one VM every process is on the same real node. `node()`, `node(Pid)`,
`nodes()` and the events of `net_kernel` would give one result for a whole
simulated cluster. `eta_transform` points those calls at this module, and this
module takes the results from the topology:

- `node/0` returns the simulated node of the caller. `node/1` returns the
  simulated node on which a pid was placed or attached, also after the process
  has died.
- A connection is explicit, as in distribution. A new simulated node is
  connected to no node. `connect_node/1` connects two nodes, and so does a send
  to a process on another node. A send with the `noconnect` option does not
  connect. `nodes/0` lists the nodes to which the node of the caller is
  connected.
- `partition/3`, `kill_node/2` and `disconnect_node/1` disconnect nodes. Every
  process subscribed with `monitor_nodes/1` receives `{nodedown, Node}`. A heal
  does not reconnect the nodes. The subscribers receive `{nodeup, Node}` when a
  process connects the nodes again.
- Each node has its own record of its connections. `partition/3` with the
  `learns` option disconnects one side only. The other side remains connected in
  its own record.
- `send_nosuspend/2,3` can return `false` because the link is busy. A real
  system loses a message on a live connection in this way. See
  `send_nosuspend/3`.

A process on no simulated node gets the real BIFs. Examples are a harness, an
observer and a process that a test spawns and does not place. `with_node/2` lets
such a process call the node identity functions for one simulated node.

Names are separate for each simulated node. A process on a simulated node
registers names, creates named ETS tables and writes `persistent_term` keys in
the namespace of that node. A system can therefore use the same names on every
node, and `{Name, Node}` resolves to the process that holds `Name` on `Node`.
See `eta_ns`. A call to `rpc` or `erpc` for a simulated node runs on that node.
See `eta_rpc`.

## Determinism

- The fault generator is seeded by the `seed` option of `start/1`.
- The fault generator advances only when a decision has more than one possible
  outcome. These sends draw nothing: a send under a perfect policy, a send
  outside the `scope`, and a send that does not cross a faultable link.
- Link events draw nothing from the fault generator.
- Every fan-out of link events is ordered by a sequence number. The number is
  assigned when a process is first placed, when a monitor is created and when a
  process first subscribes with `monitor_nodes/1`.
- A send from a process that the scheduler is not stepping, to a process that
  the scheduler owns, is delivered at once and draws nothing. `stats/0` counts
  such a send as `unmanaged`.

## Limitations

- This module does not emulate distribution. A simulated node is a name in a
  table in one VM. A destination that cannot be resolved to a local process,
  such as `{global, _}`, `{via, _, _}` or a pid on a remote node, is passed to
  the ordinary function.
- One network runs per VM. Runs must be serial.
- The functions listed in `?NET_UNSUPPORTED` in `eta_transform` raise while a
  network is running. See `unsupported/2`.
- `node(X)` in a guard cannot be redirected. `eta_transform` refuses it at
  compile time.
- A name is resolved when the message is sent. `erlang:send/2` resolves a name
  when the message is delivered. The difference is observable only when a name
  is registered again while a message to it is delayed.
- A monitor created before its two ends are located is a VM monitor and never
  fires `noconnection`.
- A simulated monitor on a process that `eta_sched` does not own never fires for
  the exit of that process.
- A monitor created on the pid of a process that died in `kill_node/2` fires
  `noproc`. Real distribution fires `noconnection` for a node that is gone.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    start/0,
    start/1,
    stop/0,
    running/0
]).

-export([
    send/2,
    send/3,
    cast/2,
    send_event/2,
    send_all_state_event/2,
    call/2,
    call/3,
    reply/1,
    reply/2,
    statem_return/1,
    unsupported/2
]).

%% The asynchronous request and response interface of `gen_server` and
%% `gen_statem`. See `send_request/2`.
-export([
    send_request/2,
    send_request/4,
    wait_response/1,
    wait_response/2,
    wait_response/3,
    receive_response/1,
    receive_response/2,
    receive_response/3,
    check_response/2,
    check_response/3
]).

%% Policy.
-export([
    set_policy/1,
    policy/0
]).

%% Topology — which simulated node each process is on. See `place/2`.
-export([
    place/2,
    attach/2,
    register_name/3,
    unregister_name/2,
    whereis_name/2,
    node_of/1,
    faultable/1,
    inherit/2,
    introduce/1
]).

%% Monitors. What `eta_transform` points a system's `erlang:monitor/2,3` at, so a
%% severed link can fire the `noconnection` DOWNs real distribution would.
-export([
    monitor/2,
    monitor/3,
    demonitor/1,
    demonitor/2,
    notify_exit/2,
    exited/1
]).

%% Membership: who a process's node is, who it is connected to, and the
%% `net_kernel` events that say when that changes. See "Node identity" above.
-export([
    node/0,
    node/1,
    nodes/0,
    nodes/1,
    is_alive/0,
    monitor_nodes/1,
    monitor_nodes/2,
    monitor_node/2,
    monitor_node/3,
    connect_node/1,
    disconnect_node/1,
    ping/1,
    send_nosuspend/2,
    send_nosuspend/3,
    with_node/2,
    local_node/0,
    is_node/1,
    await/3
]).

%% Targeted faults.
-export([
    cut/2,
    heal/2,
    partition/2,
    partition/3,
    heal_partition/2,
    heal_partition/3,
    heal_all/0,
    kill_node/1,
    kill_node/2,
    drop_next/3,
    drop_matching/5
]).

%% Observation.
-export([
    stats/0,
    in_flight/0
]).

-export_type([policy/0, scope/0, signal/0, learns/0, event_opts/0]).

-define(STATE, eta_net_state).
-define(CHAN, eta_net_chan).
-define(PLACE, eta_net_place).
-define(CALLS, eta_net_calls).
-define(MONS, eta_net_mons).
%% Pids the scheduler has reported as exited. See `simulate_monitor/4` for why
%% this exists rather than asking the VM.
-define(DEAD, eta_net_dead).
%% Who spawned whom, as far as anybody has said or been asked. Its own table,
%% not rows in `?PLACE`: an empty `?PLACE` is how "no topology was declared" is
%% told apart from "nothing is on the wire", and a spawner is not a placement.
%% See `spawner/1`.
-define(SPAWNERS, eta_net_spawners).

-type dest() :: pid() | atom().

%% What a link event says. An atom is a *kind*, derived per side into
%% `{Kind, Other}`; anything else is delivered as written. See `partition/3`.
-type signal() :: atom() | {literal, term()} | term().

%% Which side of a partition observes the failure. See `partition/3`.
-type learns() :: both | a | b.

-type event_opts() :: #{signal => signal(), learns => learns()}.

-type scope() :: all | {tags, [term()]} | fun((pid(), dest(), term()) -> boolean()).

-type policy() :: #{
    drop_p => float(),
    delay_p => float(),
    max_delay => pos_integer(),
    scope => scope(),
    busy_p => float(),
    busy_ms => pos_integer()
}.

-define(DEFAULT_POLICY, #{
    drop_p => 0.0,
    delay_p => 0.0,
    max_delay => 20,
    scope => all,
    busy_p => 0.0,
    busy_ms => 1000
}).

%% The process dictionary key `with_node/2` sets.
-define(AS_NODE, '$eta_net_node').

%% `signalled` and `noconnection` count link *events* rather than traffic, and are
%% what a non-vacuity guard on a partition asserts on: a run whose partition
%% reached nobody exercised no recovery path.
%% `busy` counts `send_nosuspend` calls refused because the link was busy. Those
%% messages are not `dropped`: the sender was told, which is the whole difference.
-define(COUNTERS, [
    delivered, dropped, delayed, cancelled, unmanaged, signalled, noconnection, busy
]).

%% ---------------------------------------------------------------------------
%% Lifecycle
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "Starts a network with the default options. See `start/1`.".
-endif.
-spec start() -> ok.
start() ->
    start(#{}).

-if(?DOCATTRS).
-doc """
Starts the network.

Options:

| Option | Default | Meaning |
|---|---|---|
| `seed` | `0` | The seed of the fault generator. The same seed gives the same fault decisions. |
| `policy` | A perfect policy | The fault policy. See `set_policy/1`. |

The default policy is perfect because a cluster needs every message while it
starts.

One network runs per VM, as with `eta_time` and `eta_log`, so runs must be
serial. If the calling process already owns a running network, `start/1` resets
that network. If another live process owns the network, `start/1` raises
`{eta_net, {network_in_use, Owner, Text}}`.
""".
-endif.
-spec start(#{seed => integer(), policy => policy()}) -> ok.
start(Opts) ->
    ok = claim(),
    stop(),
    ?STATE = ets:new(?STATE, [named_table, public, set]),
    ?CHAN = ets:new(?CHAN, [named_table, public, set]),
    ?PLACE = ets:new(?PLACE, [named_table, public, set]),
    ?CALLS = ets:new(?CALLS, [named_table, public, set]),
    ?MONS = ets:new(?MONS, [named_table, public, set]),
    ?DEAD = ets:new(?DEAD, [named_table, public, set]),
    ?SPAWNERS = ets:new(?SPAWNERS, [named_table, public, set]),
    Seed = maps:get(seed, Opts, 0),
    ets:insert(?STATE, [
        {rand, rand:seed_s(exsss, {Seed, Seed + 11, Seed + 23})},
        %% Not the fault RNG and not a clock: a monotonic counter, stamped onto
        %% every placement and every monitor, so that a fan-out of link events can
        %% be ordered by something the run itself decided. See `endpoints/1`.
        {seq, 0},
        {policy, merge_policy(maps:get(policy, Opts, #{}))}
        | [{C, 0} || C <- ?COUNTERS]
    ]),
    ok.

%% The existence of the named table is the lock: the VM destroys it when its owner
%% exits. `stop/0` is deliberately unguarded, so an `on_exit` running in another
%% process still cleans up.
claim() ->
    case ets:info(?STATE, owner) of
        undefined ->
            ok;
        Self when Self =:= self() ->
            ok;
        Other ->
            error(
                {eta_net,
                    {network_in_use, Other, <<
                        "one per VM; keep runs serial (`async: false`) and do "
                        "not drive two at once"
                    >>}}
            )
    end.

-if(?DOCATTRS).
-doc """
Stops the network. Returns `ok` also when no network is running.

A delayed message is an `eta_time` timer. A message that is delayed when the
network stops is still delivered when the clock reaches its deadline.
""".
-endif.
-spec stop() -> ok.
stop() ->
    lists:foreach(
        fun(Tab) ->
            try
                ets:delete(Tab)
            catch
                error:badarg -> ok
            end
        end,
        [?STATE, ?CHAN, ?PLACE, ?CALLS, ?MONS, ?DEAD, ?SPAWNERS]
    ),
    ok.

-if(?DOCATTRS).
-doc "Returns `true` when a network is running. When no network is running, every function of this module delegates.".
-endif.
-spec running() -> boolean().
running() ->
    ets:whereis(?STATE) =/= undefined.

%% ---------------------------------------------------------------------------
%% The seam
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Sends `Msg` to `Dest` through the network.

Returns `Msg`, as `Dest ! Msg` and `erlang:send/2` do.

`Dest` is a pid, a registered name or `{Name, Node}`. The destination is handled
as follows:

- A destination that resolves to a local process is routed.
- `{Name, Node}`, where `Node` is a simulated node and no process holds `Name`
  there, receives nothing. The message is discarded and is not counted as
  dropped.
- Any other destination, such as `{global, _}`, `{via, _, _}` or a pid on a
  remote node, is passed to `erlang:send/2`. This module does not simulate
  distribution.
""".
-endif.
-spec send(dest() | term(), term()) -> term().
send(Dest, Msg) ->
    case running() andalso normalize(Dest) of
        To when is_pid(To) ->
            route(self(), To, Msg);
        _ ->
            case nobody(Dest) of
                true -> Msg;
                false -> erlang:send(Dest, Msg)
            end
    end.

-if(?DOCATTRS).
-doc """
`erlang:send/3`.

Between two simulated nodes the options have the meaning that they have in
distribution:

- With `noconnect`, the function returns `noconnect` and sends nothing when the
  node of the sender is not connected to the node of the destination.
- With `nosuspend`, the function returns `nosuspend` and sends nothing while the
  link is busy. See `send_nosuspend/3`.

Without `noconnect`, the send first connects the two nodes. If the nodes cannot
be connected, the function sends nothing and returns `ok`.

A routed send between two local processes that are not on two different
simulated nodes ignores the options and returns `ok`. Any other destination is
passed to `erlang:send/3`.
""".
-endif.
-spec send(dest() | term(), term(), list()) -> ok | nosuspend | noconnect.
send(Dest, Msg, Opts) ->
    case running() andalso across(Dest) of
        {Here, There} ->
            remote_send(Here, There, Dest, Msg, Opts, send);
        false ->
            case running() andalso normalize(Dest) of
                To when is_pid(To) ->
                    _ = route(self(), To, Msg),
                    ok;
                _ ->
                    erlang:send(Dest, Msg, Opts)
            end
    end.

-if(?DOCATTRS).
-doc """
`gen_server:cast/2`, routed through the network.

The message is tagged by the leading element of `Msg`, not by `'$gen_cast'`. See
`set_policy/1`. The function returns `ok` and never raises, also for a name that
is not registered.
""".
-endif.
-spec cast(dest() | term(), term()) -> ok.
cast(Dest, Msg) ->
    case running() andalso normalize(Dest) of
        To when is_pid(To) ->
            %% Tagged by the payload rather than by OTP's `'$gen_cast'` envelope,
            %% which every cast carries and so would select all of them or none.
            catch route(self(), To, {'$gen_cast', Msg}, tag(Msg)),
            ok;
        _ ->
            case nobody(Dest) of
                true -> ok;
                false -> gen_server:cast(Dest, Msg)
            end
    end.

-if(?DOCATTRS).
-doc """
`gen_fsm:send_event/2`, routed through the network.

The message is sent as `{'$gen_event', Event}` and is tagged by the leading
element of `Event`, as in `cast/2`.
""".
-endif.
-spec send_event(dest() | term(), term()) -> ok.
send_event(Dest, Event) ->
    case running() andalso normalize(Dest) of
        To when is_pid(To) ->
            catch route(self(), To, {'$gen_event', Event}, tag(Event)),
            ok;
        _ ->
            case nobody(Dest) of
                true -> ok;
                false -> gen_fsm:send_event(Dest, Event)
            end
    end.

-if(?DOCATTRS).
-doc "`gen_fsm:send_all_state_event/2`, routed through the network. See `send_event/2`.".
-endif.
-spec send_all_state_event(dest() | term(), term()) -> ok.
send_all_state_event(Dest, Event) ->
    case running() andalso normalize(Dest) of
        To when is_pid(To) ->
            catch route(self(), To, {'$gen_all_state_event', Event}, tag(Event)),
            ok;
        _ ->
            case nobody(Dest) of
                true -> ok;
                false -> gen_fsm:send_all_state_event(Dest, Event)
            end
    end.

-if(?DOCATTRS).
-doc """
`gen_server:call/2,3` and `gen_statem:call/2,3`, with the request and the reply
both routed through the network.

Both behaviours use this function, because both send the request as
`{'$gen_call', From, Request}`.

`call/2` uses a time-out of 5000 ms. `call/3` accepts a `timeout()`,
`{clean_timeout, T}` or `{dirty_timeout, T}`. Both tuple forms are treated as
`T`.

## Request and reply

- The request is a send that this module routes. The request is tagged by the
  leading element of `Request`.
- The reply is sent by the callee. `gen:reply` sends the reply from inside OTP,
  so this module cannot route that send. `eta_transform` therefore rewrites the
  returns of the callee. A `{reply, R, S}` return of a `gen_server` becomes
  `eta_net:reply(From, R)` and `{noreply, S}`. A `{reply, From, R}` action of a
  `gen_statem` is removed from the action list and sent with `reply/2`. See
  `statem_return/1`.

The network can drop or delay the request and the reply independently. A dropped
reply produces the case in which the callee did the work and the caller did not
receive the result.

## Paths

| Condition | Request | Time-out |
|---|---|---|
| A network is running. | Routed. | Virtual, under the rule below. |
| No network is running and a virtual clock is running. | Sent with `erlang:send/2`, using the protocol and the alias of `gen:call`. | Virtual, under the rule below. |
| No network and no virtual clock are running. | `gen_server:call/3`. | Real. |

The second path is the default configuration of `eta_run:run/2`, which has
`net => false`. On that path the VM discards a reply that arrives after the
time-out, as it does outside a simulation.

The time-out is virtual only when the virtual clock will reach the deadline:

- With no scheduler active, every caller gets a virtual time-out.
- With a scheduler active, only the process that `eta_sched` is stepping gets a
  virtual time-out. `eta_run` advances the clock only to the deadlines of
  processes that it owns. A virtual deadline of any other caller, such as the
  driver or a harness `execute/2` that calls directly, would never be reached.
  Such a caller gets a real time-out.

The check reads `eta_sched:stepping/0`. A real time-out for an owned caller
makes the run nondeterministic. A virtual time-out for a caller that is not
owned stops the run. The check therefore selects the real time-out when the
caller is not the stepped process.

## Monitor

The call monitors the callee with a VM monitor, so that the exit of the callee
ends the call. While a network is running, the same monitor is also recorded as
a simulated monitor for the duration of the call. `partition/3`, `kill_node/2`
and `disconnect_node/1` then fire it with `noconnection`. Without this, a call
with an `infinity` time-out across a partition would never return.

A call to a callee that has already exited fails with `noproc` from the record
of `notify_exit/2`, without a monitor.

## Exits and errors

The call exits with `{Reason, {eta_net, call, [Dest, Request, Timeout]}}`.
`Reason` is one of:

| Reason | Condition |
|---|---|
| `timeout` | The time-out passed with no reply. |
| `{nodedown, Node}` | A network is running, and the link to the node of the callee was cut in both directions before the call or failed during the call. A call into a cut link sends nothing. |
| `noproc` | A network is running, `Dest` is `{Name, Node}`, `Node` is a simulated node, and no process holds `Name` there. |
| The exit reason of the callee | The callee exited during the call. |

When a network is running, a reply that arrives after the time-out is dropped.
See `reply/2`.

When a network is running, the call raises
`{eta_net, {unrouted_reply, Callee, Tag, Text}}` if the reply reached the caller
without passing through `reply/2`. The reply could then not be faulted. The
causes are:

- The callee was not built with `eta_transform`.
- The callee answers the call with a plain send to the caller, instead of
  `gen_server:reply/2` or a `gen_statem` reply action.
""".
-endif.
-spec call(dest() | term(), term()) -> term().
call(Dest, Req) ->
    call(Dest, Req, 5000).

-spec call(dest() | term(), term(), timeout() | {clean_timeout | dirty_timeout, timeout()}) ->
    term().
call(Dest, Req, Timeout0) ->
    Timeout = call_timeout(Timeout0),
    case normalize(Dest) of
        To when is_pid(To) ->
            case running() of
                true -> do_call(To, Dest, Req, Timeout);
                false -> sim_call(To, Dest, Req, Timeout)
            end;
        _ ->
            %% A `{Name, Node}` naming a simulated node with nothing registered
            %% under `Name' — the server died with its node, say — is `noproc`,
            %% as a call to an unregistered local name is. Handing it to
            %% `gen_server:call/3` instead would have the VM try to reach a node
            %% that does not exist, on the real clock. See `monitor/2`.
            case running() andalso on_simulated_node(Dest) of
                true -> exit({noproc, {eta_net, call, [Dest, Req, Timeout]}});
                false -> gen_server:call(Dest, Req, Timeout)
            end
    end.

%% A `{Name, Node}` that names a simulated node and resolved to no process:
%% the server died with its node, or was never started. A message to it goes
%% nowhere, as one to an unregistered name on a live node does.
%%
%% It must not be handed to OTP, which takes the node for a real one.
%% `gen_server:cast/2` answers a node it is not connected to by spawning a
%% process to connect and send, and that process is one nothing gated: it is
%% adopted late and runs on the real scheduler. A plain send tries the
%% connection in the sender, on the real clock. `call/3` has always refused
%% for the same reason; this is the same rule for the sends, which cannot
%% refuse and so drop.
%%
%% Nothing is counted. `dropped` is what a fault-vacuity guard asserts on, and
%% this is not a fault: the network delivered to a node where nobody was
%% listening.
nobody(Dest) ->
    running() andalso on_simulated_node(Dest).

%% Whether a deadline armed by *this* process will actually be reached.
%%
%% Needs a clock, obviously. The second condition is the one with teeth: if a
%% scheduler is running then `eta_run` drives the clock, and it advances only to
%% deadlines owned by a process it can step. `eta_sched:stepping/0` is the
%% sharpest available statement of that, and it is an ETS read — asking the
%% scheduler would deadlock against the very step this is running inside.
%%
%% With no scheduler at all (a unit test driving `eta_time:advance/1` by hand)
%% every deadline is reachable, so the clock alone is enough.
virtual_timeout() ->
    eta_time:running() andalso
        (not eta_sched:active() orelse eta_sched:stepping() =:= self()).

%% `gen_statem:call/3` accepts `{clean_timeout, T}` and `{dirty_timeout, T}` as
%% well as a plain `timeout()`. Both choose how the *caller* waits — whether the
%% wait happens in a proxy process — and neither is meaningful here: this module
%% waits in a receive of its own, on the virtual clock. Unwrapping to the number
%% is the honest reading, and it keeps `call/3` a single target for both
%% behaviours.
%%
%% What `clean_timeout` is *for* — a reply that arrives after the caller gave up
%% never reaching the caller's mailbox — is honoured on both paths regardless of
%% which form was asked for: by the alias in `sim_call/4`, and by the abandoned
%% tag in `do_call/4`. The proxy process is the mechanism, and the mechanism is
%% what does not survive; the guarantee does.
call_timeout({clean_timeout, T}) -> T;
call_timeout({dirty_timeout, T}) -> T;
call_timeout(T) -> T.

do_call(To, Dest, Req, Timeout) ->
    %% A link already down is refused before anything is sent, as distribution
    %% refuses a node it cannot connect to — rather than routing a request the
    %% cut will swallow and waiting out a timeout the caller may not have.
    case link_down(self(), To) of
        true -> exit({{nodedown, node_of(To)}, {eta_net, call, [Dest, Req, Timeout]}});
        false -> ok
    end,
    %% A callee that has already exited is `noproc`, from the record of
    %% `notify_exit/2`. A VM monitor on such a process is answered by the
    %% process while the VM removes it, at a time that the VM decides, so the
    %% `DOWN' message could arrive after the caller has blocked. See
    %% `simulate_monitor/4`.
    case target_dead(To) of
        true -> exit({noproc, {eta_net, call, [Dest, Req, Timeout]}});
        false -> ok
    end,
    Tag = make_ref(),
    Mon = erlang:monitor(process, To),
    %% Before the request goes out, so a reply cannot beat the registration and be
    %% mistaken for an unrouted one.
    true = ets:insert(?CALLS, {Tag, outstanding}),
    %% The same monitor, entered in the simulated table for the duration of the
    %% call so `sever/3` can fire it with `noconnection` when a partition cuts
    %% the link. Taken out again on every way out below, since a DOWN for a call
    %% that has finished would land as a message nothing expects.
    true = ets:insert(?MONS, {Mon, self(), To, To, 'DOWN', next_seq()}),
    _ = route(self(), To, {'$gen_call', {self(), Tag}, Req}, tag(Req)),
    Result = wait(Tag, Mon, Timeout),
    true = ets:delete(?MONS, Mon),
    case Result of
        {reply, Reply} ->
            true = erlang:demonitor(Mon, [flush]),
            ok = check_routed(Tag, To, Req),
            Reply;
        {down, noconnection} ->
            %% The link went while the call was out. Flushed, because the real
            %% monitor is still armed and the synthetic DOWN did not consume it.
            true = erlang:demonitor(Mon, [flush]),
            true = ets:delete(?CALLS, Tag),
            exit({{nodedown, node_of(To)}, {eta_net, call, [Dest, Req, Timeout]}});
        {down, Reason} ->
            true = erlang:demonitor(Mon, [flush]),
            true = ets:delete(?CALLS, Tag),
            exit({Reason, {eta_net, call, [Dest, Req, Timeout]}});
        timeout ->
            true = erlang:demonitor(Mon, [flush]),
            %% Marked, not deleted. The reply may still be coming — the callee is
            %% alive and may be about to answer, or the answer may be sitting in
            %% the network on a delay — and `reply/2` needs to know this caller
            %% has stopped listening so it can drop it.
            %%
            %% Outside a simulation the VM does this for us: `gen:call/4` waits on
            %% an alias and deactivates it on timeout, so a late reply is
            %% discarded before it reaches the mailbox. `reply/2` routes to the
            %% caller's *pid* rather than to the alias, because the network places
            %% and faults pids, so that protection is gone here and has to be
            %% rebuilt. Without it a late reply lands as a `{Tag, Reply}` nothing
            %% will ever match — which for a `gen_server` caller is an
            %% `handle_info` clause it never expected, and a crash the simulation
            %% manufactured rather than found.
            %%
            %% One entry per timed-out call, taken by `reply/2` if the reply does
            %% arrive and discarded with the table otherwise.
            true = ets:insert(?CALLS, {Tag, abandoned}),
            exit({timeout, {eta_net, call, [Dest, Req, Timeout]}})
    end.

%% The same request `gen:call/4` sends and the same wait, with the deadline moved
%% onto the virtual clock. For a run with a clock but no network — the default —
%% where there is nothing to route but every reason to keep the timeout off the
%% wall clock. See `call/3`.

%% `[alias|Mon]` is an improper list, and deliberately: it is the tag shape
%% `gen:reply/2` matches on to answer through an alias rather than a pid, so it
%% has to be built exactly this way or the protection below does not exist. The
%% analyser has no way to know that, and the warning is right about the shape and
%% wrong about the intent.
-dialyzer({no_improper_lists, sim_call/4}).
sim_call(To, Dest, Req, Timeout) ->
    case virtual_timeout() of
        false ->
            gen_server:call(Dest, Req, Timeout);
        true ->
            %% `{alias, demonitor}` and the `[alias|Mon]` tag are `gen`'s, copied
            %% deliberately: `gen:reply/2` recognises that tag shape and answers
            %% through the alias, so the `demonitor` below deactivates it and a
            %% reply that loses the race to the timeout is dropped by the VM. That
            %% is the protection `do_call/4` has to rebuild by hand, and here it
            %% comes for free.
            Mon = erlang:monitor(process, To, [{alias, demonitor}]),
            Tag = [alias | Mon],
            _ = erlang:send(To, {'$gen_call', {self(), Tag}, Req}),
            case wait(Tag, Mon, Timeout) of
                {reply, Reply} ->
                    true = erlang:demonitor(Mon, [flush]),
                    Reply;
                {down, Reason} ->
                    exit({Reason, {eta_net, call, [Dest, Req, Timeout]}});
                timeout ->
                    true = erlang:demonitor(Mon, [flush]),
                    exit({timeout, {eta_net, call, [Dest, Req, Timeout]}})
            end
    end.

%% One receive for both clocks.
%%
%% When the deadline can be reached virtually it arrives as a message and the real
%% `after` is `infinity`; otherwise nothing is armed, the `'$eta_after'` clause
%% cannot match because nothing will ever send it, and the real `after` is the
%% deadline. Writing it as one receive rather than two keeps the reply and `DOWN`
%% clauses from being stated twice, which is where a divergence would hide.
-if(?DOCATTRS).
-doc false.
-endif.
%% `wait/3` for `eta_rpc`, which waits on a worker the same way a call waits on a
%% server.
-spec await(term(), reference(), timeout()) -> {reply, term()} | {down, term()} | timeout.
await(Tag, Mon, Timeout) ->
    wait(Tag, Mon, Timeout).

wait(Tag, Mon, Timeout) ->
    Ref = make_ref(),
    {TRef, Real} =
        case virtual_timeout() of
            true -> {eta_time:arm_after(Timeout, Ref), infinity};
            false -> {undefined, Timeout}
        end,
    receive
        {Tag, Reply} ->
            ok = eta_time:disarm_after(TRef, Ref),
            {reply, Reply};
        {'DOWN', Mon, process, _, Reason} ->
            ok = eta_time:disarm_after(TRef, Ref),
            {down, Reason};
        {'$eta_after', G} when G =:= Ref ->
            timeout
    after Real ->
        timeout
    end.

%% `reply/2` takes the tag out on its way past, so a tag still here when the reply
%% lands means the callee answered by a path this module never saw.
%%
%% What it does *not* tell you is which path. The message used to name one cause
%% — "the callee was not built with eta_transform" — and that is only the first
%% of two, which sends anyone hitting the second one to look in the wrong place.
%% A module can carry the transform and still answer from somewhere the transform
%% has nothing to rewrite: `locks_agent` replies to its waiters with a bare
%% `Pid ! {Tag, Status}` rather than `gen_server:reply/2`, so the send is routed
%% as an ordinary message and the tag survives. The guard is right in both cases;
%% only the explanation was wrong.
check_routed(Tag, To, Req) ->
    case ets:take(?CALLS, Tag) of
        [] ->
            ok;
        [_] ->
            error(
                {eta_net,
                    {unrouted_reply, To, tag(Req), <<
                        "the reply reached the caller without passing through this "
                        "module, so it could not be faulted. Either the callee was "
                        "not built with eta_transform, or it answers this call from "
                        "somewhere the transform does not rewrite - a bare send to "
                        "the caller rather than gen_server:reply/2 or a gen_statem "
                        "reply action. Route that reply, build the callee with the "
                        "transform, or place both ends on one node"
                    >>}}
            )
    end.

-if(?DOCATTRS).
-doc """
`gen_server:reply/2` and `gen_statem:reply/2`, routed through the network.

A reply can therefore be dropped or delayed independently of its request.
`eta_transform` rewrites the `handle_call/3` returns of a `gen_server` and the
reply actions of a `gen_statem` to call this function. See `call/3`.

- The reply is sent to the pid of the caller, not to the alias in the tag. The
  selective receive of the caller matches on the tag in both cases.
- Every reply is tagged `'$gen_reply'`. See `set_policy/1`.
- A reply to a caller whose `call/3` has timed out is discarded. Outside a
  simulation, the alias of `gen:call` discards such a reply.
- With no network running, or when `From` is not `{Pid, Tag}`, the function
  calls `gen_server:reply/2`.
""".
-endif.
-spec reply(term(), term()) -> ok.
reply(From = {To, Tag}, Reply) when is_pid(To) ->
    case running() of
        true ->
            %% Taking the tag marks the call answered through the network —
            %% `call/3` uses the absence to detect a reply that came around it —
            %% and reads the caller's disposition in the same operation.
            %%
            %% `abandoned` means the caller timed out and is no longer listening,
            %% so this reply is dropped rather than routed. Anything else is
            %% either an outstanding call or a tag this module never issued (an
            %% untransformed client's, which is an ordinary alias), and both are
            %% answered.
            %%
            %% Tagged `'$gen_reply'` rather than by the caller's tag, which is a
            %% fresh reference per call and so names nothing a policy could scope
            %% on.
            case ets:take(?CALLS, Tag) of
                [{Tag, abandoned}] ->
                    ok;
                _ ->
                    _ = route(self(), To, {Tag, Reply}, '$gen_reply'),
                    ok
            end;
        false ->
            gen_server:reply(From, Reply)
    end;
reply(From, Reply) ->
    gen_server:reply(From, Reply).

-if(?DOCATTRS).
-doc """
`gen_statem:reply/1`, routed through the network.

The argument is one `{reply, From, Reply}` tuple or a list of them. Each reply
is sent with `reply/2`.
""".
-endif.
-spec reply([{reply, term(), term()}] | {reply, term(), term()}) -> ok.
reply({reply, From, Reply}) ->
    reply(From, Reply);
reply(Replies) when is_list(Replies) ->
    lists:foreach(fun(R) -> reply(R) end, Replies).

-if(?DOCATTRS).
-doc """
`gen_server:send_request/2` and `gen_statem:send_request/2`, with the request
and the reply both routed through the network.

Both behaviours use this function, because both send the request as
`{'$gen_call', From, Request}`. The result is a request id for
`wait_response/2`, `receive_response/2` and `check_response/2`.

With no network running, this function and the response functions call the
`gen_server` functions of the same name.

## Request and reply

- The request is a send that this module routes. The request is tagged by the
  leading element of `Request`, as for `call/3`.
- The reply is sent by the callee through `reply/2`, to the pid of the caller.
  `eta_transform` rewrites the returns of the callee. See `call/3`.

The network can drop or delay the request and the reply independently. A
request whose reply is dropped has no response until its monitor fires or the
caller stops waiting.

## Monitor

`gen_server:send_request/2` monitors the callee, and the request id is the
reference of the monitor. This function does the same:

| Caller and callee | Monitor |
|---|---|
| On two simulated nodes | A simulated monitor. See `monitor/2`. `partition/3`, `kill_node/2` and `disconnect_node/1` fire it with `noconnection`, and the exit of the callee fires it with the exit reason. |
| On one simulated node, or not placed | A VM monitor. |

A request to a callee that has already exited, or to a name that no process
holds, is answered at once with `noproc`. A request across a link that is down
is answered at once with `noconnection`. No request is sent in these cases.

## Responses

The response functions return what the `gen_server` functions return:

| Result | Condition |
|---|---|
| `{reply, Reply}` | The reply arrived. |
| `{error, {Reason, ServerRef}}` | The monitor fired. `Reason` is the exit reason of the callee, `noproc` or `noconnection`. |
| `timeout` | `wait_response/2` or `receive_response/2` waited for the time-out. |
| `no_reply` | The message that `check_response/2` received is not a response to the request. |

The time-out of `wait_response/2` and `receive_response/2` is virtual under the
rule of `call/3`. `receive_response/2` abandons the request when the time-out
passes, as `gen_server:receive_response/2` does.

A reply to a request that the caller has abandoned, or whose monitor has fired,
is discarded if the callee sends it after that. A reply that the network was
delaying at that time is delivered to the caller as an ordinary message.

## Limitations

- The reply is sent to the pid of the caller and not to an alias. The request id
  is therefore not an alias, and `erlang:unalias/1` on it has no effect.
- A destination that this module cannot resolve to a local process or to a name
  on a simulated node, such as `{global, Name}` or `{via, Module, Name}`, is
  passed to `gen_server:send_request/2`. That request is not routed.
""".
-endif.
%% `[alias | Ref]` is the tag shape of `gen:send_request/3`, which the response
%% functions of `gen_server` also match. It is an improper list on purpose.
-dialyzer({no_improper_lists, [request/2, abandon/1, response_msg/3]}).
-spec send_request(dest() | term(), term()) -> reference().
send_request(Dest, Req) ->
    case running() of
        true -> request(Dest, Req);
        false -> gen_server:send_request(Dest, Req)
    end.

-if(?DOCATTRS).
-doc """
`gen_server:send_request/4` and `gen_statem:send_request/4`: sends the request
and adds its request id to the collection `Collection` with the label `Label`.
See `send_request/2`.
""".
-endif.
-spec send_request(dest() | term(), term(), term(), gen_server:request_id_collection()) ->
    gen_server:request_id_collection().
send_request(Dest, Req, Label, Collection) ->
    case running() of
        true -> gen_server:reqids_add(request(Dest, Req), Label, Collection);
        false -> gen_server:send_request(Dest, Req, Label, Collection)
    end.

request(Dest, Req) ->
    Watcher = self(),
    case normalize(Dest) of
        To when is_pid(To) ->
            case request_monitor(Watcher, To) of
                {established, Ref} ->
                    Tag = [alias | Ref],
                    %% Before the request goes out, as in `do_call/4'.
                    true = ets:insert(?CALLS, {Tag, outstanding}),
                    _ = route(Watcher, To, {'$gen_call', {Watcher, Tag}, Req}, tag(Req)),
                    Ref;
                {fired, Ref} ->
                    Ref
            end;
        _ ->
            case is_atom(Dest) orelse on_simulated_node(Dest) of
                true ->
                    %% No process holds the name. `gen_server:send_request/2'
                    %% answers this with a `noproc' from the VM monitor.
                    down_now(Watcher, object(Dest), noproc);
                false ->
                    gen_server:send_request(Dest, Req)
            end
    end.

%% The monitor of a request. `fired' means that the `DOWN' message is already
%% in the mailbox of the caller, and that no request must be sent.
request_monitor(Watcher, To) ->
    case simulated_pair(Watcher, To) of
        true ->
            Ref = simulate_monitor(Watcher, To, To, []),
            case ets:member(?MONS, Ref) of
                true -> {established, Ref};
                false -> {fired, Ref}
            end;
        false ->
            %% The VM is not asked about a callee that has exited. See
            %% `do_call/4'.
            case target_dead(To) of
                true -> {fired, down_now(Watcher, To, noproc)};
                false -> {established, erlang:monitor(process, To)}
            end
    end.

down_now(Watcher, Object, Reason) ->
    Ref = make_ref(),
    _ = erlang:send(Watcher, {'DOWN', Ref, process, Object, Reason}),
    Ref.

-if(?DOCATTRS).
-doc "`gen_statem:wait_response/1`. See `send_request/2`.".
-endif.
-spec wait_response(reference()) -> {reply, term()} | {error, {term(), term()}}.
wait_response(ReqId) ->
    wait_response(ReqId, infinity).

-if(?DOCATTRS).
-doc """
`gen_server:wait_response/2` and `gen_statem:wait_response/2`. The request
stays outstanding after a time-out. See `send_request/2`.
""".
-endif.
-spec wait_response(reference(), response_timeout()) ->
    {reply, term()} | {error, {term(), term()}} | timeout.
wait_response(ReqId, Timeout) ->
    case running() of
        true -> await_response(ReqId, Timeout, keep);
        false -> gen_server:wait_response(ReqId, Timeout)
    end.

-if(?DOCATTRS).
-doc """
`gen_server:wait_response/3` and `gen_statem:wait_response/3`, for a collection
of request ids. See `send_request/2`.
""".
-endif.
-spec wait_response(gen_server:request_id_collection(), response_timeout(), boolean()) ->
    {{reply, term()} | {error, {term(), term()}}, term(), gen_server:request_id_collection()}
    | no_request
    | timeout.
wait_response(Collection, Timeout, Delete) ->
    case running() of
        true -> await_response(Collection, Timeout, Delete, keep);
        false -> gen_server:wait_response(Collection, Timeout, Delete)
    end.

-if(?DOCATTRS).
-doc "`gen_statem:receive_response/1`. See `send_request/2`.".
-endif.
-spec receive_response(reference()) -> {reply, term()} | {error, {term(), term()}}.
receive_response(ReqId) ->
    receive_response(ReqId, infinity).

-if(?DOCATTRS).
-doc """
`gen_server:receive_response/2` and `gen_statem:receive_response/2`. The
request is abandoned after a time-out. See `send_request/2`.
""".
-endif.
-spec receive_response(reference(), response_timeout()) ->
    {reply, term()} | {error, {term(), term()}} | timeout.
receive_response(ReqId, Timeout) ->
    case running() of
        true -> await_response(ReqId, Timeout, abandon);
        false -> gen_server:receive_response(ReqId, Timeout)
    end.

-if(?DOCATTRS).
-doc """
`gen_server:receive_response/3` and `gen_statem:receive_response/3`, for a
collection of request ids. Every request of the collection is abandoned after a
time-out. See `send_request/2`.
""".
-endif.
-spec receive_response(gen_server:request_id_collection(), response_timeout(), boolean()) ->
    {{reply, term()} | {error, {term(), term()}}, term(), gen_server:request_id_collection()}
    | no_request
    | timeout.
receive_response(Collection, Timeout, Delete) ->
    case running() of
        true -> await_response(Collection, Timeout, Delete, abandon);
        false -> gen_server:receive_response(Collection, Timeout, Delete)
    end.

-if(?DOCATTRS).
-doc """
`gen_server:check_response/2` and `gen_statem:check_response/2`: whether the
message `Msg` is the response to the request `ReqId`. See `send_request/2`.
""".
-endif.
-spec check_response(term(), reference()) ->
    {reply, term()} | {error, {term(), term()}} | no_reply.
check_response(Msg, ReqId) ->
    case running() of
        true ->
            case response_msg(Msg, ReqId, single) of
                {ReqId, Response} -> Response;
                no_reply -> no_reply
            end;
        false ->
            gen_server:check_response(Msg, ReqId)
    end.

-if(?DOCATTRS).
-doc """
`gen_server:check_response/3` and `gen_statem:check_response/3`, for a
collection of request ids. See `send_request/2`.
""".
-endif.
-spec check_response(term(), gen_server:request_id_collection(), boolean()) ->
    {{reply, term()} | {error, {term(), term()}}, term(), gen_server:request_id_collection()}
    | no_request
    | no_reply.
check_response(Msg, Collection, Delete) ->
    case running() of
        true ->
            case map_size(Collection) of
                0 ->
                    no_request;
                _ ->
                    case response_msg(Msg, Collection, collection) of
                        {ReqId, Response} -> labelled(Response, ReqId, Collection, Delete);
                        no_reply -> no_reply
                    end
            end;
        false ->
            gen_server:check_response(Msg, Collection, Delete)
    end.

%% A request id collection is a map from the request id to the label. The type
%% is opaque in `gen_server'. This module reads the map, as it copies the tag
%% shape of `gen', because a response must be matched against the collection in
%% the guard of a `receive'.
labelled(Response, ReqId, Collection, Delete) ->
    Label = maps:get(ReqId, Collection),
    case Delete of
        true -> {Response, Label, maps:remove(ReqId, Collection)};
        false -> {Response, Label, Collection}
    end.

%% Whether `Msg' is the response to the request `Ids', or to one request of the
%% collection `Ids'. The answer has the request id, and the request is settled.
response_msg({[alias | Ref], Reply}, Ids, Kind) when is_reference(Ref) ->
    case is_request(Ref, Ids, Kind) of
        true ->
            %% The monitor has done its work. A `DOWN' message that is already
            %% in the mailbox is removed.
            _ = demonitor(Ref, [flush]),
            {Ref, {reply, Reply}};
        false ->
            no_reply
    end;
response_msg({'DOWN', Ref, _Type, Object, Reason}, Ids, Kind) when is_reference(Ref) ->
    case is_request(Ref, Ids, Kind) of
        true ->
            ok = abandon(Ref),
            {Ref, {error, {Reason, Object}}};
        false ->
            no_reply
    end;
response_msg(_Msg, _Ids, _Kind) ->
    no_reply.

is_request(Ref, ReqId, single) -> Ref =:= ReqId;
is_request(Ref, Collection, collection) -> is_map_key(Ref, Collection).

%% The caller no longer waits for the reply to this request. `reply/2' discards
%% a reply that the callee sends from now on.
abandon(Ref) ->
    _ = demonitor(Ref, [flush]),
    true = ets:insert(?CALLS, {[alias | Ref], abandoned}),
    ok.

%% A time-out of `gen_server:wait_response/2': a number of milliseconds,
%% `infinity', or an absolute time of `erlang:monotonic_time(millisecond)'.
-type response_timeout() :: timeout() | {abs, integer()}.

relative_timeout({abs, At}) ->
    max(0, At - eta_time:monotonic_time(millisecond));
relative_timeout(Timeout) ->
    Timeout.

%% The wait of `wait/3', for one request.
await_response(ReqId, Timeout0, OnTimeout) when is_reference(ReqId) ->
    {TRef, Guard, Real} = arm(relative_timeout(Timeout0)),
    receive
        {[alias | Ref], _} = Msg when Ref =:= ReqId ->
            ok = eta_time:disarm_after(TRef, Guard),
            {ReqId, Response} = response_msg(Msg, ReqId, single),
            Response;
        {'DOWN', Ref, _, _, _} = Msg when Ref =:= ReqId ->
            ok = eta_time:disarm_after(TRef, Guard),
            {ReqId, Response} = response_msg(Msg, ReqId, single),
            Response;
        {'$eta_after', G} when G =:= Guard ->
            timed_out([ReqId], OnTimeout)
    after Real ->
        timed_out([ReqId], OnTimeout)
    end.

%% The same wait, for any request of a collection.
await_response(Collection, _Timeout, _Delete, _OnTimeout) when map_size(Collection) =:= 0 ->
    no_request;
await_response(Collection, Timeout0, Delete, OnTimeout) ->
    {TRef, Guard, Real} = arm(relative_timeout(Timeout0)),
    receive
        {[alias | Ref], _} = Msg when is_map_key(Ref, Collection) ->
            ok = eta_time:disarm_after(TRef, Guard),
            {ReqId, Response} = response_msg(Msg, Collection, collection),
            labelled(Response, ReqId, Collection, Delete);
        {'DOWN', Ref, _, _, _} = Msg when is_map_key(Ref, Collection) ->
            ok = eta_time:disarm_after(TRef, Guard),
            {ReqId, Response} = response_msg(Msg, Collection, collection),
            labelled(Response, ReqId, Collection, Delete);
        {'$eta_after', G} when G =:= Guard ->
            timed_out(maps:keys(Collection), OnTimeout)
    after Real ->
        timed_out(maps:keys(Collection), OnTimeout)
    end.

%% The deadline of a wait, on the virtual clock when the clock will reach it.
%% See `wait/3'.
arm(Timeout) ->
    Guard = make_ref(),
    case virtual_timeout() of
        true -> {eta_time:arm_after(Timeout, Guard), Guard, infinity};
        false -> {undefined, Guard, Timeout}
    end.

timed_out(_ReqIds, keep) ->
    timeout;
timed_out(ReqIds, abandon) ->
    lists:foreach(fun abandon/1, ReqIds),
    timeout.

-if(?DOCATTRS).
-doc """
Routes the replies in the return value of a `gen_statem` state callback through
the network.

`eta_transform` wraps the returns of a state callback in this function. A
`gen_statem` names the caller in the return value, in a `{reply, From, Msg}`
action, so the function needs only the return value. For a `gen_server`, the
transform generates a helper in each module, because `From` is an argument of
`handle_call/3`.

The function sends each `{reply, From, Msg}` action with `reply/2` and removes
it from the action list, so that `gen_statem` does not send it again:

```erlang
{next_state, S, D, [{reply, From, R}, Other]}  %% -> eta_net:reply(From, R),
                                               %%    {next_state, S, D, [Other]}
{stop_and_reply, Reason, [{reply, From, R}]}   %% -> eta_net:reply(From, R),
                                               %%    {stop_and_reply, Reason, []}
```

The recognised return shapes are:

- `{next_state, State, Data, Actions}`
- `{keep_state, Data, Actions}`
- `{keep_state_and_data, Actions}`
- `{repeat_state, Data, Actions}`
- `{repeat_state_and_data, Actions}`
- `{stop_and_reply, Reason, Replies}`
- `{stop_and_reply, Reason, Replies, Data}`

`Actions` is a list or one action. One `{reply, From, Msg}` action becomes `[]`.

Any other value is returned unchanged. That includes a return with no actions
and an unknown return shape. The function is idempotent: a return value that has
passed through it once is unchanged by a second pass.
""".
-endif.
-spec statem_return(term()) -> term().
statem_return({next_state, S, D, A}) -> {next_state, S, D, statem_actions(A)};
statem_return({keep_state, D, A}) -> {keep_state, D, statem_actions(A)};
statem_return({keep_state_and_data, A}) -> {keep_state_and_data, statem_actions(A)};
statem_return({repeat_state, D, A}) -> {repeat_state, D, statem_actions(A)};
statem_return({repeat_state_and_data, A}) -> {repeat_state_and_data, statem_actions(A)};
statem_return({stop_and_reply, R, A}) -> {stop_and_reply, R, statem_actions(A)};
statem_return({stop_and_reply, R, A, D}) -> {stop_and_reply, R, statem_actions(A), D};
statem_return(Ret) -> Ret.

statem_actions([{reply, From, Msg} | T]) ->
    ok = reply(From, Msg),
    statem_actions(T);
statem_actions([H | T]) ->
    [H | statem_actions(T)];
statem_actions([]) ->
    [];
statem_actions({reply, From, Msg}) ->
    ok = reply(From, Msg),
    [];
statem_actions(Other) ->
    Other.

-if(?DOCATTRS).
-doc """
The target of the messaging functions that this module does not implement.

`eta_transform` points these functions here: broadcasts, multi-node calls, the
synchronous events of `gen_fsm`, and the `gen_event` client API. The
list is `?NET_UNSUPPORTED` in `eta_transform`.

- With no network running, the function calls the original function with `Args`.
  A module that contains such a call therefore builds and behaves normally.
- While a network is running, the function raises
  `{eta_net, {unsupported, {M, F, A}, Text}}`.

The function raises because a run states a fault model. If a channel were
passed through without faults, the run would pass while it faulted less traffic
than the fault model states.
""".
-endif.
-spec unsupported({module(), atom(), arity()}, [term()]) -> term().
unsupported({M, F, _A} = MFA, Args) ->
    case running() of
        false ->
            apply(M, F, Args);
        true ->
            error(
                {eta_net,
                    {unsupported, MFA, <<
                        "eta_net cannot put this function's traffic on the network yet, "
                        "so a run that used it would be faulting less than it claims. "
                        "Use call/2,3, cast/2 or reply/2 on gen_server or gen_statem, "
                        "which are routed, "
                        "or run without a network"
                    >>}}
            )
    end.

%% A channel is a pair of pids, and every way of addressing a local process
%% normalizes to one. Required for correctness rather than convenience: a system
%% that sometimes sends to `Peer` and sometimes to `{peer, node()}` would
%% otherwise open two channels to one process, each with its own ordering clamp.
%%
%% A name resolves **at send time**, unlike `erlang:send/2` which resolves on
%% delivery. Only observable if the name is re-registered while a message to it is
%% in flight.
%%
%% `undefined` means "not a local process this module can identify", and the
%% caller falls back to sending directly.
%% `{Name, Node}` for a *simulated* node resolves through the registry
%% `register_name/3` fills, which is what lets a system address its peers the way
%% distributed Erlang does. The real node is checked first so a harness that
%% never registers anything behaves exactly as before.
%%
%% A name with no simulated registration still resolves if a real process holds
%% it **and is located on that node**. A system whose instances already have
%% distinct local names then needs no `register_name/3` at all, and a process
%% that restarts under the same name is found again without the harness noticing.
%%
%% A name is looked up in the sender's namespace first (see `eta_ns`), and
%% `{Name, Node}` for another simulated node in that node's.
normalize(Pid) when is_pid(Pid) -> Pid;
normalize(Name) when is_atom(Name) -> eta_ns:whereis(Name);
normalize({Name, Node}) when is_atom(Name), Node =:= erlang:node() -> eta_ns:whereis(Name);
normalize({Name, Node}) when is_atom(Name) ->
    case whereis_name(Node, Name) of
        undefined ->
            case running() andalso local_node() of
                Node -> eta_ns:whereis(Name);
                _ -> located_name(Name, Node)
            end;
        Pid ->
            Pid
    end;
normalize(_) ->
    undefined.

%% A process holding `Name` in `Node`'s namespace, or holding the bare name while
%% located on `Node`.
located_name(Name, Node) ->
    case running() andalso erlang:whereis(eta_ns:name(Node, Name)) of
        Pid when is_pid(Pid) -> Pid;
        _ -> located_bare(Name, Node)
    end.

located_bare(Name, Node) ->
    case running() andalso erlang:whereis(Name) of
        Pid when is_pid(Pid) ->
            case placement(Pid) of
                {Node, _} -> Pid;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%% ---------------------------------------------------------------------------
%% Policy
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Sets the random fault policy. A key that is omitted keeps its current value. An
unknown key is ignored.

| Key | Default | Meaning |
|---|---|---|
| `drop_p` | `0.0` | The probability that a message in scope is dropped. |
| `delay_p` | `0.0` | The probability that a message in scope is delayed. |
| `max_delay` | `20` | The upper bound of a delay, in virtual milliseconds. A delay is at least 1 ms. |
| `scope` | `all` | The messages to which `drop_p` and `delay_p` apply. |
| `busy_p` | `0.0` | The probability that a `send_nosuspend` starts a busy period on its link. See `send_nosuspend/3`. |
| `busy_ms` | `1000` | The upper bound of a busy period, in virtual milliseconds. |

The values of `scope` are:

- `all`: every message.
- `{tags, [Tag]}`: the messages that have one of these tags.
- `fun(From, Dest, Tag) -> boolean()`: the messages for which the function
  returns `true`.

The tag of a message is:

| Message | Tag |
|---|---|
| A tuple | The first element. |
| An atom | The atom. |
| Any other term | `unknown`. |
| A `cast/2`, `send_event/2`, `send_all_state_event/2` or `call/3` request | The tag of the payload. A cast of `{prepare, TxId}` has the tag `prepare`, not `'$gen_cast'`. |
| A reply | `'$gen_reply'`. |

The policy applies to a message only when the message crosses a faultable link.
See `place/2`.

Use `scope` to state which recovery paths a run may exercise. Some channels
recover from loss only after a node event, and no node event is delivered until
the heal. A property that is checked during a fault does not hold for such a
channel. A run that checks a property during a fault must restrict loss to a
channel that repairs itself. An example is a replication stream in which a
follower detects a version gap and joins again.

A message outside the scope draws nothing from the fault generator. A narrower
scope therefore does not change the fault decisions for the messages that remain
in scope.

Raises `{eta_net, {no_network, set_policy, Text}}` when no network is running.
""".
-endif.
-spec set_policy(policy()) -> ok.
set_policy(Policy) ->
    ok = require_running(set_policy),
    Merged = maps:merge(policy(), maps:with(maps:keys(?DEFAULT_POLICY), Policy)),
    true = ets:insert(?STATE, {policy, Merged}),
    ok.

-if(?DOCATTRS).
-doc "Returns the current policy.".
-endif.
-spec policy() -> policy().
policy() ->
    ets:lookup_element(?STATE, policy, 2).

-if(?DOCATTRS).
-doc """
Places processes on a simulated node. A placed process is located and faultable.

```erlang
eta_net:place(node_a, [MemberA]),
eta_net:place(node_b, [MemberB]).
```

`Node` is any term. `Pids` is a list of pids and registered names. An entry that
does not resolve to a process is ignored.

A placed process has these properties:

- It receives the link events of its node.
- It dies when its node is killed with `kill_node/2`.
- Its messages can be dropped, delayed or cut. A send is faulted only when both
  ends are placed and the ends are on different nodes.

`attach/2` gives the first two properties without the third. See "Topology" in
the module documentation.

A process that is neither placed nor attached is on no node:

- Its messages are never faulted, in either direction.
- It receives no link events.

A network therefore does not affect a process that it has no record of, such as
a process left by an earlier test in the same VM. Do not leave a process
unplaced to keep its messages from being faulted when the process belongs to a
node. Use `attach/2`, so that the process receives the link events of the node.

With no topology declared, every send is faultable.

A child process inherits the node and the faultable property of its parent when
`eta_sched` adopts the child. A worker that is spawned during a run is therefore
on the node of its parent, and a child of an attached process is not faultable.

Placing a process that is already placed moves the process. The process keeps
its position in the order of link events. See `partition/3`.

Placing a process on a killed node marks the node as up again. See
`kill_node/2`.

Raises `{eta_net, {no_network, place, Text}}` when no network is running.
""".
-endif.
-spec place(term(), [dest()]) -> ok.
place(Node, Pids) ->
    do_place(place, Node, Pids, true).

-if(?DOCATTRS).
-doc """
Attaches processes to a simulated node. An attached process is located and not
faultable.

```erlang
eta_net:place(node_a, [MemberA]),          %% sends to peers over the network
eta_net:attach(node_a, [ElectorA, ConnA]). %% located, not faultable
```

An attached process receives the link events of its node and dies when the node
is killed. Its messages are never faulted.

Use `attach/2` for a process whose sends do not stand for network messages.
Examples are an elector that coordinates through a durable store, and a
connector that only watches whether nodes are alive. A dropped send of such a
process is a failure that the real system cannot produce, and the divergence
that follows has the same symptoms as a replication defect. Both processes must
still receive the link events of their node and must die with the node, so they
cannot be left unplaced.

The faultable property belongs to a process, not to a channel. A send is faulted
only when both ends are faultable. The messages of an attached process are
therefore not faulted in either direction.

In every other respect `attach/2` behaves as `place/2` does: the node names, the
inheritance by child processes, and the treatment by `partition/3` and
`kill_node/2` are the same.

Raises `{eta_net, {no_network, attach, Text}}` when no network is running.
""".
-endif.
-spec attach(term(), [dest()]) -> ok.
attach(Node, Pids) ->
    do_place(attach, Node, Pids, false).

do_place(What, Node, Pids, Faultable) ->
    ok = require_running(What),
    true = ets:insert(?PLACE, {{node, Node}, true}),
    true = ets:delete(?PLACE, {down, Node}),
    lists:foreach(
        fun(D) ->
            case normalize(D) of
                P when is_pid(P) ->
                    true = ets:insert(?PLACE, {{pid, P}, Node, Faultable, seq_of(P)}),
                    true = ets:insert(?PLACE, {{home, P}, Node});
                _ ->
                    ok
            end
        end,
        Pids
    ),
    ok.

-if(?DOCATTRS).
-doc """
Registers `Name` on the simulated node `Node`, so that `{Name, Node}` resolves
as `{Name, node()}` does in a real cluster.

```erlang
eta_net:place(node_a, [ServerA]),
eta_net:register_name(node_a, my_server, ServerA),
eta_net:cast({my_server, node_a}, hello).   %% reaches ServerA
```

A distributed Erlang program addresses a process as `{RegisteredName, Node}`.
One VM has one registry, and a second
`gen_server:start_link({local, Name}, ...)` fails with `already_started`. With
no registration, `{Name, Node}` for a simulated node resolves to no process and
the message is discarded. Nothing is raised and nothing is counted.

Rules:

- The name belongs to the node. The same name on two nodes refers to two
  processes.
- Registration does not place the process. A process that is registered and not
  placed is on no node and is never faulted. Register the pid that was placed.
- A pid can hold several names.
- Registering a name again moves the name.
- A name is not removed when its process dies. The name then resolves to a dead
  pid, as `{Name, Node}` does for a real node that has restarted. Use
  `unregister_name/2` to model deregistration.

`Dest` is a pid or a registered name. Raises
`{eta_net, {register_name, Node, Name, no_such_process}}` when `Dest` resolves
to no process. Raises `{eta_net, {no_network, register_name, Text}}` when no
network is running.

## Alias for a local name

`Dest` can also be `{local, LocalName}`. `Name` on `Node` then resolves, at each
send, to one of these processes:

- the process that holds `LocalName` in the namespace of `Node`;
- otherwise the process that holds the real local name `LocalName`, if that
  process is located on `Node`.

```erlang
%% Each node runs one instance under a distinct local name. A peer addresses
%% the instance by the name that the peer uses for its own instance.
eta_net:register_name(node_b, myapp_a_server, {local, myapp_b_server}).
```

Use an alias when a system runs one instance for each simulated node in one VM.
The instances need distinct local names, and each instance addresses a peer by
the name of its own instance. The alias is resolved at each send, so it resolves
to the new process after a supervisor restarts the server under the same local
name. No new registration is needed. The alias resolves to no process while the
node is down.
""".
-endif.
-spec register_name(term(), atom(), dest() | {local, atom()}) -> ok.
register_name(Node, Name, {local, Local}) when is_atom(Name), is_atom(Local) ->
    ok = require_running(register_name),
    true = ets:insert(?PLACE, {{name, Node, Name}, {local, Local}}),
    ok;
register_name(Node, Name, Dest) when is_atom(Name) ->
    ok = require_running(register_name),
    case normalize(Dest) of
        Pid when is_pid(Pid) ->
            true = ets:insert(?PLACE, {{name, Node, Name}, Pid}),
            ok;
        undefined ->
            error({eta_net, {register_name, Node, Name, no_such_process}})
    end.

-if(?DOCATTRS).
-doc "Removes the registration of `Name` on the simulated node `Node`. See `register_name/3`.".
-endif.
-spec unregister_name(term(), atom()) -> ok.
unregister_name(Node, Name) when is_atom(Name) ->
    true = ets:delete(?PLACE, {name, Node, Name}),
    ok.

-if(?DOCATTRS).
-doc """
Returns the pid registered as `Name` on the simulated node `Node`, or
`undefined`.

This function is `erlang:whereis/1` for the names of `register_name/3`. An alias
is resolved at the time of the call. The function returns `undefined` when no
network is running.
""".
-endif.
-spec whereis_name(term(), atom()) -> pid() | undefined.
whereis_name(Node, Name) when is_atom(Name) ->
    case running() andalso ets:lookup(?PLACE, {name, Node, Name}) of
        [{_, {local, Local}}] -> located_name(Local, Node);
        [{_, Pid}] -> Pid;
        _ -> undefined
    end.

%% A process keeps the sequence number it was first given, so re-placing one — a
%% harness restating its topology after a restart, say — does not reshuffle the
%% order link events are delivered in.
seq_of(Pid) ->
    case ets:lookup(?PLACE, {pid, Pid}) of
        [{_, _Node, _F, Seq}] -> Seq;
        [] -> next_seq()
    end.

next_seq() ->
    ets:update_counter(?STATE, seq, 1).

-if(?DOCATTRS).
-doc """
Returns the simulated node of a process, or `undefined`. See `place/2`.

For a process that is neither placed nor attached, the function returns the node
of the process that spawned it, if that process has a node. The function follows
the chain of spawners up to the first located process.

`eta_sched` places a child of a scheduled process with `inherit/2` when it
adopts the child. The fallback covers a child that exists before a scheduler can
adopt it. An example is a worker that a server spawns from `init/1` during the
`init/2` of the harness. The function does not place such a child:

- The child remains not faultable.
- `kill_node/2` does not kill the child.

A harness should therefore return from `init/2` only after such children have
finished.

The spawner of a process is recorded once. The node of the spawner is read at
each call, so the result follows a spawner that is placed or moved later.
`eta_sched` records the spawner of every process that it owns before the run
needs it, so that this function does not call `erlang:process_info/2` on a
suspended process. See `introduce/1`.
""".
-endif.
-spec node_of(dest()) -> term() | undefined.
node_of(Dest) ->
    case normalize(Dest) of
        Pid when is_pid(Pid) -> node_of_pid(Pid);
        _ -> undefined
    end.

node_of_pid(Pid) ->
    case placement(Pid) of
        {Node, _Faultable} ->
            Node;
        undefined ->
            case spawner(Pid) of
                Parent when is_pid(Parent) -> node_of_pid(Parent);
                undefined -> undefined
            end
    end.

%% Who spawned `Pid`, or `undefined`. Remembered, because it cannot change and
%% because finding out is not free.
%%
%% `erlang:process_info/2` is a signal against a live target that has signals
%% of its own waiting: the caller asks, and parks in
%% `erts_internal:await_result/1` until the target answers. Against a process
%% `eta_sched` has suspended, asked by the process it is stepping, that is a
%% step that ends where the wall clock says. A parked process is `waiting`,
%% `waiting` is what a finished step looks like, and the scheduler moves on
%% with the asker in the middle of a callback. Nothing counts it: it is not a
%% step timeout, the process did block. And the asker is always a process with
%% signals outstanding at its target, because it is `node_cut/2` asking on
%% behalf of a send, and the send before it was to the same place.
%%
%% Measured in isolation, outside any of this: a process that sends to a
%% suspended one and then asks for its `parent` is seen parked in about one
%% trial in two hundred by a sampler that mostly misses it.
%%
%% So the question is put by somebody who can wait. `eta_sched` introduces
%% every process it is handed (`introduce/1`) from its own process, between
%% steps, and reports every spawn it sees (`inherit/2`), which is the same
%% fact without a question at all. What is left for the lookup below to ask is
%% a process nobody introduced, and then only once.
spawner(Pid) ->
    case ets:lookup(?SPAWNERS, Pid) of
        [{_, Spawner}] ->
            Spawner;
        [] ->
            Spawner =
                case erlang:process_info(Pid, parent) of
                    {parent, Parent} when is_pid(Parent) -> Parent;
                    _ -> undefined
                end,
            _ = ets:insert_new(?SPAWNERS, {Pid, Spawner}),
            Spawner
    end.

-if(?DOCATTRS).
-doc """
Records the spawner of `Pid` and of each ancestor of `Pid`, up to the first
located ancestor.

`eta_sched` calls this function for every process that it is given. A harness
does not call it.

`node_of/1` needs the spawner of a process. Reading the spawner calls
`erlang:process_info/2`, which waits for the target process when the target has
signals pending. The process that the scheduler is stepping must not wait for a
suspended process. This function therefore reads the spawner from the scheduler
process, between steps.

The function does nothing when no network is running.
""".
-endif.
-spec introduce(pid()) -> ok.
introduce(Pid) when is_pid(Pid) ->
    case running() andalso placement(Pid) =:= undefined andalso spawner(Pid) of
        Spawner when is_pid(Spawner) -> introduce(Spawner);
        _ -> ok
    end.

-if(?DOCATTRS).
-doc """
Returns `true` when the network may fault the messages of this process.

| Process | Result |
|---|---|
| Placed with `place/2`, or the child of a placed process | `true` |
| Attached with `attach/2`, or the child of an attached process | `false` |
| Neither placed nor attached | `false` |
| Any process, with no topology declared | `true` |

A topology is declared by the first call to `place/2`, `attach/2` or
`register_name/3`.
""".
-endif.
-spec faultable(dest()) -> boolean().
faultable(Dest) ->
    case ets:info(?PLACE, size) of
        0 ->
            true;
        _ ->
            case placement(normalize(Dest)) of
                {_Node, Faultable} -> Faultable;
                undefined -> false
            end
    end.

%% `{Node, Faultable}` or `undefined`. The one place the table's row shape is
%% read, so the rest of the module does not care what it is.
placement(Pid) ->
    case ets:lookup(?PLACE, {pid, Pid}) of
        [{_, Node, Faultable, _Seq}] -> {Node, Faultable};
        [] -> undefined
    end.

-if(?DOCATTRS).
-doc """
Places `Child` on the node of `Parent`, with the faultable property of `Parent`.

`eta_sched` calls this function when it adopts a process. A harness does not
call it. See `place/2`.

- The function records `Parent` as the spawner of `Child`, also when `Parent`
  has no node.
- A child that is already placed or attached keeps its placement.
- The function does nothing when no network is running.
""".
-endif.
-spec inherit(pid(), pid()) -> ok.
inherit(Parent, Child) ->
    %% Who spawned it is worth keeping whether or not the parent is anywhere:
    %% the parent may be placed later, and `node_of/1` would otherwise have to
    %% ask the child. See `spawner/1`.
    _ = running() andalso ets:insert_new(?SPAWNERS, {Child, Parent}),
    %% A child placed before the scheduler adopted it keeps that placement: it
    %% was put there on purpose, as `eta_rpc` does with its workers.
    case running() andalso placement(Child) =:= undefined andalso placement(Parent) of
        {Node, Faultable} ->
            true = ets:insert(?PLACE, {{pid, Child}, Node, Faultable, seq_of(Child)}),
            true = ets:insert(?PLACE, {{home, Child}, Node}),
            ok;
        _ ->
            ok
    end.

%% Whether a send crosses a simulated link, and so is something the policy may
%% fault. Both ends must be located, on different nodes, and faultable — an
%% attached process is on the node but not on the wire, so nothing it sends or
%% receives is ever a candidate. No topology at all means every link is faultable.
crosses_link(From, Dest) ->
    case ets:info(?PLACE, size) of
        0 ->
            true;
        _ ->
            case {placement(normalize(From)), placement(normalize(Dest))} of
                {{A, true}, {B, true}} when A =/= B -> true;
                {_, _} -> false
            end
    end.

%% A reference to cut or partition: a node if it names one, otherwise a process.
%% Only an atom is ambiguous — a node named the same as a registered process — and
%% nodes win; pass a pid to disambiguate.
%% Any term can name a node, because `place/2` takes any term: a system whose node
%% names are binaries partitions them the same way as one using atoms.
resolve(Ref) when is_pid(Ref) ->
    {pid, Ref};
resolve(Ref) ->
    case ets:member(?PLACE, {node, Ref}) of
        true -> {node, Ref};
        false -> {pid, normalize(Ref)}
    end.

%% Every process on a node, for delivering a link signal, **in placement order**.
%%
%% `ets:match/2` returns rows in whatever order the table hands them over, which
%% is neither specified nor stable, so the raw list is unusable for anything the
%% schedule depends on: a fan-out of link events delivered in table order would
%% put a different sequence of messages in different mailboxes from run to run,
%% and a seed would stop reproducing itself. Sorting by the placement sequence
%% orders it by something the run decided instead — the order the harness placed
%% them in, and for children the order they were spawned in.
on_node(Node) ->
    in_seq_order(ets:match(?PLACE, {{pid, '$1'}, Node, '_', '$2'})).

%% Every located process, in placement order. See `on_node/1`.
located() ->
    in_seq_order(ets:match(?PLACE, {{pid, '$1'}, '_', '_', '$2'})).

in_seq_order(Matched) ->
    [P || {_Seq, P} <- lists:sort([{Seq, P} || [P, Seq] <- Matched])].

merge_policy(Policy) ->
    maps:merge(?DEFAULT_POLICY, maps:with(maps:keys(?DEFAULT_POLICY), Policy)).

%% Configuring or inspecting a network needs one to exist. `send/2` and friends
%% are deliberately *not* guarded: their contract is to be inert without one.
require_running(What) ->
    case running() of
        true ->
            ok;
        false ->
            error(
                {eta_net,
                    {no_network, What, <<
                        "no network is running; pass `net => true` (or "
                        "`net => #{policy => ...}`) to eta_run:run/2, or call "
                        "eta_net:start/1 first"
                    >>}}
            )
    end.

%% ---------------------------------------------------------------------------
%% Membership
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
`erlang:node/0` for a process on a simulated node. Returns the node on which the
caller is placed or attached.

For any other process the function returns the real node. A process that the
network has no record of therefore gets the same result as with no network.
Inside `with_node/2`, the function returns the node that `with_node/2` names.
""".
-endif.
-spec node() -> term().
node() ->
    case local_node() of
        undefined -> erlang:node();
        Node -> Node
    end.

-if(?DOCATTRS).
-doc """
`erlang:node/1`. Returns the simulated node on which a pid was placed or
attached, or the real node.

The result remains the same after the process dies, as for a real pid. Systems
compare `node(Pid)` with the name of a peer after the process has died.

For a port or a reference, the function calls `erlang:node/1`.
""".
-endif.
-spec node(pid() | port() | reference()) -> term().
node(Pid) when is_pid(Pid) ->
    case running() andalso ets:lookup(?PLACE, {home, Pid}) of
        [{_, Node}] -> Node;
        _ -> erlang:node(Pid)
    end;
node(Other) ->
    erlang:node(Other).

-if(?DOCATTRS).
-doc """
`erlang:nodes/0`. Returns the sorted list of nodes to which the node of the
caller is connected.

See "Node identity" in the module documentation for the rules of connection. For
a caller on no simulated node, the function calls `erlang:nodes/0`.
""".
-endif.
-spec nodes() -> [term()].
nodes() ->
    case local_node() of
        undefined -> erlang:nodes();
        Node -> connected_to(Node)
    end.

-if(?DOCATTRS).
-doc """
`erlang:nodes/1` for a process on a simulated node.

| Argument | Result |
|---|---|
| `visible` | The result of `nodes/0`. |
| `connected` | The result of `nodes/0`. |
| `this` | The node of the caller. |
| `known` | Every simulated node that has been named in `place/2` or `attach/2`, sorted. |
| `hidden` | `[]`. A simulated node is always visible. |

A list of arguments returns the results in the order of the list, without
duplicates. Any other argument raises `badarg`. For a caller on no simulated
node, the function calls `erlang:nodes/1`.
""".
-endif.
-spec nodes(atom() | [atom()]) -> [term()].
nodes(Arg) ->
    case local_node() of
        undefined ->
            erlang:nodes(Arg);
        Node ->
            Kinds =
                case is_list(Arg) of
                    true -> Arg;
                    false -> [Arg]
                end,
            dedupe(lists:append([nodes_of(Node, K) || K <- Kinds]))
    end.

nodes_of(Node, K) when K =:= visible; K =:= connected -> connected_to(Node);
nodes_of(_Node, hidden) -> [];
nodes_of(Node, this) -> [Node];
nodes_of(_Node, known) -> lists:sort([N || [N] <- ets:match(?PLACE, {{node, '$1'}, '_'})]);
nodes_of(_Node, Other) -> error(badarg, [Other]).

dedupe(List) -> dedupe(List, #{}).
dedupe([], _Seen) -> [];
dedupe([H | T], Seen) when is_map_key(H, Seen) -> dedupe(T, Seen);
dedupe([H | T], Seen) -> [H | dedupe(T, Seen#{H => true})].

-if(?DOCATTRS).
-doc "`erlang:is_alive/0`. Returns `true` for a process on a simulated node.".
-endif.
-spec is_alive() -> boolean().
is_alive() ->
    local_node() =/= undefined orelse erlang:is_alive().

-if(?DOCATTRS).
-doc "`net_kernel:monitor_nodes/1`. See `monitor_nodes/2`.".
-endif.
-spec monitor_nodes(boolean()) -> ok | error.
monitor_nodes(Flag) ->
    monitor_nodes(Flag, []).

-if(?DOCATTRS).
-doc """
`net_kernel:monitor_nodes/2` for a process on a simulated node.

`true` adds a subscription and `false` removes one subscription with the same
options. As with `net_kernel`, each subscription delivers its own copy of every
event.

The subscriber receives these messages for the node of the caller:

| Message | Cause |
|---|---|
| `{nodeup, Node}` | `connect_node/1` or a send without `noconnect` connected the two nodes. |
| `{nodedown, Node}` | `partition/3`, `kill_node/2` or `disconnect_node/1` disconnected the two nodes. |

A heal does not reconnect the nodes, as in distribution. A process must connect
them again.

With a non-empty option list, the message is
`{nodeup, Node, Info}` or `{nodedown, Node, Info}`. The options are:

- `{node_type, visible}` or `{node_type, all}` adds `{node_type, visible}` to
  `Info`.
- `{node_type, hidden}` selects no events. A simulated node is never hidden.
- `nodedown_reason` adds `{nodedown_reason, Reason}` to the `Info` of a
  `nodedown` message.

| `Reason` | Cause |
|---|---|
| `net_tick_timeout` | `partition/3` |
| `connection_closed` | `kill_node/2` |
| `disconnect` | `disconnect_node/1` |

The messages are sent directly and are not routed, as the signal of
`partition/3` is. A cut therefore cannot drop them. The subscribers of a node
receive each event in the order in which they first subscribed.

For a caller on no simulated node, the function calls
`net_kernel:monitor_nodes/2`.
""".
-endif.
-spec monitor_nodes(boolean(), list()) -> ok | error.
monitor_nodes(Flag, Opts) when is_boolean(Flag), is_list(Opts) ->
    case local_node() of
        undefined -> net_kernel:monitor_nodes(Flag, Opts);
        Node -> subscribe(Flag, Node, self(), Opts)
    end.

subscribe(true, Node, Pid, Opts) ->
    {Seq, Subs} =
        case ets:lookup(?PLACE, {sub, Pid}) of
            [{_, _Node, S, L}] -> {S, L};
            [] -> {next_seq(), []}
        end,
    true = ets:insert(?PLACE, {{sub, Pid}, Node, Seq, Subs ++ [Opts]}),
    ok;
subscribe(false, _Node, Pid, Opts) ->
    case ets:lookup(?PLACE, {sub, Pid}) of
        [{Key, Node, Seq, Subs}] ->
            case lists:delete(Opts, Subs) of
                [] -> true = ets:delete(?PLACE, Key);
                Left -> true = ets:insert(?PLACE, {Key, Node, Seq, Left})
            end,
            ok;
        [] ->
            ok
    end.

-if(?DOCATTRS).
-doc "`erlang:monitor_node/2`. See `monitor_node/3`.".
-endif.
-spec monitor_node(term(), boolean()) -> true.
monitor_node(Node, Flag) ->
    monitor_node(Node, Flag, []).

-if(?DOCATTRS).
-doc """
`erlang:monitor_node/3` for a process on a simulated node.

With `true`, the caller watches the connection from its node to `Node`:

- The function first connects the two nodes, as distribution does.
- If the nodes cannot be connected, the caller receives `{nodedown, Node}` at
  once.
- When the connection is lost, the caller receives `{nodedown, Node}` once, and
  the watch is removed.

Each call with `true` adds one watch. A call with `false` removes one watch. A
call that names the node of the caller adds no watch and sends no message. The
function returns `true`. The options are ignored for a simulated node.

For a caller on no simulated node, the function calls `erlang:monitor_node/3`.
""".
-endif.
-spec monitor_node(term(), boolean(), list()) -> true.
monitor_node(Node, Flag, Opts) ->
    case local_node() of
        undefined ->
            erlang:monitor_node(Node, Flag, Opts);
        Node ->
            true;
        Here when Flag ->
            case ets:member(?PLACE, {conn, Here, Node}) orelse try_connect(Here, Node) of
                true ->
                    Key = {nmon, self()},
                    Watched =
                        case ets:lookup(?PLACE, Key) of
                            [{_, _Here, W}] -> W;
                            [] -> []
                        end,
                    true = ets:insert(?PLACE, {Key, Here, Watched ++ [Node]});
                false ->
                    _ = erlang:send(self(), {nodedown, Node}),
                    true
            end;
        _Here ->
            Key = {nmon, self()},
            case ets:lookup(?PLACE, Key) of
                [{_, H, W}] ->
                    case lists:delete(Node, W) of
                        [] -> true = ets:delete(?PLACE, Key);
                        Left -> true = ets:insert(?PLACE, {Key, H, Left})
                    end;
                [] ->
                    true
            end
    end.

-if(?DOCATTRS).
-doc """
`net_kernel:connect_node/1` and `Node.connect/1` in Elixir.

Returns `true` when the node of the caller is connected to `Node` after the
call:

- The nodes were already connected, or `Node` is the node of the caller.
- `Node` is up and no cut exists between the two nodes. The function connects
  the nodes, and the `monitor_nodes/1` subscribers of both nodes receive
  `nodeup`.

Returns `false` in every other case: `Node` has never been named in `place/2` or
`attach/2`, `Node` was killed, or a cut exists between the two nodes.

For a caller on no simulated node, the function calls
`net_kernel:connect_node/1`.
""".
-endif.
-spec connect_node(term()) -> boolean() | ignored.
connect_node(Node) ->
    case local_node() of
        undefined -> net_kernel:connect_node(Node);
        Node -> true;
        Here -> try_connect(Here, Node)
    end.

-if(?DOCATTRS).
-doc """
`erlang:disconnect_node/1` and `Node.disconnect/1` in Elixir.

The function closes the connection between the node of the caller and `Node`, as
distribution does:

1. It cancels the delayed messages between the two nodes, in both directions.
2. It fires the simulated monitors across the connection with `noconnection`.
3. It sends `nodedown`, with the reason `disconnect`, to the `monitor_nodes/1`
   subscribers of both nodes.

Returns `true`, or `false` when the nodes were not connected or `Node` is the
node of the caller. The function records no cut. The nodes are connected again
when a process calls `connect_node/1` or sends to the other node without
`noconnect`.

For a caller on no simulated node, the function calls
`erlang:disconnect_node/1`.
""".
-endif.
-spec disconnect_node(term()) -> boolean() | ignored.
disconnect_node(Node) ->
    case local_node() of
        undefined -> erlang:disconnect_node(Node);
        Node -> false;
        Here -> drop_connection(Here, Node)
    end.

-if(?DOCATTRS).
-doc "`net_adm:ping/1` and `Node.ping/1` in Elixir. Returns `pong` when `connect_node/1` returns `true`, and `pang` otherwise.".
-endif.
-spec ping(term()) -> pong | pang.
ping(Node) ->
    case local_node() of
        undefined ->
            net_adm:ping(Node);
        _ ->
            case connect_node(Node) of
                true -> pong;
                _ -> pang
            end
    end.

-if(?DOCATTRS).
-doc "`erlang:send_nosuspend/2`. See `send_nosuspend/3`.".
-endif.
-spec send_nosuspend(dest() | term(), term()) -> boolean().
send_nosuspend(Dest, Msg) ->
    send_nosuspend(Dest, Msg, []).

-if(?DOCATTRS).
-doc """
`erlang:send_nosuspend/3`, on a link that can be busy.

Between two simulated nodes, the function returns `false` and sends nothing in
these cases:

- The link is busy.
- The option `noconnect` is given and the nodes are not connected.
- The nodes are not connected and cannot be connected, because of a cut or
  because the destination node is down.

In every other case the message is routed as any send is, so the random policy
and any cut still apply, and the function returns `true`. The function also
returns `true` for a name that no process holds on the other node. Distribution
loses such a message without an error.

## Busy links

A busy link models a distribution port whose buffer is full. The connection
stays up, no `nodedown` is delivered, and the message is lost unless the sender
handles `false`.

- A call that crosses a faultable link starts a busy period on that link with
  probability `busy_p`. The busy period lasts between 1 and `busy_ms` virtual
  milliseconds.
- During a busy period, every `send_nosuspend` on that link in the same
  direction returns `false`. A `send/3` with the `nosuspend` option returns
  `nosuspend`.
- A send without `nosuspend` is not refused, because a real send would suspend
  the sender.
- A busy period draws from the fault generator only while `busy_p` is above 0.
- The `scope` of the policy does not apply. The `scope` selects messages, and a
  busy port refuses every message.
- `stats/0` counts a refused send as `busy`, not as `dropped`.

Between two local processes that are not on two different simulated nodes, the
function routes the message and returns `true`. Any other destination is passed
to `erlang:send_nosuspend/3`.
""".
-endif.
-spec send_nosuspend(dest() | term(), term(), list()) -> boolean().
send_nosuspend(Dest, Msg, Opts) ->
    case running() andalso across(Dest) of
        {Here, There} ->
            remote_send(Here, There, Dest, Msg, Opts, nosuspend);
        false ->
            case running() andalso normalize(Dest) of
                To when is_pid(To) ->
                    _ = route(self(), To, Msg),
                    true;
                _ ->
                    erlang:send_nosuspend(Dest, Msg, Opts)
            end
    end.

-if(?DOCATTRS).
-doc """
Runs `Fun` with the calling process treated as a process on `Node`, and returns
the result of `Fun`.

The setting affects only the node identity functions: `node/0`, `nodes/0,1`,
`is_alive/0`, `connect_node/1`, `disconnect_node/1`, `monitor_nodes/1,2`,
`monitor_node/2,3`, `ping/1` and `local_node/0`. Placement and routing are
unchanged.

Use this function in a harness that reads the state of one node through the
public API of the system, when that API calls `node()` to decide what is local.
""".
-endif.
-spec with_node(term(), fun(() -> T)) -> T.
with_node(Node, Fun) when is_function(Fun, 0) ->
    Old = put(?AS_NODE, Node),
    try
        Fun()
    after
        case Old of
            undefined -> erase(?AS_NODE);
            _ -> put(?AS_NODE, Old)
        end
    end.

-if(?DOCATTRS).
-doc """
Returns the simulated node of the caller, or `undefined`.

The simulated node of the caller is the node that `with_node/2` names, or
otherwise the node on which the caller is placed or attached. The function
returns `undefined` when the caller is on no simulated node or no network is
running. `node/0` returns the real node in that case.
""".
-endif.
-spec local_node() -> term() | undefined.
local_node() ->
    case running() of
        false ->
            undefined;
        true ->
            case get(?AS_NODE) of
                undefined ->
                    case placement(self()) of
                        {Node, _} -> Node;
                        undefined -> undefined
                    end;
                Node ->
                    Node
            end
    end.

-if(?DOCATTRS).
-doc "Returns `true` when `Node` is a simulated node: a node that has been named in `place/2` or `attach/2`.".
-endif.
-spec is_node(term()) -> boolean().
is_node(Node) ->
    running() andalso ets:member(?PLACE, {node, Node}).

%% `{Here, There}` when a send from the caller to `Dest` goes between two
%% different simulated nodes, otherwise `false`.
across(Dest) ->
    case {local_node(), dest_node(Dest)} of
        {undefined, _} -> false;
        {_, undefined} -> false;
        {Same, Same} -> false;
        {Here, There} -> {Here, There}
    end.

dest_node(Pid) when is_pid(Pid) ->
    case ets:lookup(?PLACE, {home, Pid}) of
        [{_, Node}] -> Node;
        [] -> undefined
    end;
dest_node({Name, Node}) when is_atom(Name) ->
    case ets:member(?PLACE, {node, Node}) of
        true -> Node;
        false -> undefined
    end;
dest_node(Name) when is_atom(Name) ->
    case eta_ns:whereis(Name) of
        Pid when is_pid(Pid) -> dest_node(Pid);
        _ -> undefined
    end;
dest_node(_) ->
    undefined.

%% A send between two simulated nodes, as `erlang:send/3` (`send`) or
%% `erlang:send_nosuspend/3` (`nosuspend`) does it.
remote_send(Here, There, Dest, Msg, Opts, Mode) ->
    Connected =
        ets:member(?PLACE, {conn, Here, There}) orelse
            (not lists:member(noconnect, Opts) andalso try_connect(Here, There)),
    case Connected of
        false when Mode =:= nosuspend ->
            false;
        false ->
            case lists:member(noconnect, Opts) of
                true -> noconnect;
                false -> ok
            end;
        true ->
            case normalize(Dest) of
                To when is_pid(To) ->
                    Busy =
                        (Mode =:= nosuspend orelse lists:member(nosuspend, Opts)) andalso
                            busy(self(), To, Here, There, Msg),
                    case Busy of
                        true when Mode =:= nosuspend ->
                            false;
                        true ->
                            nosuspend;
                        false ->
                            _ = route(self(), To, Msg),
                            accepted(Mode)
                    end;
                _ ->
                    accepted(Mode)
            end
    end.

accepted(nosuspend) -> true;
accepted(send) -> ok.

%% Whether the `Here -> There` link refuses this send. A spell in progress refuses
%% everything; starting one is a draw from the fault schedule, made only for a
%% send the schedule ordered and the policy may fault.
busy(From, To, Here, There, Msg) ->
    Key = {busy, Here, There},
    Now = now_ms(),
    Busy =
        case ets:lookup(?CHAN, Key) of
            [{_, Until}] when Until > Now ->
                true;
            _ ->
                Policy = policy(),
                BusyP = maps:get(busy_p, Policy),
                BusyP > 0.0 andalso classify(From, To) =:= scheduled andalso
                    crosses_link(From, To) andalso
                    case draw() < BusyP of
                        true ->
                            Ms = max(1, trunc(draw() * maps:get(busy_ms, Policy))),
                            true = ets:insert(?CHAN, {Key, Now + Ms}),
                            true;
                        false ->
                            false
                    end
        end,
    case Busy of
        true ->
            bump(busy),
            _ = eta_log:log({net, busy, To, tag(Msg)}),
            true;
        false ->
            false
    end.

%% A plain send between two simulated nodes connects them first, as distribution
%% does, unless they are cut apart — then the send is dropped by `decide/3` as
%% any send across a cut is.
autoconnect(From, Dest) ->
    case {placement(From), placement(Dest)} of
        {{A, _}, {B, _}} when A =/= B ->
            _ = ets:member(?PLACE, {conn, A, B}) orelse try_connect(A, B),
            ok;
        _ ->
            ok
    end.

is_up(Node) ->
    ets:member(?PLACE, {node, Node}) andalso not ets:member(?PLACE, {down, Node}).

link_cut(A, B) ->
    ets:member(?CHAN, {node_cut, A, B}) orelse ets:member(?CHAN, {node_cut, B, A}).

connected_to(Node) ->
    lists:sort([N || [N] <- ets:match(?PLACE, {{conn, Node, '$1'}})]).

try_connect(Here, There) ->
    case is_up(There) andalso not link_cut(Here, There) of
        true ->
            link_up(Here, There),
            true;
        false ->
            false
    end.

%% Each side's belief that it is connected is held separately, because the two
%% ends of a real connection find out about its loss separately. See `learns` in
%% `partition/3`.
link_up(A, B) ->
    ok = believe(A, B),
    believe(B, A).

believe(X, Y) ->
    case ets:insert_new(?PLACE, {{conn, X, Y}}) of
        true -> node_event(X, nodeup, Y, undefined);
        false -> ok
    end.

link_down(A, B, Learns, Reason) ->
    Sides =
        case Learns of
            both -> [{A, B}, {B, A}];
            a -> [{A, B}];
            b -> [{B, A}]
        end,
    lists:foreach(fun({X, Y}) -> disbelieve(X, Y, Reason) end, Sides).

disbelieve(X, Y, Reason) ->
    case ets:member(?PLACE, {conn, X, Y}) of
        true ->
            true = ets:delete(?PLACE, {conn, X, Y}),
            ok = node_monitors_down(X, Y),
            node_event(X, nodedown, Y, Reason);
        false ->
            ok
    end.

%% `monitor_node/2` watches on node `X` of node `Y`: each one fires once and goes.
%% In watch order, like the subscriptions.
node_monitors_down(X, Y) ->
    Watchers = lists:sort([
        {Pid, W}
     || [Pid, W] <- ets:match(?PLACE, {{nmon, '$1'}, X, '$2'}), lists:member(Y, W)
    ]),
    lists:foreach(
        fun({Pid, W}) ->
            Fired = [N || N <- W, N =:= Y],
            Left = [N || N <- W, N =/= Y],
            _ = [(catch erlang:send(Pid, {nodedown, Y})) || _ <- Fired],
            _ = [bump(signalled) || _ <- Fired],
            case Left of
                [] -> true = ets:delete(?PLACE, {nmon, Pid});
                _ -> true = ets:insert(?PLACE, {{nmon, Pid}, X, Left})
            end
        end,
        Watchers
    ).

drop_connection(Here, There) ->
    case ets:member(?PLACE, {conn, Here, There}) orelse ets:member(?PLACE, {conn, There, Here}) of
        false ->
            false;
        true ->
            Ours = on_node(Here),
            Theirs = on_node(There),
            _ = [cancel_pending(P, Q) || P <- Ours, Q <- Theirs],
            _ = [cancel_pending(Q, P) || P <- Ours, Q <- Theirs],
            ok = sever(Ours, Theirs, both),
            ok = link_down(Here, There, both, disconnect),
            true
    end.

%% `kill_node/2`, after the processes are gone: the node is down, every survivor
%% connected to it hears `nodedown`, and its own subscriptions went with it.
node_down(Node, Dying) ->
    true = ets:insert(?PLACE, {{down, Node}}),
    Peers = lists:sort([N || [N] <- ets:match(?PLACE, {{conn, '$1', Node}})]),
    lists:foreach(fun(Peer) -> disbelieve(Peer, Node, connection_closed) end, Peers),
    true = ets:match_delete(?PLACE, {{conn, Node, '_'}}),
    lists:foreach(fun(P) -> true = ets:delete(?PLACE, {sub, P}) end, Dying),
    lists:foreach(fun(P) -> true = ets:delete(?PLACE, {nmon, P}) end, Dying),
    ok.

%% Tells every subscriber on `Node`, in subscription order. Direct, as
%% `signals/3` is.
node_event(Node, Kind, Other, Reason) ->
    Subs = lists:sort([
        {Seq, Pid, Subs}
     || [Pid, Seq, Subs] <- ets:match(?PLACE, {{sub, '$1'}, Node, '$2', '$3'})
    ]),
    lists:foreach(
        fun({_Seq, Pid, Each}) ->
            lists:foreach(
                fun(Opts) ->
                    case node_message(Kind, Other, Reason, Opts) of
                        skip ->
                            ok;
                        Msg ->
                            _ = (catch erlang:send(Pid, Msg)),
                            bump(signalled),
                            _ = eta_log:log({net, signal, Pid, Kind})
                    end
                end,
                Each
            )
        end,
        Subs
    ).

node_message(Kind, Other, _Reason, []) ->
    {Kind, Other};
node_message(Kind, Other, Reason, Opts) ->
    case lists:member({node_type, hidden}, Opts) of
        true ->
            skip;
        false ->
            Type = [
                {node_type, visible}
             || T <- [visible, all], lists:member({node_type, T}, Opts)
            ],
            Why = [
                {nodedown_reason, Reason}
             || Kind =:= nodedown, lists:member(nodedown_reason, Opts)
            ],
            {Kind, Other, lists:sublist(Type, 1) ++ Why}
    end.

%% ---------------------------------------------------------------------------
%% Monitors
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
`erlang:monitor/2,3`, with monitors that can fire `noconnection` on a simulated
link failure.

Most systems detect a failed peer with a monitor. Under a partition in one VM,
the target is still alive and a VM monitor does not fire. `eta_transform` points
`erlang:monitor/2,3` and `erlang:demonitor/1,2` of a module at this module, so
the code of the system needs no change.

## Simulated monitors and VM monitors

A simulated monitor is a record in this module. No VM monitor exists for it. A
monitor is simulated when a network is running, the type is `process`, the
options contain no `alias`, and one of these conditions holds when the monitor
is created:

- The watcher and the target are located on different simulated nodes.
- The item is `{Name, Node}`, `Node` is not the real node, and this module
  resolves the item to a process. The VM cannot resolve such an item.

Every other monitor is a VM monitor, created with `erlang:monitor/2,3`.
Examples:

- a monitor between two processes on one simulated node;
- a monitor with an end that is not located;
- a monitor with no topology declared;
- a monitor on a port or on `time_offset`;
- a monitor with an `alias`.

The rule is narrow for two reasons:

- Only a simulated monitor can fire `noconnection`. The VM does not let one
  process cancel the monitor of another process, and a `DOWN` message that is
  already sent cannot be changed. A VM monitor on a process of a killed node
  would report `killed` to a watcher on another node.
- A simulated monitor fires for an exit only when this module is notified of the
  exit. See `notify_exit/2`. If the notification is missing, the watcher waits
  with no end. The rule limits that risk to the monitors that a link failure can
  sever.

A monitor created before its two ends are located is a VM monitor and never
fires `noconnection`. Declare the topology before the system creates monitors,
in `init/2` of the harness.

## Messages

A simulated monitor fires once and is then removed, as a VM monitor is.

| Message | Condition |
|---|---|
| `{'DOWN', Ref, process, Object, noconnection}` | `partition/3`, `kill_node/2` or `disconnect_node/1` severs the link between the watcher and the target. |
| `{'DOWN', Ref, process, Object, Reason}` | The target exits. `Reason` is the real exit reason, reported by `eta_sched`. See `notify_exit/2`. |
| `{'DOWN', Ref, process, Object, noconnection}`, at once | The link between the watcher and the target is already down when the monitor is created. |
| `{'DOWN', Ref, process, Object, noproc}`, at once | The target is already dead when the monitor is created, and the link is not down. |

`Object` is the value that `erlang:monitor/2` uses: the pid for a pid, and
`{Name, node()}` for a registered name. A `{tag, Tag}` option replaces `'DOWN'`
with `Tag`, as for the BIF.

A monitor that cannot be established fires at once, as the BIF does. A process
that monitors a peer in order to detect that the peer is unreachable depends on
this message.

A special case is an item `{Name, Node}` for which no process holds `Name` on
the simulated node `Node`. When the caller is on a simulated node, the function
creates no monitor and sends one `DOWN` at once:

- `noproc` when `Node` is the node of the caller.
- `noproc` when `Node` is another node and `connect_node/1` succeeds.
- `noconnection` when `connect_node/1` fails.

## Rules for `noconnection`

- A `noconnection` DOWN is final. Real Erlang does not arm a monitor again after
  the message, and this module does not either. `heal_partition/3` restores no
  monitor. A system that needs the monitor must create it again.
- The `noconnection` at creation reports the state of the link at that time. It
  does not repeat an earlier failure.
- A link is down when both directions are cut at the node level. `partition/3`
  between two nodes produces this state. Real distribution has no failure of one
  direction only: when the tick of either end times out, the whole connection
  closes.
- A `cut/2` of one direction, and a `cut/2` between two processes, leave the
  link up. A monitor created across such a cut is established and does not fire.
  See `cut/2`.

## Limitations

- The check at creation reads the recorded cut. It does not read which side has
  received the link events. After `partition/3` with `learns => a`, side B has
  received no link event, and a monitor that side B creates still fires
  `noconnection` at once.
- A monitor created on the pid of a process that died in `kill_node/2` fires
  `noproc`, not `noconnection`.
""".
-endif.
-spec monitor(process | port | time_offset, term()) -> reference().
monitor(Type, Item) ->
    monitor(Type, Item, []).

-spec monitor(process | port | time_offset, term(), list()) -> reference().
monitor(process, Item, Opts) ->
    case running() andalso not lists:keymember(alias, 1, Opts) of
        true -> do_monitor(Item, Opts);
        false -> erlang:monitor(process, Item, Opts)
    end;
monitor(Type, Item, Opts) ->
    erlang:monitor(Type, Item, Opts).

do_monitor(Item, Opts) ->
    Watcher = self(),
    case normalize(Item) of
        Target when is_pid(Target) ->
            %% `simulated_pair/2` decides whether the monitor can be *faulted*,
            %% which same-node pairs cannot be. That is not the same question as
            %% whether it can be handed to `erlang:monitor/3`: a `{Name, Node}`
            %% naming a **simulated** node cannot, because the VM has no such
            %% node and answers `badarg` when it is not distributed at all.
            %%
            %% This bit hard. An agent monitoring the lock server on its *own*
            %% simulated node is a same-node pair, so it took the fallback and
            %% died on the spot — and since the only node whose name the VM
            %% recognises is `node()`, exactly one process per cluster survived
            %% doing it. What that looks like from outside is a cluster that
            %% elects exactly one leader and never two, which reads like the
            %% system being conservative rather than like most of it being dead.
            case simulated_pair(Watcher, Target) orelse simulated_name(Item) of
                true -> simulate_monitor(Watcher, Target, Item, Opts);
                false -> erlang:monitor(process, Item, Opts)
            end;
        undefined ->
            case unheld_simulated_name(Item) of
                {true, Reason} ->
                    %% `{Name, Node}` for a simulated node where nothing holds
                    %% `Name`. The VM cannot be asked: `Node` is not a node it
                    %% knows, so `erlang:monitor/3` answers `badarg` rather than
                    %% the DOWN distribution delivers. The case that found it is
                    %% a node that was killed and not restarted. A lock agent
                    %% monitoring the lock server there crashed on the spot, where
                    %% real distribution tells it the node is gone and it carries
                    %% on with the others, and the election above it spun.
                    Ref = make_ref(),
                    ok = fire({Ref, Watcher, undefined, Item, down_tag(Opts), next_seq()}, Reason),
                    Ref;
                false ->
                    %% An unregistered name, or a destination this module cannot
                    %% identify as a local process. `erlang:monitor/2` already does
                    %% the right thing with both — an immediate `noproc` for the
                    %% first, a real distributed monitor for the second — and
                    %% neither is something to reimplement.
                    erlang:monitor(process, Item, Opts)
            end
    end.

%% What a monitor on `{Name, Node}` gets at once when `Node` is a simulated node
%% and nothing there holds `Name`, asked by a process on a simulated node: as
%% distribution does, it connects first, and the DOWN says `noconnection` if it
%% cannot and `noproc` if it can. A name on the caller's own node is `noproc`.
unheld_simulated_name({Name, Node}) when is_atom(Name) ->
    case local_node() of
        undefined ->
            false;
        Node ->
            {true, noproc};
        _Here ->
            case is_node(Node) of
                false ->
                    false;
                true ->
                    case connect_node(Node) of
                        true -> {true, noproc};
                        _ -> {true, noconnection}
                    end
            end
    end;
unheld_simulated_name(_) ->
    false.

simulate_monitor(Watcher, Target, Item, Opts) ->
    Ref = make_ref(),
    Mon = {Ref, Watcher, Target, object(Item), down_tag(Opts), next_seq()},
    true = ets:insert(?MONS, Mon),
    %% `erlang:monitor/2` on a dead process delivers `noproc` at once rather than
    %% never, and code that waits for a DOWN it will not otherwise get relies on
    %% it.
    %%
    %% **Liveness comes from `notify_exit/2`'s record, not from the VM**, and
    %% neither obvious BIF will do.
    %%
    %% `erlang:is_process_alive/1` and `erlang:process_info/2` are both
    %% signal-based against a live target: to keep their answer ordered against
    %% signals the caller has already sent it, they ask the target and wait for a
    %% reply — and a reply is something the target produces by *running*. Every
    %% target here is one `eta_sched` owns, so it is suspended, and the watcher is
    %% exactly the kind of process that has been sending it things. The watcher's
    %% progress therefore came to depend on when its target was next stepped, which
    %% is the VM ordering two processes where the schedule is supposed to. It cost
    %% about one seed in forty its reproducibility, and showed up as a member
    %% parked in `erts_internal:await_result/1` at a choice point — first under
    %% `is_process_alive/1`, then in the same place under `process_info/2`, which
    %% is what ruled out swapping one for the other.
    %%
    %% `eta_sched` reports every exit it sees, and every process that can be a
    %% target here is one it owns — `simulated_pair/2` requires both ends placed —
    %% so that report is the authority. Reading it asks the target for nothing.
    case cannot_establish(Watcher, Target) of
        {true, Reason} -> fire(Mon, Reason);
        false -> ok
    end,
    Ref.

%% Why this monitor cannot be set up at all, if it cannot. Both answers are the
%% same rule — the BIF reports "could not establish" at once rather than never —
%% and both are facts about right now rather than events being replayed. See
%% `monitor/2`.
%%
%% The link is asked about first, because that is the order reality has them in:
%% across a severed connection the watcher cannot learn *anything* about the
%% target, its having exited included, so `noconnection` is what it is told.
cannot_establish(Watcher, Target) ->
    case link_down(Watcher, Target) of
        true ->
            {true, noconnection};
        false ->
            case target_dead(Target) of
                true -> {true, noproc};
                false -> false
            end
    end.

%% Whether the connection between two processes' nodes is down.
%%
%% Both directions, and node-level only. That is exactly the state `partition/3`
%% leaves behind, and it is what a lost link *is*: real distribution has no
%% one-way connection failure. A `cut/2` — one direction, or between two
%% processes rather than two nodes — is documented as a channel that swallows
%% traffic while both ends still believe the link is up, and a monitor that could
%% not be established is precisely a thing an end that believes the link is up
%% would not observe. So a cut fires nothing here, as it fires nothing anywhere
%% else in this module.
%%
%% Attached processes are subject to it, for the reason `simulated_pair/2` gives:
%% they are behind the same wire as everything else on their node, and `node_of/1`
%% locates them like anything else.
%%
%% `kill_node/2` is not covered, because it records no cut — it kills. A monitor
%% created on something it killed therefore answers `noproc` where real
%% distribution would answer `noconnection` for a node that is not there. Both are
%% immediate, so nothing waits on a DOWN that never comes, which is the failure
%% this predicate exists to prevent; the reason differs, and closing that needs a
%% record of which nodes are dead rather than merely empty.
link_down(A, B) ->
    node_cut(A, B) andalso node_cut(B, A).

%% Whether a monitor's target has already exited.
%%
%% Which answer is authoritative depends on whether a scheduler is running, and
%% that is the subtlety. Under one, nothing may ask a suspended process a question
%% (see above) and nothing needs to, because the scheduler reports every exit
%% through `notify_exit/2`. Without one — driving a network by hand, which this
%% module supports — no exit is ever reported, but nothing is suspended either, so
%% the VM is safe to ask.
target_dead(Target) ->
    ets:member(?DEAD, Target) orelse
        (eta_sched:current() =:= undefined andalso not erlang:is_process_alive(Target)).

%% Whether this pair is one a severed link could separate: both located, on
%% different simulated nodes. Faultability is not consulted — it decides whose
%% *messages* may be dropped, and a monitor is not a message. An attached process
%% is behind the same wire as everything else on its node and its monitors fail
%% with it.
simulated_pair(Watcher, Target) ->
    case {placement(Watcher), placement(Target)} of
        {{A, _}, {B, _}} when A =/= B -> true;
        {_, _} -> false
    end.

%% Whether this destination is a name only *this* module can resolve. `normalize/1`
%% answers `{Name, Node}` from the simulated registry for any node that is not
%% `node()`, so a pid coming back for one of those means the VM cannot resolve it
%% and must not be asked to. See `register_name/3`.
simulated_name({Name, Node}) when is_atom(Name), Node =/= erlang:node() ->
    is_pid(normalize({Name, Node}));
simulated_name(_) ->
    false.

%% Whether a `{Name, Node}` names a node the topology knows — whatever is or
%% is not registered there. `place/2` records every node it is given.
on_simulated_node({Name, Node}) when is_atom(Name), Node =/= erlang:node() ->
    ets:member(?PLACE, {node, Node});
on_simulated_node(_) ->
    false.

%% What `erlang:monitor/2` puts in the DOWN message's `Object` position.
object(Pid) when is_pid(Pid) -> Pid;
object(Name) when is_atom(Name) -> {Name, erlang:node()};
object({Name, Node}) when is_atom(Name), is_atom(Node) -> {Name, Node};
object(Other) -> Other.

down_tag(Opts) ->
    case lists:keyfind(tag, 1, Opts) of
        {tag, Tag} -> Tag;
        false -> 'DOWN'
    end.

-if(?DOCATTRS).
-doc "`erlang:demonitor/1`. See `monitor/2`.".
-endif.
-spec demonitor(reference()) -> true.
demonitor(Ref) ->
    _ = demonitor(Ref, []),
    true.

-if(?DOCATTRS).
-doc """
`erlang:demonitor/2`, with the options `flush` and `info`. See `monitor/2`.

For a simulated monitor that has not fired, the function removes the monitor and
returns `true`.

For a simulated monitor that has already fired, the function behaves as the BIF
does for a VM monitor that has fired. It returns `true`, or `false` with the
`info` option, and it does not raise.
""".
-endif.
-spec demonitor(reference(), list()) -> boolean().
demonitor(Ref, Opts) ->
    case running() andalso ets:take(?MONS, Ref) of
        [{Ref, _W, _T, _O, Tag, _Seq}] ->
            flush_down(lists:member(flush, Opts), Tag, Ref),
            result(Opts, true);
        _ ->
            demonitor_real(Ref, Opts)
    end.

demonitor_real(Ref, Opts) ->
    try
        erlang:demonitor(Ref, Opts)
    catch
        error:badarg when is_reference(Ref) ->
            %% A simulated monitor that already fired: its row is gone and the
            %% ref was never a VM monitor, so the BIF cannot recognise it. Real
            %% Erlang does not raise for a fired monitor and neither may we, or a
            %% system tidying up after a DOWN would crash on the tidying.
            flush_down(lists:member(flush, Opts), 'DOWN', Ref),
            result(Opts, false)
    end.

result(Opts, Found) ->
    case lists:member(info, Opts) of
        true -> Found;
        false -> true
    end.

flush_down(false, _Tag, _Ref) ->
    ok;
flush_down(true, Tag, Ref) ->
    receive
        {Tag, Ref, _Type, _Object, _Reason} -> ok
    after 0 -> ok
    end.

-if(?DOCATTRS).
-doc """
Records that a process has exited, and fires the simulated monitors on it with
the exit reason.

`eta_sched` calls this function from the exit trace event. A harness does not
call it. The function does nothing when no network is running.

The function does the following:

1. It records the process as dead. A simulated monitor that is created on the
   process later fires `noproc` at once, without a call to the VM.
2. It removes the `monitor_nodes/1` subscriptions and the `monitor_node/2`
   watches of the process.
3. It fires every simulated monitor on the process, in the order in which the
   monitors were created.
4. It removes every simulated monitor that the process held.

## Source of the notification

A simulated monitor has no VM monitor, so another component must report the
exit of the target. The alternatives to `eta_sched` were rejected:

| Alternative | Defect |
|---|---|
| A broker process with VM monitors | The scheduler does not own the broker, so the broker forwards the `DOWN` at a time that the VM decides. The message is then ordered by real time. |
| A VM monitor in the watcher, with a private tag | The message arrives at the correct time with the wrong content. No process can change a message in the mailbox of another process. |
| Polling | The monitor fires at the next driver call, not at the exit. |

`eta_sched` is the tracer of every process in a run, and it calls `inherit/2`
from the same handler. It receives the exit in the step that caused the exit.
Only one process runs during a step. A `DOWN` that is sent at the end of the
step therefore follows every message that the dying process sent during the
step. The VM produces the same order.

## Limitations

- A target that the scheduler does not own reports no exit, so a simulated
  monitor on such a target never fires for an exit. Every process that a run
  schedules is owned, so the limitation applies only to processes outside the
  run.
""".
-endif.
-spec notify_exit(pid(), term()) -> ok.
notify_exit(Pid, Reason) ->
    case running() of
        true ->
            %% Recorded before the fan-out, so a monitor created later on a target
            %% that has already exited answers `noproc` without asking the VM. See
            %% `simulate_monitor/4`.
            true = ets:insert(?DEAD, {Pid}),
            true = ets:delete(?PLACE, {sub, Pid}),
            true = ets:delete(?PLACE, {nmon, Pid}),
            _ = [fire(M, Reason) || M <- monitors_on(Pid)],
            %% Whatever it was watching, it is not watching any more.
            true = ets:match_delete(?MONS, {'_', Pid, '_', '_', '_', '_'}),
            ok;
        false ->
            ok
    end.

-if(?DOCATTRS).
-doc false.
-endif.
%% Whether this module has recorded the exit of `Pid`, through `notify_exit/2`
%% or `kill_node/2`. For `eta_sched:is_alive/1`. `false` when no network is
%% running.
-spec exited(pid()) -> boolean().
exited(Pid) ->
    try
        ets:member(?DEAD, Pid)
    catch
        error:badarg -> false
    end.

%% Every simulated monitor whose target is `Pid`, oldest first. Ordered for the
%% same reason `on_node/1` is: a fan-out whose order came from the table is a
%% fan-out that differs between runs of one seed.
monitors_on(Pid) ->
    by_seq(ets:match_object(?MONS, {'_', '_', Pid, '_', '_', '_'})).

by_seq(Mons) ->
    lists:sort(fun({_, _, _, _, _, S1}, {_, _, _, _, _, S2}) -> S1 =< S2 end, Mons).

%% Delivers a DOWN and retires the monitor, in that order for no reason other
%% than that the row must be gone before anything can ask about it again. Direct
%% rather than routed: a DOWN is a signal, and a cut channel must not be able to
%% swallow the announcement of the cut.
fire({Ref, Watcher, _Target, Object, Tag, _Seq}, Reason) ->
    true = ets:delete(?MONS, Ref),
    _ = (catch erlang:send(Watcher, {Tag, Ref, process, Object, Reason})),
    case Reason of
        noconnection -> bump(noconnection);
        _ -> ok
    end,
    _ = eta_log:log({net, {down, Reason}, Watcher, Tag}),
    ok.

%% ---------------------------------------------------------------------------
%% Targeted faults
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Drops every message sent from `From` to `To` until `heal/2`. The cut applies to
one direction.

`From` and `To` are both simulated nodes or both processes:

- A cut between two nodes applies to every process on the nodes. It also applies
  to a process that is placed on one of the nodes later, such as a restarted
  process.
- A cut between two processes applies to those two pids.
- An atom that names both a simulated node and a registered process is treated
  as a node. Pass a pid to cut the process.

Delayed messages on the channel are cancelled, because a failing link loses the
messages that are in transit. Each cancelled message is counted as `dropped` and
as `cancelled`.

A cut delivers no link event: no signal is sent and no monitor fires. Both ends
continue to treat the link as up. A lost connection does not produce this state.
Real distribution closes the whole connection when the tick of either end times
out, and both ends then receive the event. Use `partition/3` for a lost
connection or a lost node. Use `cut/2` for a channel that drops messages while
the connection stays up.

Raises `{eta_net, {mixed_cut, Resolved, Text}}` when one argument is a node and
the other is a process. Raises `{eta_net, {no_network, cut, Text}}` when no
network is running.
""".
-endif.
-spec cut(dest(), dest()) -> ok.
cut(From0, To0) ->
    ok = require_running(cut),
    case {resolve(From0), resolve(To0)} of
        {{node, A}, {node, B}} ->
            true = ets:insert(?CHAN, {{node_cut, A, B}}),
            %% Everything already in flight across the link is lost with it.
            _ = [cancel_pending(P, Q) || P <- on_node(A), Q <- on_node(B)],
            true = ets:delete(?CHAN, {link_last, A, B}),
            ok;
        {{pid, From}, {pid, To}} ->
            true = ets:insert(?CHAN, {{cut, From, To}}),
            _ = cancel_pending(From, To),
            ok;
        Mixed ->
            error(
                {eta_net,
                    {mixed_cut, Mixed, <<
                        "cut both ends as nodes or both as processes, not one of each"
                    >>}}
            )
    end.

-if(?DOCATTRS).
-doc "Removes a cut made with `cut/2`, in one direction. Raises `{eta_net, {mixed_cut, Resolved}}` when one argument is a node and the other is a process.".
-endif.
-spec heal(dest(), dest()) -> ok.
heal(From0, To0) ->
    ok = require_running(heal),
    case {resolve(From0), resolve(To0)} of
        {{node, A}, {node, B}} -> true = ets:delete(?CHAN, {node_cut, A, B});
        {{pid, From}, {pid, To}} -> true = ets:delete(?CHAN, {cut, From, To});
        Mixed -> error({eta_net, {mixed_cut, Mixed}})
    end,
    ok.

-if(?DOCATTRS).
-doc "Cuts both directions between `A` and `B` and delivers the link events, with no signal. See `partition/3`.".
-endif.
-spec partition(dest(), dest()) -> ok.
partition(A, B) ->
    partition(A, B, #{}).

-if(?DOCATTRS).
-doc """
Cuts both directions between `A` and `B` and delivers the link events of the
failure.

```erlang
eta_net:partition(na, nb, #{signal => nodedown}).
```

`A` and `B` are both simulated nodes or both processes, as for `cut/2`.

| Option | Default | Meaning |
|---|---|---|
| `signal` | No signal | A message sent to every located process on each side. |
| `learns` | `both` | The side that receives the link events: `both`, `a` or `b`. |

The function does the following, in this order:

1. It cuts both directions and cancels the delayed messages, as `cut/2` does.
2. It fires every simulated monitor held across the partition with
   `noconnection`.
3. When `A` and `B` are nodes, it disconnects them and sends `nodedown` to the
   `monitor_node/2` watchers and the `monitor_nodes/1` subscribers.
4. It sends the signal, if the `signal` option is given.

Raises `{eta_net, {bad_learns, Value, Text}}` for any other value of `learns`.
Raises `{eta_net, {mixed_cut, Resolved, Text}}` when one argument is a node and
the other is a process.

## Signal

A real link failure delivers `nodedown` to both ends, and systems start recovery
from that event. A partition that delivers no event leaves both ends treating
the link as up while messages are lost. No network produces that state, and the
state that the system then fails to recover from is not a defect of the system.

Recovery that starts from the event can also repair the divergence that a run is
testing. A run that checks a property during a fault should restrict loss with
the `scope` of the policy instead. Neither choice fits every run, so the
`signal` option has no default.

| `signal` | Message to side A | Message to side B |
|---|---|---|
| An atom, such as `nodedown` | `{nodedown, B}` | `{nodedown, A}` |
| `{literal, Term}` | `Term` | `Term` |
| Any other term | The term | The term |

An atom is the kind of the event. Each side receives the kind with the name of
the other side: the processes on A receive that B is gone, and the processes on
B receive that A is gone. The name of a side is the node name when the argument
named a node, and the pid otherwise.

The other two forms send one complete term to both sides. For example,
`#{signal => {nodedown, node()}}` sends `{nodedown, node()}` to both sides. Use
`{literal, Atom}` to send a signal that is a single atom.

## The `learns` option

`learns` selects the side that receives the link events. It applies to the
DOWNs, the `nodedown` messages and the signal together.

```erlang
eta_net:partition(na, nb, #{signal => nodedown, learns => a}).
```

In this example, side A receives the events for the loss of B, and side B
receives nothing. Real distribution produces this asymmetry, because the two
ends time out independently. The cut is symmetric in every case: a lost link
loses both directions.

Side B receives its events when the partition heals, at the latest.
`heal_partition/2,3` first delivers the events of side B: the DOWNs, the
`nodedown` messages and the signal of the partition. It then heals the cut. This
order models the real case: side A closed its end of the connection, so side B
receives the loss of the connection as soon as packets arrive again. Without
this step, a call that side B made into the cut would wait for its whole
time-out after the heal.

## Connections

When `A` and `B` are nodes, the partition disconnects them. On each side that
receives the link events, the `monitor_nodes/1` subscribers receive
`{nodedown, Other}`, with the reason `net_tick_timeout`. A system that watches
`net_kernel` acts on this message, so most runs need no `signal`. Use `signal`
for a system that detects a failure in another way. See "Node identity" in the
module documentation.

## Monitors

Every simulated monitor held across the partition fires
`{'DOWN', Ref, process, Object, noconnection}` once and is removed. With
`learns`, only the monitors whose watcher is on the selected side fire. See
`monitor/2`.

## Delivery order

1. The DOWNs, in the order in which the monitors were created.
2. For side A and then for side B: `{nodedown, Other}` to the `monitor_node/2`
   watchers, then to the `monitor_nodes/1` subscribers in subscription order.
3. The signal to the processes of side A, in placement order.
4. The signal to the processes of side B, in placement order.

Every message is sent directly and is not routed, so the cut cannot drop it.
Every message is sent before the call returns. No process that the scheduler
owns runs during the call, so no process observes a part of the events.
""".
-endif.
-spec partition(dest(), dest(), event_opts()) -> ok.
partition(A, B, Opts) ->
    ok = cut(A, B),
    ok = cut(B, A),
    ok = link_event(A, B, Opts),
    case learns(Opts) of
        both ->
            ok;
        _ ->
            true = ets:insert(?CHAN, {{one_sided, A, B}, Opts}),
            ok
    end.

-if(?DOCATTRS).
-doc "Heals both directions between `A` and `B`, with no signal. See `heal_partition/3`.".
-endif.
-spec heal_partition(dest(), dest()) -> ok.
heal_partition(A, B) ->
    heal_partition(A, B, #{}).

-if(?DOCATTRS).
-doc """
Heals both directions between `A` and `B`, and optionally sends a signal.

The options are those of `partition/3`. `#{signal => nodeup}` sends
`{nodeup, B}` to side A and `{nodeup, A}` to side B. `learns` restricts the
signal to one side.

The function does the following, in this order:

1. If the partition was made with `learns => a` or `learns => b`, it delivers
   the link events of the partition to the other side. See `partition/3`.
2. It removes the cut in both directions.
3. It sends the signal, if the `signal` option is given.

A heal is a second event. It does not undo the failure:

- A monitor that fired `noconnection` is not restored, as in real Erlang. A
  system that needs the monitor must create it again.
- The nodes remain disconnected until a process connects them, with
  `connect_node/1` or with a send without `noconnect`.
""".
-endif.
-spec heal_partition(dest(), dest(), event_opts()) -> ok.
heal_partition(A, B, Opts) ->
    ok = learn_late(A, B),
    ok = learn_late(B, A),
    ok = heal(A, B),
    ok = heal(B, A),
    signals(A, B, Opts).

%% The side a one-sided partition left unaware learns of it now, before the link
%% comes back. The side that noticed closed its end of the connection, so the
%% first thing the other end hears once packets flow again is that its connection
%% is gone: its monitors fire `noconnection` and its `monitor_nodes` subscribers
%% get `nodedown`. Left unaware, a call it made into the cut would wait out its
%% whole time-out after the heal, which real distribution never does.
learn_late(A, B) ->
    case ets:take(?CHAN, {one_sided, A, B}) of
        [{_, Opts}] ->
            Late =
                case learns(Opts) of
                    a -> b;
                    b -> a
                end,
            link_event(A, B, Opts#{learns => Late});
        [] ->
            ok
    end.

%% A link between A and B has failed: retire the monitors that crossed it, tell
%% the `monitor_nodes` subscribers, then deliver any signal.
link_event(A, B, Opts) ->
    ok = sever(endpoints(A), endpoints(B), learns(Opts)),
    ok =
        case {resolve(A), resolve(B)} of
            {{node, X}, {node, Y}} -> link_down(X, Y, learns(Opts), net_tick_timeout);
            _ -> ok
        end,
    signals(A, B, Opts).

%% Fires `noconnection` at every simulated monitor with one end on each side.
%%
%% `learns` selects by *watcher*, since it says who noticed: with `learns => a`,
%% only monitors held from side A fire, and side B carries on believing its peer
%% is reachable.
sever(SideA, SideB, Learns) ->
    A = sets:from_list(SideA),
    B = sets:from_list(SideB),
    Straddling = [
        M
     || M = {_Ref, W, T, _O, _Tag, _Seq} <- ets:tab2list(?MONS),
        straddles(W, T, A, B, Learns)
    ],
    _ = [fire(M, noconnection) || M <- by_seq(Straddling)],
    ok.

straddles(W, T, A, B, Learns) ->
    (Learns =/= b andalso sets:is_element(W, A) andalso sets:is_element(T, B)) orelse
        (Learns =/= a andalso sets:is_element(W, B) andalso sets:is_element(T, A)).

learns(Opts) ->
    case maps:get(learns, Opts, both) of
        L when L =:= both; L =:= a; L =:= b ->
            L;
        Other ->
            error(
                {eta_net,
                    {bad_learns, Other, <<"expected both, a or b — see eta_net:partition/3">>}}
            )
    end.

%% Delivers the signal, derived per side. Side A hears about B and side B hears
%% about A; `learns` can silence either.
signals(A, B, Opts) ->
    case maps:find(signal, Opts) of
        error ->
            ok;
        {ok, Sig} ->
            Learns = learns(Opts),
            ok = emit(sides(Learns, a, endpoints(A)), derive(Sig, name_of(B))),
            ok = emit(sides(Learns, b, endpoints(B)), derive(Sig, name_of(A)))
    end.

sides(both, _Side, Pids) -> Pids;
sides(Side, Side, Pids) -> Pids;
sides(_Other, _Side, _Pids) -> [].

%% An atom is a kind and is derived; anything else is already the message. Kept
%% in that order so `#{signal => {nodedown, node()}}` — the form that has callers
%% — is untouched, and `{literal, Atom}` is the escape for a bare atom.
derive({literal, Term}, _Other) -> Term;
derive(Kind, Other) when is_atom(Kind) -> {Kind, Other};
derive(Term, _Other) -> Term.

%% What the other side is *called*, for a derived signal: the node name if the
%% argument named one, and the pid otherwise. A pid-level partition has no node
%% names to offer and saying so is better than inventing one.
name_of(Ref) ->
    case resolve(Ref) of
        {node, Node} -> Node;
        {pid, Pid} -> Pid
    end.

emit(Pids, Sig) ->
    lists:foreach(
        fun(P) ->
            case is_pid(P) of
                true ->
                    _ = (catch erlang:send(P, Sig)),
                    bump(signalled),
                    _ = eta_log:log({net, signal, P, tag(Sig)});
                false ->
                    ok
            end
        end,
        Pids
    ),
    ok.

%% Who a link signal reaches: everything on the node, not a representative — a
%% process that never saw the event is one the harness excluded from recovering.
%% In placement order; see `on_node/1` for why that matters.
endpoints(Ref) ->
    case resolve(Ref) of
        {node, Node} -> on_node(Node);
        {pid, Pid} -> [Pid]
    end.

-if(?DOCATTRS).
-doc "Kills the simulated node `Node` with no signal. See `kill_node/2`.".
-endif.
-spec kill_node(term()) -> ok.
kill_node(Node) ->
    kill_node(Node, #{}).

-if(?DOCATTRS).
-doc """
Kills a simulated node: every located process on the node dies, and the
surviving processes receive the link events of the loss.

```erlang
eta_net:kill_node(nb, #{signal => nodedown}).
```

The only option is `signal`. See `partition/3` for its forms. An atom `Signal`
is sent as `{Signal, Node}`.

The function does the following, in this order:

1. It fires `{'DOWN', Ref, process, Object, noconnection}` for every simulated
   monitor that a process on another node holds on a process of the node.
2. It removes every simulated monitor that has either end on the node.
3. It cancels the delayed messages to and from the processes of the node.
4. It kills every located process on the node, placed and attached, and waits
   until each process has exited. It also cancels the timers of these processes.
5. It applies a disk crash to the files of the node, when a disk is running. See
   `eta_disk:crash/1`.
6. It marks the node as down and disconnects every node that is connected to it.
   The `monitor_nodes/1` subscribers of those nodes receive `{nodedown, Node}`,
   with the reason `connection_closed`.
7. It sends the signal to every surviving located process, in placement order.

A harness that builds this sequence from `place/2`, `exit/2` and `partition/3`
must keep the same order.

## Errors

| Error | Condition |
|---|---|
| `{eta_net, {no_such_node, Node, Text}}` | No process has been placed or attached on `Node`. |
| `{eta_net, {learns_on_kill, Node, Text}}` | The options contain `learns`. Only the surviving side receives events, so `learns` has no meaning here. |
| `{eta_net, {kill_timeout, Pid, Text}}` | A process of the node did not exit within 5 s of real time. |
| `{eta_net, {no_network, kill_node, Text}}` | No network is running. |

## Order of step 1 and step 4

Real distribution reports a lost node as `noconnection` to a monitor on another
node. A monitor on the same machine receives the real exit reason. One VM cannot
produce both results with VM monitors, because a killed process reports `killed`
to every monitor on it. The function therefore fires and removes the monitors
from other nodes before it kills the processes.

Step 1 must also come before step 4 because the exit signal is asynchronous.
After the kill, the scheduler can report the exit at any time. A simulated
monitor that still exists at that time would fire with the real exit reason.

A monitor held by a process that is not located is a VM monitor and receives
`killed`. Examples are a client, a harness and an observer.

## Atomicity

The whole sequence runs in the driver, between steps, while every process that
the scheduler owns is suspended. No surviving process runs until the sequence is
complete, so no surviving process observes a node that is partly dead.

## Restart

The name of a killed node remains. The processes of the node do not. To restart
the node, call `place/2` or `attach/2` with the same name. The new processes get
new positions in the order of link events.

A restart does not reset the following:

- A cut that involves the node remains. A node that was partitioned and then
  killed is still partitioned after the restart, until the cut is healed.
- No monitor is created again for a surviving process.
""".
-endif.
-spec kill_node(term(), event_opts()) -> ok.
kill_node(Node, Opts) ->
    ok = require_running(kill_node),
    ets:member(?PLACE, {node, Node}) orelse
        error(
            {eta_net,
                {no_such_node, Node, <<
                    "nothing has been placed on this node, so killing it would be a "
                    "no-op that looks like a fault. Name a node from place/2 or attach/2"
                >>}}
        ),
    %% `learns` is a `partition/3` option and means nothing here — a node kill
    %% has one surviving side, and the side that died is not going to notice
    %% anything. Refused rather than ignored, since an option that silently does
    %% nothing reads at the call site as though it did.
    not is_map_key(learns, Opts) orelse
        error(
            {eta_net,
                {learns_on_kill, Node, <<
                    "kill_node/2 has only one side that can learn anything; "
                    "`learns` is a partition/3 option"
                >>}}
        ),
    Dying = on_node(Node),
    Survivors = located() -- Dying,
    ok = sever_from(Dying),
    ok = forget_monitors(Dying),
    ok = cancel_touching(Dying),
    ok = kill_all(Dying),
    %% After the processes are gone, so that none of them writes again: the
    %% simulated disk decides what the node's unsynced writes left behind. A
    %% no-op with no disk running. See `eta_disk:crash/1`.
    ok = eta_disk:node_killed(Node),
    ok = node_down(Node, Dying),
    case maps:find(signal, Opts) of
        error -> ok;
        {ok, Sig} -> emit(Survivors, derive(Sig, Node))
    end.

%% Step 1: the monitors a remote watcher holds on something about to die. A
%% watcher that is dying too is not told anything, and one that is not located is
%% not on the network at all — its monitor is a real one and reports the truth.
sever_from(Dying) ->
    D = sets:from_list(Dying),
    Straddling = [
        M
     || M = {_Ref, W, T, _O, _Tag, _Seq} <- ets:tab2list(?MONS),
        sets:is_element(T, D),
        not sets:is_element(W, D)
    ],
    _ = [fire(M, noconnection) || M <- by_seq(Straddling)],
    ok.

forget_monitors(Dying) ->
    lists:foreach(
        fun(P) ->
            true = ets:match_delete(?MONS, {'_', P, '_', '_', '_', '_'}),
            true = ets:match_delete(?MONS, {'_', '_', P, '_', '_', '_'})
        end,
        Dying
    ),
    ok.

%% Kills every process on the node and **waits for each to be gone** before
%% returning.
%%
%% The wait is what makes the kill atomic with respect to the schedule rather
%% than merely quick. `erlang:exit/2` posts a signal; the process dies some
%% moment later, and the moment is chosen by the BEAM. `eta_sched:runnable/1`
%% asks `is_process_alive/1`, so a driver that returned before the answer settled
%% would leave the scheduler's next choice depending on how fast a corpse was
%% reaped — a step chosen by wall clock, and a seed that stops reproducing its own
%% schedule. Two runs of one seed then differ by one step, which is the entire
%% failure mode this framework exists to prevent.
%%
%% `kill` is untrappable and reaches a suspended process, so this terminates. The
%% bound is there to fail loudly rather than hang a suite if it ever does not.
kill_all(Dying) ->
    Expected = vm_monitor_downs(Dying),
    Mons = [{P, erlang:monitor(process, P)} || P <- Dying],
    lists:foreach(
        fun(P) ->
            true = ets:delete(?PLACE, {pid, P}),
            %% As `notify_exit/2` would, but the scheduler has not seen these
            %% deaths yet and a survivor may monitor one before it does.
            true = ets:insert(?DEAD, {P}),
            %% Its timers die with it, as a real node's do. Left in the wheel
            %% they would be strays the run gets charged with, for a fault the
            %% run injected on purpose. See `eta_time:forget/1`.
            _ = eta_time:forget(P),
            true = erlang:exit(P, kill)
        end,
        Dying
    ),
    lists:foreach(fun await_death/1, Mons),
    lists:foreach(fun await_vm_down/1, Expected),
    ok.

%% The `DOWN' messages that VM monitors on the dying processes will deliver to
%% suspended survivors: `{Watcher, QueueLengthAfterDelivery}'.
%%
%% A simulated monitor is fired by `sever_from/1' before the kill, at a point
%% in the schedule. A VM monitor is fired by the VM while it removes the dead
%% process, and the harness's own `DOWN' in `await_death/1' can arrive before
%% the VM has sent the others. A watcher on the same node as its target has a
%% VM monitor, and so does a watcher that is not placed, such as a registry
%% that every node uses. `eta_sched' reads the queue length of each process at
%% its next choice. If the `DOWN' arrives after that read, the choice depends on
%% real time, and the seed stops reproducing its schedule.
%%
%% Only a suspended watcher is counted. Its queue cannot shrink, so the queue
%% reaches the expected length exactly when every `DOWN' has arrived. A watcher
%% that runs, such as the driver, takes messages out of its queue and gives no
%% such bound.
vm_monitor_downs(Dying) ->
    D = sets:from_list(Dying),
    Counts = lists:foldl(
        fun(W, Acc) -> maps:update_with(W, fun(N) -> N + 1 end, 1, Acc) end,
        #{},
        [
            W
         || P <- Dying,
            {monitored_by, Ws} <- [erlang:process_info(P, monitored_by)],
            W <- Ws,
            is_pid(W),
            not sets:is_element(W, D)
        ]
    ),
    [
        {W, Length + N}
     || {W, N} <- lists:sort(maps:to_list(Counts)),
        [{status, suspended}, {message_queue_len, Length}] <-
            [erlang:process_info(W, [status, message_queue_len])]
    ].

await_vm_down({Watcher, Length}) ->
    await_vm_down(Watcher, Length, erlang:monotonic_time(millisecond) + 5000).

await_vm_down(Watcher, Length, Deadline) ->
    case erlang:process_info(Watcher, message_queue_len) of
        undefined ->
            ok;
        {message_queue_len, N} when N >= Length ->
            ok;
        {message_queue_len, N} ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error(
                        {eta_net,
                            {down_timeout, Watcher, {N, Length}, <<
                                "a suspended process that monitors a killed process "
                                "did not receive its DOWN message within 5s"
                            >>}}
                    );
                false ->
                    erlang:yield(),
                    await_vm_down(Watcher, Length, Deadline)
            end
    end.

await_death({Pid, Mon}) ->
    receive
        {'DOWN', Mon, process, _, _} -> ok
    after 5000 ->
        true = erlang:demonitor(Mon, [flush]),
        error(
            {eta_net,
                {kill_timeout, Pid, <<
                    "a process on a killed node did not die within 5s; the node "
                    "cannot be reported gone while one of its processes is still there"
                >>}}
        )
    end.

%% Everything on the wire in either direction is lost with the node.
cancel_touching(Dying) ->
    D = sets:from_list(Dying),
    _ = [
        cancel_pending(From, To)
     || {{chan, From, To}, _Last, _Pending} <- ets:match_object(?CHAN, {{chan, '_', '_'}, '_', '_'}),
        sets:is_element(From, D) orelse sets:is_element(To, D)
    ],
    ok.

-if(?DOCATTRS).
-doc """
Drops the next `K` messages from `From` to `To`. Later messages are not
affected.

Use this function for a fault that a probability cannot select, such as the loss
of the reply to one operation. `From` and `To` are pids or registered names. A
new call for the same channel replaces the earlier count.

Raises `{eta_net, {no_network, drop_next, Text}}` when no network is running.
""".
-endif.
-spec drop_next(dest(), dest(), non_neg_integer()) -> ok.
drop_next(From0, To0, K) ->
    ok = require_running(drop_next),
    true = ets:insert(?CHAN, {{drop_next, normalize(From0), normalize(To0)}, K}),
    ok.

-if(?DOCATTRS).
-doc """
Drops selected messages with the tag `Tag` on the channel from `From` to `To`.

The function lets the next `Skip` messages with the tag `Tag` pass, and then
drops the following `K` messages with that tag. Messages with other tags are not
affected and are not counted. See `set_policy/1` for the definition of a tag.

The count applies to one kind of message. A batch is interleaved on the channel
with acknowledgements and replies, so "drop messages 2 to 4 of this batch" can
only be stated by tag. The loss of a strict subset of one batch differs from the
loss of a whole channel: the receiver may have no gap to detect.

Raises `{eta_net, {no_network, drop_matching, Text}}` when no network is
running.
""".
-endif.
-spec drop_matching(dest(), dest(), term(), non_neg_integer(), non_neg_integer()) -> ok.
drop_matching(From0, To0, Tag, Skip, K) ->
    ok = require_running(drop_matching),
    Key = {drop_matching, normalize(From0), normalize(To0), Tag},
    true = ets:insert(?CHAN, {Key, Skip, K}),
    ok.

-if(?DOCATTRS).
-doc """
Removes every cut and every pending `drop_next/3` and `drop_matching/5`.

The function does not change the following:

- The random policy. To get a perfect network, call `heal_all/0` and
  `set_policy(#{drop_p => 0.0, delay_p => 0.0})`.
- Monitors. A monitor that fired `noconnection` is not restored, as with
  `heal_partition/3`.
- The topology and the connections. A node killed with `kill_node/2` remains
  down.

Raises `{eta_net, {no_network, heal_all, Text}}` when no network is running.
""".
-endif.
-spec heal_all() -> ok.
heal_all() ->
    ok = require_running(heal_all),
    true = ets:match_delete(?CHAN, {{cut, '_', '_'}}),
    true = ets:match_delete(?CHAN, {{node_cut, '_', '_'}}),
    true = ets:match_delete(?CHAN, {{drop_next, '_', '_'}, '_'}),
    true = ets:match_delete(?CHAN, {{drop_matching, '_', '_', '_'}, '_', '_'}),
    ok.

%% ---------------------------------------------------------------------------
%% Observation
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Returns the counters of the network as a map.

| Key | Count |
|---|---|
| `delivered` | Messages that were routed and delivered at once. |
| `delayed` | Messages that were routed and scheduled for a later delivery. |
| `dropped` | Messages dropped by a cut, by `drop_next/3` or `drop_matching/5`, or by the policy, and delayed messages that were cancelled. |
| `cancelled` | Delayed messages that were cancelled by a cut, a partition, a disconnect or a node kill. Each is also counted as `dropped`. |
| `unmanaged` | Sends to a process that the scheduler owns, made by a process that the scheduler was not stepping. See `eta_sched:stepping/0`. |
| `signalled` | Link event messages sent: signals, and `nodeup` and `nodedown` messages. |
| `noconnection` | Synthetic `noconnection` DOWNs fired. |
| `busy` | Sends refused because the link was busy. See `send_nosuspend/3`. |
| `in_flight` | The result of `in_flight/0`. |

Use the counters to check that a run was not vacuous:

- With `dropped` at 0, a lossy policy lost nothing. The run tested the same
  behaviour as a run with a perfect network, and it reports the same `ok`.
- With `signalled` and `noconnection` at 0, a partition reached no process and
  severed no monitor. The run exercised no recovery.
- With `unmanaged` above 0, a part of the run was ordered by real time. No other
  measurement reports this. A send between two processes that the run does not
  own is delivered unchanged and is not counted.

Raises `{eta_net, {no_network, stats, Text}}` when no network is running.
""".
-endif.
-spec stats() -> #{atom() => non_neg_integer()}.
stats() ->
    ok = require_running(stats),
    maps:from_list(
        [{C, ets:lookup_element(?STATE, C, 2)} || C <- ?COUNTERS] ++
            [{in_flight, in_flight()}]
    ).

-if(?DOCATTRS).
-doc """
Returns the number of messages that are delayed and not yet delivered.

A result above 0 at the end of a run means that a delayed message was not
delivered. The usual cause is that the run ended, or the destination died,
before the deadline. The count corresponds to the stray timers of `eta_time`.

Raises `{eta_net, {no_network, in_flight, Text}}` when no network is running.
""".
-endif.
-spec in_flight() -> non_neg_integer().
in_flight() ->
    ok = require_running(in_flight),
    Now = now_ms(),
    lists:sum([
        length([A || {A, _Ref} <- Pending, A > Now])
     || {{chan, _, _}, _Last, Pending} <- ets:match_object(?CHAN, {{chan, '_', '_'}, '_', '_'})
    ]).

%% ---------------------------------------------------------------------------
%% Routing
%% ---------------------------------------------------------------------------

route(From, Dest, Msg) ->
    route(From, Dest, Msg, tag(Msg)).

%% What this send is, as far as the schedule is concerned.
%%
%% - `scheduled` — routed, faulted, and allowed to draw from the fault schedule.
%% - `escaped` — the schedule did not order it, but it targets a process the
%%   scheduler owns. Delivered untouched, draws nothing, and **counted**: it is
%%   enough on its own to make a trace diverge, and nothing else reports it.
%% - `foreign` — neither end belongs to the run. Delivered untouched, draws
%%   nothing, not counted.
%%
%% During a step one process runs and every other one the scheduler owns is
%% suspended, so a send from anything else happened at a moment wall-clock timing
%% chose. That is exact, where asking "is the sender registered with the
%% scheduler" would be both weaker (a process can be owned and still running
%% loose) and stale.
%%
%% `foreign` exists because this module is global to the VM, so every transformed
%% module in it sends through here — including a leftover system from an earlier
%% test file. Such a send cannot change what is runnable, so counting it would
%% fire a diagnostic the reader cannot act on. It still draws nothing: a
%% stranger's message must not shift the fault schedule.
%%
%% No step in progress is not off-schedule: the driver runs between steps, and
%% outside a run there is no scheduler at all.
classify(From, Dest) ->
    case eta_sched:stepping() of
        undefined -> scheduled;
        From -> scheduled;
        Stepping -> escaped_or_foreign(Dest, Stepping)
    end.

%% "Does the scheduler own the destination", without asking it: mid-step every
%% process it owns except the stepped one is suspended.
escaped_or_foreign(Dest, Stepping) when Dest =:= Stepping ->
    escaped;
escaped_or_foreign(Dest, _Stepping) ->
    case erlang:process_info(Dest, status) of
        {status, suspended} -> escaped;
        _ -> foreign
    end.

%% `Tag` is what a policy scopes on and what the log records. Passed rather than
%% derived so `cast/2` and `reply/2` can name the payload, not OTP's envelope.
route(From, Dest, Msg, Tag) ->
    case classify(From, Dest) of
        scheduled ->
            ok = autoconnect(From, Dest),
            route_managed(From, Dest, Msg, Tag);
        escaped ->
            bump(unmanaged),
            erlang:send(Dest, Msg);
        foreign ->
            erlang:send(Dest, Msg)
    end.

route_managed(From, Dest, Msg, Tag) ->
    case decide(From, Dest, Tag) of
        drop ->
            bump(dropped),
            _ = eta_log:log({net, dropped, Dest, Tag}),
            Msg;
        {send, Delay} ->
            schedule(From, Dest, Msg, Tag, Delay)
    end.

%% The order matters: a cut is absolute, a targeted drop is next, and only then
%% does the random policy get a say — and only for traffic in its scope.
decide(From, Dest, Tag) ->
    case is_cut(From, Dest) of
        true ->
            drop;
        false ->
            case take_drop_next(From, Dest) orelse take_drop_matching(From, Dest, Tag) of
                true -> drop;
                false -> roll(From, Dest, Tag)
            end
    end.

is_cut(From, Dest) ->
    ets:member(?CHAN, {cut, From, Dest}) orelse node_cut(From, Dest).

%% A node-level cut survives a process restart, which a pid-level one cannot: the
%% replacement is on the same node, so it is still on the wrong side of the
%% partition. That is the behaviour a partition actually has.
node_cut(From, Dest) ->
    case {node_of(From), node_of(Dest)} of
        {undefined, _} -> false;
        {_, undefined} -> false;
        {A, B} -> ets:member(?CHAN, {node_cut, A, B})
    end.

take_drop_matching(From, Dest, Tag) ->
    Key = {drop_matching, From, Dest, Tag},
    case ets:lookup(?CHAN, Key) of
        [{Key, Skip, K}] when Skip > 0 ->
            true = ets:insert(?CHAN, {Key, Skip - 1, K}),
            false;
        [{Key, 0, K}] when K > 0 ->
            true = ets:insert(?CHAN, {Key, 0, K - 1}),
            true;
        _ ->
            false
    end.

take_drop_next(From, Dest) ->
    Key = {drop_next, From, Dest},
    case ets:lookup(?CHAN, Key) of
        [{Key, K}] when K > 0 ->
            true = ets:insert(?CHAN, {Key, K - 1}),
            true;
        _ ->
            false
    end.

%% Draws from the RNG exactly once for an in-scope message, and a second time only
%% when the delay branch is taken.
%%
%% Two things draw nothing at all, and both are load-bearing rather than
%% optimisations.
%%
%% **Out-of-scope traffic**, so narrowing the scope does not shift the schedule
%% for the traffic still inside it.
%%
%% **A perfect policy.** With both probabilities at zero there is no decision to
%% make, and making it anyway costs a draw — which is how the fault schedule stops
%% being a function of the seed. A cluster that must sync before it can survive
%% faults starts perfect and turns loss on at the end of `init/2`, and everything
%% it sends while starting up runs on the *real* scheduler, varying in order and
%% count from run to run. Charging those messages for a decision that could only
%% ever come out one way left the generator at a different offset on every run:
%% same seed, different drops, and a trace that diverged the moment the first
%% fault landed. Measured on a 3-member registry, this was 5 distinct schedules in
%% 5 runs of one seed.
%%
%% The rule this leaves is worth stating whole: **the generator advances only when
%% the answer could have been otherwise.**
roll(From, Dest, Tag) ->
    Policy = policy(),
    DropP = maps:get(drop_p, Policy),
    DelayP = maps:get(delay_p, Policy),
    case faultable(From, Dest, Tag) of
        false ->
            {send, 0};
        true ->
            case draw() of
                P when P < DropP -> drop;
                P when P < DropP + DelayP ->
                    {send, max(1, trunc(draw() * maps:get(max_delay, Policy)))};
                _ ->
                    {send, 0}
            end
    end.

%% Whether this message is one the policy in force could actually do something to.
%% Three conditions, each load-bearing somewhere else in this module: the policy
%% has to be able to fault at all, the send has to cross a simulated link, and it
%% has to be in scope.
%%
%% Shared with `call/3`, which is why it is a function rather than a guard inside
%% `roll/3`: "would the network interfere with this?" is exactly the question that
%% decides whether a synchronous call is safe to let through.
faultable(From, Dest, Tag) ->
    Policy = policy(),
    maps:get(drop_p, Policy) + maps:get(delay_p, Policy) > 0.0 andalso
        crosses_link(From, Dest) andalso
        in_scope(maps:get(scope, Policy), From, Dest, Tag).

in_scope(all, _From, _Dest, _Tag) -> true;
in_scope({tags, Tags}, _From, _Dest, Tag) -> lists:member(Tag, Tags);
in_scope(Fun, From, Dest, Tag) when is_function(Fun, 3) -> Fun(From, Dest, Tag).

%% Read-modify-write on the RNG, which is safe because only one process runs at a
%% time under `eta_sched` — and outside a run, only whoever is driving by hand.
draw() ->
    {P, Next} = rand:uniform_s(ets:lookup_element(?STATE, rand, 2)),
    true = ets:insert(?STATE, {rand, Next}),
    P.

%% Where the ordering guarantee lives. A delivery lands at
%% `max(Now + Delay, Last + 1)`, so it can never overtake one already scheduled on
%% the same channel — and a message that needs no delay, on a channel with nothing
%% outstanding, is sent directly, so a perfect network behaves exactly as no
%% network does.
schedule(From, Dest, Msg, Tag, Delay) ->
    %% A delayed message to a process that has already exited arms no timer.
    %% The message would reach nobody, and `eta_time` would count its deadline
    %% as a stray timer: a deadline that can make no process runnable. A reply
    %% to a caller that was killed is such a message. `eta_time:forget/1`
    %% removes the timers of a process that exits after the message was sent.
    case ets:member(?DEAD, Dest) of
        true -> Msg;
        false -> schedule_live(From, Dest, Msg, Tag, Delay)
    end.

schedule_live(From, Dest, Msg, Tag, Delay) ->
    Now = now_ms(),
    {Last0, Pending} = channel(From, Dest, Now),
    Link = link_key(From, Dest),
    Last = max(Last0, link_last(Link, Now)),
    case max(Now + Delay, Last + 1) of
        At when At =< Now ->
            deliver(Dest, Msg);
        At ->
            Ref = eta_time:send_after(At - Now, Dest, Msg),
            true = ets:insert(?CHAN, {{chan, From, Dest}, At, [{At, Ref} | Pending]}),
            ok = put_link_last(Link, At),
            bump(delayed),
            _ = eta_log:log({net, {delayed, At - Now}, Dest, Tag}),
            Msg
    end.

%% The node-to-node link a message crosses, for the link-wide ordering guarantee in
%% the module doc. `none` for anything that doesn't cross one.
link_key(From, Dest) ->
    case {placement(From), placement(Dest)} of
        {{A, _}, {B, _}} when A =/= B -> {link_last, A, B};
        _ -> none
    end.

%% The last delivery scheduled on a link, or one before `Now` if none is pending.
link_last(none, Now) ->
    Now - 1;
link_last(Key, Now) ->
    case ets:lookup(?CHAN, Key) of
        [{_, At}] -> At;
        [] -> Now - 1
    end.

put_link_last(none, _At) ->
    ok;
put_link_last(Key, At) ->
    true = ets:insert(?CHAN, {Key, At}),
    ok.

%% Milliseconds on whichever clock is running.
%%
%% `eta_time` already delegates `send_after/3` and `cancel_timer/1` to `erlang`
%% when no virtual clock exists, so a delay outside a run is a real one — which is
%% what a network simulator driven by hand should do, and what lets a harness that
%% predates `eta_run` use this module unchanged. Inside a run there is always a
%% virtual clock and the delay costs nothing.
%%
%% The one thing that is exact only on the virtual clock is `channel/3`'s
%% deduction that a delivery at or before `Now` has already happened: a real timer
%% fires *around* its deadline rather than at it. The consequence is a
%% millisecond of slack in the ordering clamp, which no protocol can observe,
%% rather than a reordering.
now_ms() ->
    case eta_time:running() of
        true -> eta_time:now_ms();
        false -> erlang:monotonic_time(millisecond)
    end.

deliver(Dest, Msg) ->
    bump(delivered),
    erlang:send(Dest, Msg).

%% A channel's last scheduled delivery and whatever is still outstanding.
%%
%% "Outstanding" needs no bookkeeping beyond the clock: deliveries are timers, the
%% clock only moves by firing everything due, and an armed delivery is always at a
%% strictly future time — so anything at or before `Now` has already been
%% delivered. That is why the clamp is `Last + 1` rather than `Last`.
channel(From, Dest, Now) ->
    case ets:lookup(?CHAN, {chan, From, Dest}) of
        [{_, Last, Pending}] -> {Last, [P || P = {At, _} <- Pending, At > Now]};
        [] -> {Now - 1, []}
    end.

cancel_pending(From, Dest) ->
    case ets:lookup(?CHAN, {chan, From, Dest}) of
        [{_, _Last, Pending}] ->
            Now = now_ms(),
            Cancelled = [R || {At, R} <- Pending, At > Now, eta_time:cancel_timer(R) =/= false],
            true = ets:delete(?CHAN, {chan, From, Dest}),
            lists:foreach(
                fun(_) ->
                    bump(dropped),
                    bump(cancelled)
                end,
                Cancelled
            ),
            length(Cancelled);
        _ ->
            0
    end.

bump(Counter) ->
    _ = ets:update_counter(?STATE, Counter, 1),
    ok.

%% The message's leading element, which is what a policy scopes on and what the
%% log records. Enough to read a protocol trace without holding every payload.
tag(Msg) when is_tuple(Msg), tuple_size(Msg) > 0 -> element(1, Msg);
tag(Msg) when is_atom(Msg) -> Msg;
tag(_) -> unknown.
