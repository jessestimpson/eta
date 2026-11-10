-module(eta_rpc).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
`rpc` and `erpc` between simulated nodes.

A real `rpc:call(Node, M, F, A)` runs `M:F(A)` in a process on `Node` and sends
the result back. Between simulated nodes there is no `Node` for the VM to reach,
so `eta_transform` points these calls here, and this module does the same thing
inside the simulation:

1. It connects to `Node`, as `rpc` does, and fails as `rpc` does if it can't.
2. It spawns a worker, places it on `Node`, and sends it the request over the
   simulated network. The worker runs on `Node`: its `node()` is `Node` and its
   names are `Node`'s (see `eta_ns`).
3. The worker exits with the result as its reason, and the caller, which
   monitored it before sending the request, waits for the `DOWN` on the virtual
   clock.

The request can be dropped, delayed or cut like any other message. The result
comes back as `erpc`'s does, in the exit of the process that ran the call, so it
arrives with the `DOWN` or not at all: a partition while the call is out ends it
the way a lost connection does, and a call can't learn that its worker finished
and then wait forever for a result the partition swallowed.

| What happened | `rpc:call` | `erpc:call` |
|---|---|---|
| Returned `V` | `V` | `V` |
| Threw `T` | `T` | throws `T` |
| Raised error `R` | `{badrpc, {'EXIT', {R, Stack}}}` | `error({exception, R, Stack})` |
| Exited `R` | `{badrpc, {'EXIT', R}}` | `exit({exception, R})` |
| No connection, or lost mid-call | `{badrpc, nodedown}` | `error({erpc, noconnection})` |
| Timed out | `{badrpc, timeout}` | `error({erpc, timeout})` |

A timed-out worker is killed, so a late result never reaches the caller.

A call from a process on no simulated node, or to a node the network doesn't know,
is the real `rpc` or `erpc` call.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    call/4,
    call/5,
    cast/4,
    erpc_call/2,
    erpc_call/3,
    erpc_call/4,
    erpc_call/5,
    erpc_cast/2,
    erpc_cast/4
]).

-export([worker/2]).

%% ---------------------------------------------------------------------------
%% rpc
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "`rpc:call/4`. See the module doc.".
-endif.
-spec call(node(), module(), atom(), [term()]) -> term().
call(Node, M, F, A) ->
    call(Node, M, F, A, infinity).

-if(?DOCATTRS).
-doc "`rpc:call/5`. See the module doc.".
-endif.
-spec call(node(), module(), atom(), [term()], timeout()) -> term().
call(Node, M, F, A, Timeout) ->
    case simulated(Node) of
        false ->
            rpc:call(Node, M, F, A, Timeout);
        true ->
            case run(Node, {M, F, A}, Timeout) of
                {ok, Value} -> Value;
                {raise, throw, Thrown, _} -> Thrown;
                {raise, exit, Reason, _} -> {badrpc, {'EXIT', Reason}};
                {raise, error, Reason, Stack} -> {badrpc, {'EXIT', {Reason, Stack}}};
                {down, Reason} -> {badrpc, {'EXIT', Reason}};
                nodedown -> {badrpc, nodedown};
                timeout -> {badrpc, timeout}
            end
    end.

-if(?DOCATTRS).
-doc "`rpc:cast/4`: the request is sent and nothing waits for it.".
-endif.
-spec cast(node(), module(), atom(), [term()]) -> true.
cast(Node, M, F, A) ->
    case simulated(Node) of
        false ->
            rpc:cast(Node, M, F, A);
        true ->
            _ = start(Node, {M, F, A}, none),
            true
    end.

%% ---------------------------------------------------------------------------
%% erpc
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "`erpc:call/2`. See the module doc.".
-endif.
-spec erpc_call(node(), fun(() -> term())) -> term().
erpc_call(Node, Fun) ->
    erpc_call(Node, Fun, infinity).

-if(?DOCATTRS).
-doc "`erpc:call/3`. See the module doc.".
-endif.
-spec erpc_call(node(), fun(() -> term()), timeout()) -> term().
erpc_call(Node, Fun, Timeout) when is_function(Fun, 0) ->
    case simulated(Node) of
        false -> erpc:call(Node, Fun, Timeout);
        true -> erpc_result(run(Node, Fun, Timeout))
    end.

-if(?DOCATTRS).
-doc "`erpc:call/4`. See the module doc.".
-endif.
-spec erpc_call(node(), module(), atom(), [term()]) -> term().
erpc_call(Node, M, F, A) ->
    erpc_call(Node, M, F, A, infinity).

