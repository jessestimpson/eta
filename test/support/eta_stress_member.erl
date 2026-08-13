-module(eta_stress_member).
-behaviour(gen_statem).

%% A member of a heartbeat ticker mesh — the system process for `eta_stress`.
%%
%% Each member ticks on a `state_timeout`, broadcasting its counter to every
%% peer in one step (the fan-out the schedule alone cannot produce), and each
%% tick is followed by a busy period whose own deadline cancels the tick's and
%% is cancelled in turn. That puts every `state_timeout` rule to work at volume:
%% arming in `init/1`, rearming with `keep_state`, and cancellation by state
%% change — both directions — hundreds of times per run.
%%
%% Members monitor their peers with bare `monitor(process, Peer)` so a
%% partition or node kill produces the `noconnection` DOWNs real distribution
%% would, and the invariant in `eta_stress` checks those reasons the same way
%% `eta_net_faults` does. All state goes to ETS so `check/1` reads it without
%% asking a suspended process anything.
%%
%% Started unlinked. A linked member would take the driver down the first time a
%% node was killed, which is not a property of the system under test — same
%% reason `eta_net_node` is started with `gen_server:start/3`.

-include_lib("eta/include/eta.hrl").

-eta_observe(all).

-export([start/2, stop/1, watch/1, tick/1]).
-export([callback_mode/0, init/1, idle/3, busy/3, terminate/3]).

-define(TICK_MS, 50).
-define(BUSY_MS, 30).

-record(data, {
    tab :: ets:tid(),
    name :: atom(),
    counter = 0 :: non_neg_integer(),
    %% peer pid => monitor ref. A monitor is created once and re-created only
    %% after it has fired, which is what a real system does with a terminal DOWN.
    watched = #{} :: #{pid() => reference()}
}).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

%% Unlinked and unnamed — see the module doc. Peers are published to the shared
%% ETS table by the harness after all members are started, and read on demand.
start(Tab, Name) ->
    gen_statem:start(?MODULE, {Tab, Name}, []).

stop(Pid) ->
    gen_statem:stop(Pid).

%% Force a tick immediately, rather than waiting for the deadline. Duplicates
%% the state-timeout path so an operation can inject extra activity at a point
%% the seed chose.
tick(Pid) ->
    gen_statem:cast(Pid, force_tick).

%% Re-create monitors that have fired. Called as an operation so a monitor
%% retired by a `noconnection` DOWN gets re-armed, which is what makes a second
%% partition observable.
watch(Pid) ->
    gen_statem:cast(Pid, watch).

%% ---------------------------------------------------------------------------
%% gen_statem
%% ---------------------------------------------------------------------------

callback_mode() ->
    state_functions.

init({Tab, Name}) ->
    ok = ?ETA_LABEL({member, Name}),
    Data = #data{tab = Tab, name = Name},
    %% The first tick deadline is armed here, so a mesh that is started and then
    %% left alone still produces traffic — which is the only reason anything
    %% happens at all without an operation driving it.
    {ok, idle, Data, [{state_timeout, ?TICK_MS, tick}]}.

%% ---------------------------------------------------------------------------
%% idle — waiting for the next tick deadline
%% ---------------------------------------------------------------------------

%% The deadline fires: increment, fan out to every peer, and go busy. The state
%% change cancels this deadline and the action arms the busy one.
idle(state_timeout, tick, Data) ->
    do_tick(Data);

%% Forced by an operation. Same path, different trigger.
idle(cast, force_tick, Data) ->
    do_tick(Data);

%% A peer's tick arrived: record it and rearm. The `keep_state` does *not*
%% cancel the deadline — the action replaces it, which is the distinction the
%% whole heartbeat mechanism in `eta_elect` rests on.
idle(cast, {tick, Peer, Count}, Data) ->
    ok = record(Data, {tick, Peer, Count}),
    {keep_state, Data, [{state_timeout, ?TICK_MS, tick}]};

%% Re-create monitors that have fired. Idempotent: a monitor still live is left
%% alone, which is what a real system does.
idle(cast, watch, Data) ->
    {keep_state, rearm_monitors(Data), [{state_timeout, ?TICK_MS, tick}]};

idle(info, {'DOWN', Ref, process, _Pid, Reason}, Data) ->
    {keep_state, handle_down(Ref, Reason, Data), [{state_timeout, ?TICK_MS, tick}]};
