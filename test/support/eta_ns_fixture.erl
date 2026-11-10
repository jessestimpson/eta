-module(eta_ns_fixture).

%% The calls that name things — registered names, named ETS tables,
%% `persistent_term` keys — and `rpc`, written as a system writes them, so the
%% transform has to point each at a node's own namespace. See `eta_ns`.

-include_lib("eta/include/eta.hrl").

-export([
    reg/1,
    where/1,
    names/0,
    my_name/0,
    stack_size/0,
    send_named/2,
    named_timer/3,
    table/1,
    read/1,
    read_all/1,
    pt_put/2,
    pt_get/1,
    whoami/0,
    rpc/4,
    rpc_cast/4,
    erpc/4,
    erpc_fun/2,
    raise/1,
    stall/0,
    spawn_on/2,
    spawn_fun_on/2,
    spawn_monitor_on/1,
    report_node/1,
    monitor_name/2
]).

reg(Name) -> register(Name, self()).

where(Name) -> whereis(Name).

names() -> registered().

my_name() -> process_info(self(), registered_name).

stack_size() -> element(2, erlang:process_info(self(), stack_size)).

send_named(Dest, Msg) -> Dest ! Msg.

named_timer(Ms, Name, Msg) -> erlang:send_after(Ms, Name, Msg).

table(Name) ->
    Name = ets:new(Name, [named_table, public]),
    true = ets:insert(Name, {k, node()}),
    ok.

read(Name) -> ets:lookup(Name, k).

read_all(Name) -> ets:tab2list(Name).

pt_put(Key, Value) -> persistent_term:put(Key, Value).

pt_get(Key) -> persistent_term:get(Key, undefined).

whoami() -> node().

rpc(Node, M, F, A) -> rpc:call(Node, M, F, A, 1000).

rpc_cast(Node, M, F, A) -> rpc:cast(Node, M, F, A).

erpc(Node, M, F, A) -> erpc:call(Node, M, F, A, 1000).

erpc_fun(Node, Fun) -> erpc:call(Node, Fun).

raise(How) ->
    case How of
        throw -> throw(thrown);
        error -> error(broken);
        exit -> exit(gone)
    end.

stall() ->
    receive
        never -> ok
    end.

%% The distributed spawns. `spawn_on/2` is written bare, as `locks` writes its
%% watcher spawn, so it goes through the auto-imported path of the transform.
spawn_on(Node, To) -> spawn(Node, ?MODULE, report_node, [To]).

spawn_fun_on(Node, To) -> erlang:spawn(Node, fun() -> report_node(To) end).

%% Waits for the child to end, and answers with why.
spawn_monitor_on(Node) ->
    {_Pid, Ref} = erlang:spawn_monitor(Node, ?MODULE, whoami, []),
    receive
        {'DOWN', Ref, process, _, Reason} -> Reason
    end.

report_node(To) -> To ! {node_of, self(), node()}.

%% Monitors `{Name, Node}` and answers with the DOWN's object and reason.
monitor_name(Name, Node) ->
    Ref = erlang:monitor(process, {Name, Node}),
    receive
        {'DOWN', Ref, process, Object, Reason} -> {Object, Reason}
    after 1000 -> no_down
    end.
