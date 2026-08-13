-module(eta_stress).

%% A stress system under test for `eta`'s determinism claim.
%%
%% The existing SUTs each exercise one surface: `eta_2pc` drives synchronous
%% calls and virtual timeouts; `eta_elect` drives `state_timeout` through every
%% gen_statem rule; `eta_net_faults` drives link events across simulated nodes.
%% This one drives all of them at once and at volume, because the thing that
%% makes a determinism bug likely to surface is not the *variety* of mechanisms
%% but the *throughput* of state-timeout firings, fan-out casts, and link-event
%% deliveries happening in the same run.
%%
%% The system is a **ticker mesh**: N members on separate simulated nodes, each
%% ticking on a `state_timeout` and broadcasting its counter to every peer in one
%% step. Every tick is followed by a busy period whose own deadline cancels the
%% tick's and is cancelled in turn, so a run of 20 operations produces hundreds
%% of state-timeout arming/cancellation/rearming cycles. Members monitor their
%% peers, so partitions and node kills produce `noconnection` DOWNs, and the
%% invariant checks those reasons the same way `eta_net_faults` does.
%%
%% There is no planted bug. The SUT is correct, and the invariant always holds.
%% The assertion the test makes is that the same seed produces one result — and
%% a run this dense is the one most likely to find a drift in `eta` itself,
%% because every surface where nondeterminism can leak is working hard at once.

-behaviour(eta_harness).

-export([init/2, processes/1, generate/2, execute/2, check/1, terminate/1, labels/1]).

-define(MEMBERS, 4).

%% ---------------------------------------------------------------------------
%% eta_harness
%% ---------------------------------------------------------------------------

init(Seed, Config) ->
    N = maps:get(members, Config, ?MEMBERS),
    Tab = ets:new(eta_stress, [public, set]),

    Names = [member_name(I) || I <- lists:seq(1, N)],
    Members = [
        {Name, start_member(Tab, Name)}
     || Name <- Names
    ],

    %% Publish peer pids to ETS. No member can know the pids of members started
    %% after it, so this happens after all are started — the same shape as
    %% `eta_net_faults`' `introduce/2`.
    ok = introduce(Tab, Members),

    ok = topology(Members),

    {ok, #{
        tab => Tab,
        members => Members,
        names => Names,
        killed => [],
        seed => Seed
    }}.

%% The order is part of the contract — ids are assigned in registration order —
%% so it is built the same way every time regardless of what has died.
processes(#{members := Members}) ->
    [P || {_Name, P} <- Members].

labels(#{members := Members}) ->
    maps:from_list([{P, {member, Name}} || {Name, P} <- Members]).

%% Mostly traffic, with faults rare enough that a run has something to fault
%% and frequent enough to exercise delivery ordering. Same distribution shape as
%% `eta_net_faults`: pings dominate, faults are the minority.
generate(#{names := Names}, Rand0) ->
    N = length(Names),
    {Roll, Rand1} = rand:uniform_s(Rand0),
    if
        Roll < 0.45 -> one(fun(A) -> {tick, A} end, N, Rand1);
        Roll < 0.65 -> one(fun(A) -> {watch, A} end, N, Rand1);
        Roll < 0.80 -> two(fun(A, B) -> {partition, A, B} end, N, Rand1);
        Roll < 0.95 -> two(fun(A, B) -> {heal, A, B} end, N, Rand1);
        true -> one(fun(A) -> {kill, A} end, N, Rand1)
    end.

execute({tick, A}, Sut) ->
    eta_stress_member:tick(member(A, Sut)),
    Sut;
execute({watch, A}, Sut) ->
    eta_stress_member:watch(member(A, Sut)),
    Sut;
execute({partition, A, B}, Sut) ->
    case eta_net:running() of
        true -> ok = eta_net:partition(node_name(A), node_name(B), #{signal => nodedown});
        false -> ok
    end,
    Sut;
execute({heal, A, B}, Sut) ->
    case eta_net:running() of
        true -> ok = eta_net:heal_partition(node_name(A), node_name(B), #{signal => nodeup});
        false -> ok
    end,
    Sut;
execute({kill, A}, Sut = #{killed := Killed}) ->
    case eta_net:running() of
        true -> ok = eta_net:kill_node(node_name(A), #{signal => nodedown});
        false -> ok
    end,
    Sut#{killed := lists:usort([A | Killed])}.

%% The asymmetry `kill_node/2` exists to produce. Read straight out of ETS: an
%% invariant that asked a process anything would be asking a suspended one.
check(#{tab := Tab, members := Members}) ->
    Names = [Name || {Name, _} <- Members],
    first_violation(Names, Tab).

terminate(Sut = #{tab := Tab}) ->
    lists:foreach(fun stop/1, processes(Sut)),
    catch ets:delete(Tab),
    ok.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

%% Each member is placed on its own simulated node, so every tick broadcast
%% crosses links that can be broken. Inert when no network is running.
topology(Members) ->
    case eta_net:running() of
        false ->
            ok;
        true ->
            lists:foreach(
                fun({Name, Pid}) ->
                    ok = eta_net:place(node_name(Name), [Pid])
                end,
                Members
            )
    end.

%% Publish each member's peer pids to the shared ETS table. Members read this
%% on demand rather than storing it, so a `watch` or `broadcast` always sees the
%% full set.
introduce(Tab, Members) ->
    lists:foreach(
        fun({Name, _Pid}) ->
            Peers = [P || {N, P} <- Members, N =/= Name],
            true = ets:insert(Tab, {{peers, Name}, Peers})
        end,
        Members
    ),
    ok.

first_violation([], _Tab) ->
    ok;
first_violation([Name | Rest], Tab) ->
    Events = events(Tab, Name),
    case [R || {down, _Peer, R} <- Events, R =/= noconnection, R =/= noproc] of
        [] ->
            first_violation(Rest, Tab);
        [Reason | _] ->
            {violation, #{
                property => remote_monitors_see_noconnection,
                detail => <<
                    "a process on another simulated node learned the real exit "
                    "reason of a process that died with its node"
                >>,
                who => Name,
                reason => Reason,
                events => Events
            }}
    end.

events(Tab, Name) ->
    [
        E
     || {{event, N, _Seq}, E} <- lists:sort(ets:tab2list(Tab)),
        N =:= Name
    ].

start_member(Tab, Name) ->
    {ok, Pid} = eta_stress_member:start(Tab, Name),
    Pid.

member(I, #{names := Names, members := Members}) ->
    Name = lists:nth(I, Names),
    proplists:get_value(Name, Members).

member_name(I) ->
    list_to_atom("eta_stress_" ++ integer_to_list(I)).

node_name(Name) when is_atom(Name) ->
    list_to_atom("node_" ++ atom_to_list(Name));
node_name(I) when is_integer(I) ->
    node_name(member_name(I)).

%% Two distinct indexes, so a partition never names one member twice.
two(Make, N, Rand0) ->
    {A, Rand1} = rand:uniform_s(N, Rand0),
    {Off, Rand2} = rand:uniform_s(N - 1, Rand1),
    {Make(A, 1 + ((A - 1 + Off) rem N)), Rand2}.

one(Make, N, Rand0) ->
    {A, Rand1} = rand:uniform_s(N, Rand0),
    {Make(A), Rand1}.

stop(Pid) ->
    catch gen_statem:stop(Pid),
    ok.