idle(info, {nodedown, Node}, Data) ->
    ok = record(Data, {nodedown, Node}),
    {keep_state, Data, [{state_timeout, ?TICK_MS, tick}]};
idle(info, {nodeup, Node}, Data) ->
    ok = record(Data, {nodeup, Node}),
    {keep_state, Data, [{state_timeout, ?TICK_MS, tick}]}.

%% ---------------------------------------------------------------------------
%% busy — processing a tick; the busy deadline is the only one running
%% ---------------------------------------------------------------------------

%% Processing done: go back to idle. The state change cancels the busy deadline
%% and the action arms the tick one.
busy(state_timeout, done, Data) ->
    {next_state, idle, Data, [{state_timeout, ?TICK_MS, tick}]};

%% A forced tick while busy: ignore it. The member is already working and will
%% tick again when it returns to idle.
busy(cast, force_tick, _Data) ->
    keep_state_and_data;

%% A peer's tick arrived while busy: record it and rearm the busy deadline.
busy(cast, {tick, Peer, Count}, Data) ->
    ok = record(Data, {tick, Peer, Count}),
    {keep_state, Data, [{state_timeout, ?BUSY_MS, done}]};

busy(cast, watch, Data) ->
    {keep_state, rearm_monitors(Data), [{state_timeout, ?BUSY_MS, done}]};

busy(info, {'DOWN', Ref, process, _Pid, Reason}, Data) ->
    {keep_state, handle_down(Ref, Reason, Data), [{state_timeout, ?BUSY_MS, done}]};
busy(info, {nodedown, Node}, Data) ->
    ok = record(Data, {nodedown, Node}),
    {keep_state, Data, [{state_timeout, ?BUSY_MS, done}]};
busy(info, {nodeup, Node}, Data) ->
    ok = record(Data, {nodeup, Node}),
    {keep_state, Data, [{state_timeout, ?BUSY_MS, done}]}.

terminate(_Reason, _State, _Data) ->
    ok.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

%% The tick: increment, fan out to every peer, and go busy. The state change
%% cancels the idle deadline and the action arms the busy one.
do_tick(Data = #data{name = Name, counter = C}) ->
    C1 = C + 1,
    ok = broadcast(Data, {tick, Name, C1}),
    {next_state, busy, Data#data{counter = C1}, [{state_timeout, ?BUSY_MS, done}]}.

%% Fan-out: every peer gets the message inside one scheduler step. This is the
%% state `README.md` says the schedule alone cannot produce — a
%% partially-delivered broadcast is one network drop away.
broadcast(#data{tab = Tab, name = Name}, Msg) ->
    lists:foreach(
        fun(Peer) -> gen_statem:cast(Peer, Msg) end,
        peers_of(Tab, Name)
    ),
    ok.

%% Re-create monitors for peers whose previous monitor has fired. A monitor is
%% terminal, so the peer comes out of the watch set when it fires and a later
%% `watch` re-arms it.
rearm_monitors(Data = #data{tab = Tab, name = Name, watched = Watched}) ->
    Watched1 = lists:foldl(
        fun(Peer, Acc) ->
            case maps:is_key(Peer, Acc) of
                true -> Acc;
                false -> Acc#{Peer => monitor(process, Peer)}
            end
        end,
        Watched,
        peers_of(Tab, Name)
    ),
    Data#data{watched = Watched1}.

handle_down(Ref, Reason, Data = #data{watched = Watched}) ->
    %% Find which peer this monitor was for, so the event names it.
    Peer = maps:fold(
        fun(P, R, Acc) -> case R =:= Ref of true -> P; false -> Acc end end,
        undefined,
        Watched
    ),
    Watched1 = maps:remove(Peer, Watched),
    ok = record(Data, {down, Peer, Reason}),
    Data#data{watched = Watched1}.

record(#data{tab = Tab, name = Name}, Event) ->
    _ = ?ETA_LOG(Event),
    Seq = ets:update_counter(Tab, {seq, Name}, {3, 1}, {seq, Name, 0}),
    ets:insert(Tab, {{event, Name, Seq}, Event}),
    ok.

%% Peers are published to the table by the harness after all members are
%% started, because no member can know the pids of members started after it.
%% Read on demand rather than stored, so a `watch` or `broadcast` always sees
%% the full set.
peers_of(Tab, Name) ->
    case ets:lookup(Tab, {peers, Name}) of
        [{_, Peers}] -> Peers;
        [] -> []
    end.
