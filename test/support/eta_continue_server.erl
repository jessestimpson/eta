-module(eta_continue_server).
-behaviour(gen_server).

%% A `gen_server' whose `init/1' returns a continue. Each `handle_continue/2'
%% does the next step of a script, which is the argument of `init/1'. The
%% steps are the returns that `gen_server' accepts from `handle_continue/2',
%% an error, an exit, a throw and a bad return.
%%
%% `terminate/2' records its reason in the ETS table `eta_continue'.

-include_lib("eta/include/eta.hrl").

-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

init(Script) ->
    {ok, Script, {continue, step}}.

handle_continue(step, [Step | Rest]) ->
    case Step of
        continue -> {noreply, Rest, {continue, step}};
        noreply -> {noreply, Rest};
        hibernate -> {noreply, Rest, hibernate};
        zero -> {noreply, Rest, 0};
        infinity -> {noreply, Rest, infinity};
        timeout -> {noreply, Rest, 60000};
        {stop, Reason} -> {stop, Reason, Rest};
        {error, Reason} -> error(Reason);
        {exit, Reason} -> exit(Reason);
        throw -> throw({noreply, Rest});
        bad -> bad_return
    end.

handle_call(ping, _From, Script) ->
    {reply, pong, Script}.

handle_cast(_Msg, Script) ->
    {noreply, Script}.

handle_info(_Msg, Script) ->
    {noreply, Script}.

terminate(Reason, _Script) ->
    true = ets:insert(eta_continue, {terminated, Reason}),
    ok.
