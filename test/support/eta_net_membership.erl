-module(eta_net_membership).

%% Node identity and membership as a system under simulation writes them: bare
%% and qualified, in function bodies and in guards. Every function here is
%% something `eta_transform` has to point at `eta_net`, or a guard it has to
%% rewrite so that it compares against the simulated node rather than the real
%% one.

-include_lib("eta/include/eta.hrl").

-export([
    whoami/0,
    whoami_qualified/0,
    node_of/1,
    peers/0,
    peers_with_this/0,
    alive/0,
    subscribe/0,
    subscribe_with_reason/0,
    connect/1,
    disconnect/1,
    ping/1,
    nosuspend/2,
    nosuspend_noconnect/2,
    local_by_function_guard/1,
    local_by_case_guard/1,
    local_by_if/1,
    local_by_receive_guard/0,
    local_by_fun_guard/0,
    local_by_try_guard/1,
    nested/1
]).

whoami() -> node().

whoami_qualified() -> erlang:node().

node_of(Pid) -> node(Pid).

peers() -> nodes().

peers_with_this() -> erlang:nodes([this, visible]).

alive() -> is_alive().

subscribe() -> net_kernel:monitor_nodes(true).

subscribe_with_reason() -> net_kernel:monitor_nodes(true, [nodedown_reason]).

connect(Node) -> net_kernel:connect_node(Node).

disconnect(Node) -> disconnect_node(Node).

ping(Node) -> net_adm:ping(Node).

nosuspend(Dest, Msg) -> erlang:send_nosuspend(Dest, Msg).

nosuspend_noconnect(Dest, Msg) -> erlang:send_nosuspend(Dest, Msg, [noconnect]).

%% The guard forms. Each answers `local` for the caller's own node.
local_by_function_guard(N) when N =:= node() -> local;
local_by_function_guard(_) -> remote.

local_by_case_guard(N) ->
    case N of
        M when M =:= node() -> local;
        _ -> remote
    end.

local_by_if(N) ->
    if
        N =:= node() -> local;
        true -> remote
    end.

%% Reads one `{node, N}` message from the caller's own mailbox.
local_by_receive_guard() ->
    receive
        {node, N} when N =:= node() -> local;
        {node, _} -> remote
    after 1000 -> timeout
    end.

local_by_fun_guard() ->
    fun
        (N) when N =:= node() -> local;
        (_) -> remote
    end.

local_by_try_guard(N) ->
    try N of
        M when M =:= erlang:node() -> local;
        _ -> remote
    catch
        _:_ -> error
    end.

%% A guarded case inside a guarded function, so both rewrites have to compose.
nested(N) when N =/= node() ->
    case N of
        _ when node() =:= N -> impossible;
        _ -> remote
    end;
nested(_) ->
    local.
