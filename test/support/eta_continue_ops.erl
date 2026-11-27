-module(eta_continue_ops).

%% The client of `eta_continue_server'. The client runs as a scheduled process
%% in a run and as a plain process outside a run, so it is in a transformed
%% module.

-include_lib("eta/include/eta.hrl").

-export([client/1, outcome/0]).

%% Starts the server, calls it once and records the answer. Then the client
%% stops the server with an exit signal, if the server still runs, and records
%% the exit reason of the server. The server does not trap exits, so the exit
%% signal does not call `terminate/2'.
client(Script) ->
    Flag = process_flag(trap_exit, true),
    {ok, Server} = gen_server:start_link(eta_continue_server, Script, []),
    true = ets:insert(eta_continue, {answer, catch gen_server:call(Server, ping)}),
    true = exit(Server, shutdown),
    receive
        {'EXIT', Server, Why} -> true = ets:insert(eta_continue, {exit, Why})
    end,
    _ = process_flag(trap_exit, Flag),
    ok.

%% The records of one client, in a form that is equal in a run and outside a
%% run.
outcome() ->
    lists:sort([{Key, plain(Value)} || {Key, Value} <- ets:tab2list(eta_continue)]).

%% A call to a server that stops in its continue fails with the reason of the
%% server, or with `noproc' if the server is already dead. Outside a run the
%% VM decides which, so only the failure is compared. A stack trace is
%% dropped, because its frames differ in a run.
plain({'EXIT', {_, {gen_server, call, _}}}) -> call_failed;
plain({'EXIT', {_, {eta_net, call, _}}}) -> call_failed;
plain({Reason, [{_, _, _, _} | _]}) -> plain(Reason);
plain(Value) -> Value.
