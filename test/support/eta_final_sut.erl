-module(eta_final_sut).
-behaviour(eta_harness).

%% Transformed unconditionally, like every SUT here: the ticker below only keeps
%% a run out of `quiescent' if its `after' lands on the virtual clock.
-compile({parse_transform, eta_transform}).

%% A system under test for `check_final/2`.
%%
%% It does as little as possible on purpose. `check_final/2` is about *when* a
%% callback runs and *what it is told*, so the system it runs over should not be
%% able to influence either — this one counts its operations in an ETS table the
%% test reads afterwards and has no state worth an invariant.
%%
%% Two knobs, both from `Config`:
%%
%% <dl>
%%   <dt>`final'</dt><dd>`ok' (the default), `violation', or `crash'. What
%%     `check_final/2' returns.</dd>
%%   <dt>`tick_ms'</dt><dd>if set, a process that rearms a timer forever, so the
%%     run can never reach `quiescent' and has to end on `settle_budget'.</dd>
%% </dl>

-export([init/2, processes/1, generate/2, execute/2, check/1, check_final/2,
         terminate/1]).

-define(TAB, eta_final_sut).

%% Named, and cleared here rather than in `terminate/1`, because the test reads it
%% *after* the run has torn itself down.
init(_Seed, Config) ->
    catch ets:delete(?TAB),
    Tab = ets:new(?TAB, [public, set, named_table]),
    ets:insert(Tab, {ops, 0}),
    Pid = spawn(fun idle/0),
    Ticker =
        case maps:get(tick_ms, Config, undefined) of
            undefined -> undefined;
            Ms -> spawn(fun() -> tick(Ms) end)
        end,
    {ok, #{tab => Tab, pid => Pid, ticker => Ticker,
           final => maps:get(final, Config, ok)}}.

processes(#{pid := Pid, ticker := undefined}) -> [Pid];
processes(#{pid := Pid, ticker := T}) -> [Pid, T].

generate(_Sut, Rand) ->
    {noop, Rand}.

execute(noop, Sut = #{tab := Tab}) ->
    _ = ets:update_counter(Tab, ops, 1),
    Sut.

check(_Sut) ->
    ok.

%% Records what it was told, so a test can assert on the `Settled' it saw as well
%% as on the fact that it ran at all.
check_final(Settled, #{tab := Tab, final := Final}) ->
    ets:insert(Tab, {final_called, Settled}),
    case Final of
        ok -> ok;
        violation -> {violation, #{property => final_said_no, settled => Settled}};
        crash -> error(deliberate)
    end.

terminate(#{pid := Pid, ticker := T}) ->
    exit(Pid, kill),
    case T of
        undefined -> ok;
        _ -> exit(T, kill)
    end,
    ok.

idle() ->
    receive
        _ -> idle()
    end.

%% Never quiescent: a deadline is always pending, so `advance_to_next/1` always
%% has somewhere to go and the run can only end on its settle budget.
tick(Ms) ->
    receive
    after Ms -> tick(Ms)
    end.