-if(?DOCATTRS).
-doc "`erpc:call/5`. See the module doc.".
-endif.
-spec erpc_call(node(), module(), atom(), [term()], timeout()) -> term().
erpc_call(Node, M, F, A, Timeout) ->
    case simulated(Node) of
        false -> erpc:call(Node, M, F, A, Timeout);
        true -> erpc_result(run(Node, {M, F, A}, Timeout))
    end.

erpc_result({ok, Value}) -> Value;
erpc_result({raise, throw, Thrown, _}) -> throw(Thrown);
erpc_result({raise, exit, Reason, _}) -> exit({exception, Reason});
erpc_result({raise, error, Reason, Stack}) -> error({exception, Reason, Stack});
erpc_result({down, Reason}) -> exit({exception, Reason});
erpc_result(nodedown) -> error({erpc, noconnection});
erpc_result(timeout) -> error({erpc, timeout}).

-if(?DOCATTRS).
-doc "`erpc:cast/2`: the request is sent and nothing waits for it.".
-endif.
-spec erpc_cast(node(), fun(() -> term())) -> ok.
erpc_cast(Node, Fun) when is_function(Fun, 0) ->
    case simulated(Node) of
        false ->
            erpc:cast(Node, Fun);
        true ->
            _ = start(Node, Fun, none),
            ok
    end.

-if(?DOCATTRS).
-doc "`erpc:cast/4`: the request is sent and nothing waits for it.".
-endif.
-spec erpc_cast(node(), module(), atom(), [term()]) -> ok.
erpc_cast(Node, M, F, A) ->
    case simulated(Node) of
        false ->
            erpc:cast(Node, M, F, A);
        true ->
            _ = start(Node, {M, F, A}, none),
            ok
    end.

%% ---------------------------------------------------------------------------
%% The call
%% ---------------------------------------------------------------------------

%% A call from a process on a simulated node to a simulated node.
simulated(Node) ->
    eta_net:local_node() =/= undefined andalso eta_net:is_node(Node).

run(Node, Job, Timeout) ->
    Tag = make_ref(),
    case spawn_worker(Node, Tag) of
        nodedown ->
            nodedown;
        Worker ->
            %% Monitored before it has the job, so its exit can't come first.
            Mon = eta_net:monitor(process, Worker),
            _ = eta_net:send(Worker, {'$eta_rpc', Job}),
            %% The result is the worker's exit reason, so it arrives with the
            %% `DOWN` or not at all, as `erpc`'s does. Sent as a message of its
            %% own, a cut between the two lost the reply after the worker was
            %% known to have finished, and a call with no timeout waited forever.
            case eta_net:await(Tag, Mon, Timeout) of
                {down, {'$eta_rpc', Tag, Result}} ->
                    Result;
                {down, noconnection} ->
                    nodedown;
                {down, Reason} ->
                    {down, Reason};
                timeout ->
                    _ = eta_net:demonitor(Mon, [flush]),
                    true = exit(Worker, kill),
                    timeout
            end
    end.

%% Connects, as `rpc` does, then starts the worker on `Node` and sends it the job.
%% `ReplyTag` is `none` for a cast.
start(Node, Job, ReplyTag) ->
    case spawn_worker(Node, ReplyTag) of
        nodedown ->
            nodedown;
        Worker ->
            _ = eta_net:send(Worker, {'$eta_rpc', Job}),
            Worker
    end.

spawn_worker(Node, ReplyTag) ->
    case eta_net:connect_node(Node) of
        true ->
            Worker = eta_sched:spawn(?MODULE, worker, [self(), ReplyTag]),
            ok = eta_net:place(Node, [Worker]),
            Worker;
        _ ->
            nodedown
    end.

-if(?DOCATTRS).
-doc false.
-endif.
-spec worker(pid(), reference() | none) -> ok.
worker(_Caller, ReplyTag) ->
    receive
        {'$eta_rpc', Job} ->
            Result =
                try
                    {ok, apply_job(Job)}
                catch
                    Class:Reason:Stack -> {raise, Class, Reason, Stack}
                end,
            case ReplyTag of
                none -> ok;
                _ -> finish({'$eta_rpc', ReplyTag, Result})
            end
    end.

%% A simulated monitor fires when the scheduler sees its target exit. With no
%% scheduler, nothing would see it, so the worker says so itself.
finish(Reason) ->
    case eta_sched:active() of
        true -> ok;
        false -> ok = eta_net:notify_exit(self(), Reason)
    end,
    exit(Reason).

apply_job({M, F, A}) -> apply(M, F, A);
apply_job(Fun) -> Fun().
