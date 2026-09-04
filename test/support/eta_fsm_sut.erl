-module(eta_fsm_sut).
-behaviour(gen_fsm).

%% A `gen_fsm` that does nothing but let a test drive its time-outs through
%% each of the shapes they can take, and each of `eta_fsm`'s rules. Also every
%% `gen_fsm` start form the transform rewrites, for the gated-start tests.
%%
%% Deliberate: there is no catch-all in the state functions for a stray
%% `timeout` event — a deadline that survives a cancel arrives as `timeout` in
%% whatever state the machine is in and is reported to the owner, so a test can
%% see it rather than have it swallowed.

-include_lib("eta/include/eta.hrl").

%% The behaviour itself is deprecated; that is rather the point of this SUT.
-compile(nowarn_deprecated_callback).

-compile(
    {nowarn_deprecated_function, [
        {gen_fsm, start, 3},
        {gen_fsm, start, 4},
        {gen_fsm, start_link, 3},
        {gen_fsm, start_link, 4},
        {gen_fsm, send_event, 2},
        {gen_fsm, send_all_state_event, 2},
        {gen_fsm, sync_send_event, 2},
        {gen_fsm, sync_send_all_state_event, 2},
        {gen_fsm, send_event_after, 2},
        {gen_fsm, start_timer, 2},
        {gen_fsm, cancel_timer, 1},
        {gen_fsm, stop, 1}
    ]}
).

-export([start_link/1, start_link/2, start/1, start_link_named/2, start_named/2]).
-export([drive/2, sync_drive/2, who/1, state/1, stop/1]).
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).
-export([a/2, a/3, b/2, b/3]).

start_link(Owner) -> gen_fsm:start_link(?MODULE, {Owner, infinity}, []).
%% `InitTimeout` is `init/1`'s, the one time-out set before any event.
start_link(Owner, InitTimeout) -> gen_fsm:start_link(?MODULE, {Owner, InitTimeout}, []).
start(Owner) -> gen_fsm:start(?MODULE, {Owner, infinity}, []).
start_link_named(Name, Owner) -> gen_fsm:start_link(Name, ?MODULE, {Owner, infinity}, []).
start_named(Name, Owner) -> gen_fsm:start(Name, ?MODULE, {Owner, infinity}, []).

%% An asynchronous operation followed by a barrier, so the test hears back only
%% once the operation's return — and its time-out — has been applied. The
%% barrier is a `sys` request rather than a synchronous event, deliberately:
%% any *event* cancels a `gen_fsm` time-out, so a call here would cancel what
%% the operation just armed. A system message is not an event.
drive(Pid, Op) ->
    ok = gen_fsm:send_event(Pid, Op),
    _ = sys:get_state(Pid),
    ok.

%% An operation issued as a synchronous event, for the `{reply, ...}` shapes.
sync_drive(Pid, Op) ->
    gen_fsm:sync_send_event(Pid, Op).

who(Dest) -> gen_fsm:sync_send_all_state_event(Dest, who).
state(Dest) -> gen_fsm:sync_send_all_state_event(Dest, state).
stop(Dest) -> gen_fsm:stop(Dest).

init({Owner, InitTimeout}) ->
    ok = ?ETA_LABEL(fsm),
    case InitTimeout of
        infinity -> {ok, a, #{owner => Owner}};
        T -> {ok, a, #{owner => Owner}, T}
    end.

%% State `a`. A time-out that fires is reported with the state it fired in.
a(timeout, D = #{owner := Owner}) ->
    Owner ! {fired, a},
    {next_state, a, D};
a(Op, D) ->
    op(a, Op, D).

a({arm_reply, T}, _From, D) ->
    {reply, ok, a, D, T};
a(noop_reply, _From, D) ->
    {reply, ok, a, D}.

b(timeout, D = #{owner := Owner}) ->
    Owner ! {fired, b},
    {next_state, b, D};
%% Reached directly from `a` — the nested-call idiom whose inner time-out must
%% survive the outer return.
b(enter, D) ->
    {next_state, b, D, 250};
b(Op, D) ->
    op(b, Op, D).

b({arm_reply, T}, _From, D) ->
    {reply, ok, b, D, T};
b(noop_reply, _From, D) ->
    {reply, ok, b, D}.

%% The operations, shared by both states.
op(S, {arm, T}, D) ->
    {next_state, S, D, T};
op(S, noop, D) ->
    {next_state, S, D};
op(_S, {next_state, To}, D) ->
    {next_state, To, D};
%% `a` calls `b/2` directly and returns whatever it returns.
op(a, chain, D) ->
    b(enter, D);
op(S, {later, T, Event}, D) ->
    _ = gen_fsm:send_event_after(T, Event),
    {next_state, S, D};
op(S, {timer, T, Msg}, D) ->
    Ref = gen_fsm:start_timer(T, Msg),
    {next_state, S, D#{timer => Ref}};
op(S, cancel_timer, D = #{timer := Ref, owner := Owner}) ->
    Owner ! {cancelled, gen_fsm:cancel_timer(Ref)},
    {next_state, S, D};
op(S, {timeout, _Ref, Msg}, D = #{owner := Owner}) ->
    Owner ! {timer, S, Msg},
    {next_state, S, D};
op(S, Event, D = #{owner := Owner}) ->
    Owner ! {event, S, Event},
    {next_state, S, D}.

handle_event(_Event, S, D) ->
    {next_state, S, D}.

handle_sync_event(sync, _From, S, D) ->
    {reply, synced, S, D};
handle_sync_event(who, _From, S, D) ->
    {reply, self(), S, D};
handle_sync_event(state, _From, S, D) ->
    {reply, S, S, D}.

handle_info(_Info, S, D) ->
    {next_state, S, D}.

terminate(_Reason, _S, _D) ->
    ok.

code_change(_OldVsn, S, D, _Extra) ->
    {ok, S, D}.
