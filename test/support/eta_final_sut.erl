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
%%   <dt>`done_ticks'</dt><dd>if set, `settle_done/1' answers `true' once the
%%     ticker has ticked that many times.</dd>
%%   <dt>`spin'</dt><dd>if `true', two processes that pass a message back and
%%     forth forever, so one of them is always runnable and the clock never moves
%%     unless `busy_steps' moves it.</dd>
%% </dl>

-export([init/2, processes/1, generate/2, execute/2, check/1, check_final/2,
         settle_done/1, terminate/1]).

-define(TAB, eta_final_sut).

%% Named, and cleared here rather than in `terminate/1`, because the test reads it
%% *after* the run has torn itself down.
init(_Seed, Config) ->
    catch ets:delete(?TAB),
    Tab = ets:new(?TAB, [public, set, named_table]),
    ets:insert(Tab, {ops, 0}),
    Pid = spawn(fun idle/0),
    ets:insert(Tab, {ticks, 0}),
    Ticker =
        case maps:get(tick_ms, Config, undefined) of
            undefined -> undefined;
            Ms -> spawn(fun() -> tick(Ms) end)
        end,
    Spinner =
        case maps:get(spin, Config, false) of
            true ->
                %% The ball is thrown by the first operation, once the scheduler
                %% owns both: thrown here, they would pass it back and forth on
                %% the real VM until the run took them over.
                [spawn(fun spin/0), spawn(fun spin/0)];
            false ->
                []
        end,
    {ok, #{tab => Tab, pid => Pid, ticker => Ticker, spinner => Spinner,
           final => maps:get(final, Config, ok),
           done_ticks => maps:get(done_ticks, Config, undefined)}}.

processes(#{pid := Pid, ticker := T, spinner := S}) ->
    [P || P <- [Pid, T | S], P =/= undefined].

generate(_Sut, Rand) ->
    {noop, Rand}.

execute(noop, Sut = #{tab := Tab, spinner := Spinner}) ->
    _ = ets:update_counter(Tab, ops, 1),
    case Spinner of
        [A, B] -> A ! {ball, B};
        [] -> ok
    end,
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

settle_done(#{done_ticks := undefined}) ->
    false;
settle_done(#{tab := Tab, done_ticks := N}) ->
    ets:lookup_element(Tab, ticks, 2) >= N.

terminate(#{pid := Pid, ticker := T, spinner := S}) ->
    _ = [exit(P, kill) || P <- [Pid, T | S], P =/= undefined],
    ok.

idle() ->
    receive
        _ -> idle()
    end.

%% Never quiescent: a deadline is always pending, so `advance_to_next/1` always
%% has somewhere to go and the run can only end on its settle budget.
tick(Ms) ->
    receive
    after Ms ->
        _ = ets:update_counter(?TAB, ticks, 1),
        tick(Ms)
    end.

spin() ->
    receive
        {ball, Other} ->
            Other ! {ball, self()},
            spin()
    end.
