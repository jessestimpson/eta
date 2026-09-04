-module(eta_fsm).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
`gen_fsm`'s time-outs, on the virtual clock. The `gen_fsm` counterpart of
`eta_statem`, and a simpler one.

A `gen_fsm` time-out is the `after` of a `receive` inside `gen_fsm:loop/8`: a
callback returns `{next_state, S, D, Time}` and the loop waits `Time` for a
message, delivering `timeout` to the state function if none comes. No transform
of the module's code reaches that `receive`, so under simulation it would sit on
the real clock — and, as with `gen_statem`, nothing would report it.

The time-out is taken away from `gen_fsm` through the one seam it offers: the
value the callback returns. `eta_transform` wraps every callback so its return
passes through `return/2`, which reads the `Time` off the end, arms a virtual
deadline in its place, and hands `gen_fsm` the same value without it.

## Delivery needs no code of its own

`gen_fsm` dispatches a `{timeout, Ref, {'$gen_event', Event}}` message — the
shape `send_event_after/2` produces — to the state function as `Event`. So the
virtual deadline delivers `{timeout, Ref, {'$gen_event', timeout}}`, and
`gen_fsm` itself turns that into the `timeout` event the state function would
have seen. There is no clause to prepend, unlike `eta_statem`.

## Cancellation is "any message"

A `gen_fsm` time-out is cancelled by the arrival of *any* message, since the
`receive` it lives in returns on one. Here that is read as "any callback ran":
every callback return that is not itself a new time-out drops the pending one.
The two differ only between a message's arrival and its processing, and the
deadline cannot fire in that window under `eta_sched`, because a process with a
message to handle is runnable and the clock does not move while something is.

`return/2` takes the token `enter/0` read at the callback's start, so a callback
that reaches another state function directly — `prepare(Ev, S) -> update(start,
S)`, a common `gen_fsm` idiom — does not cancel the deadline its inner call
armed: the outer return sees a token that changed under it and leaves it be.

## Zero, `infinity` and `hibernate`

`Time = 0` is `receive ... after 0`: the event fires at once if the mailbox is
empty and not at all otherwise. That consults no clock, so it is done directly —
a self-send when the queue is empty — which is also the deterministic version
of what is, in `gen_fsm`, a race against the next sender.

`infinity` cancels and arms nothing. `hibernate` raises: it is a real-clock
behaviour of the process rather than of the machine, and nothing here stands in
for it.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

%% What `eta_transform` generates calls to.
-export([enter/0, return/2, init_return/1]).

%% What the transform points `gen_fsm`'s own timer functions at.
-export([send_event_after/2, start_timer/2, cancel_timer/1]).

%% Observation.
-export([armed/0]).

%% The one pending time-out, in the process dictionary of the machine that owns
%% it, for the reasons `eta_statem` gives: per-process state with no reader
%% outside the process, and a lifetime that ends with the machine.
-define(ARMED, '$eta_fsm_timeout').

-type token() :: undefined | reference().

-if(?DOCATTRS).
-doc """
Read at a callback's start: which time-out, if any, is pending. Handed to
`return/2` so it can tell a deadline that was pending when the callback began
from one the callback's body armed by calling another state function.

No side effects, so wrapping a function that turns out not to be a callback
costs a dictionary read.
""".
-endif.
-spec enter() -> token().
enter() ->
    case erlang:get(?ARMED) of
        #{ref := Ref} -> Ref;
        undefined -> undefined
    end.

-if(?DOCATTRS).
-doc """
What a callback's return means for the time-out, given the token `enter/0` read.

A return carrying a `Time` replaces whatever is pending and comes back without
it. One that does not — `{next_state, S, D}`, `{reply, R, S, D}`, a stop — means
a message was handled, which cancels the pending time-out *if it is still the
one that was pending at entry*. Anything that is not a `gen_fsm` return is left
alone, and so is the time-out.
""".
-endif.
-spec return(token(), Ret) -> Ret.
return(Token, Ret) ->
    case eta_time:running() of
        false -> Ret;
        true -> apply_return(Token, Ret)
    end.

-if(?DOCATTRS).
-doc """
The same for `init/1`'s return, which `eta_sched:fsm_start_link/3` hands to
`gen_fsm:enter_loop/4` — so a time-out set there must be armed here or it is
armed by OTP on the real clock. Nothing can be pending before the first event,
so a return without a `Time` cancels nothing.
""".
-endif.
-spec init_return(Ret) -> Ret.
init_return(Ret) ->
    return(undefined, Ret).

apply_return(_Token, {next_state, S, D, Time}) ->
    ok = arm(Time),
    {next_state, S, D};
apply_return(_Token, {reply, R, S, D, Time}) ->
    ok = arm(Time),
    {reply, R, S, D};
apply_return(_Token, {ok, S, D, Time}) ->
    ok = arm(Time),
    {ok, S, D};
apply_return(Token, Ret = {next_state, _, _}) ->
    ok = handled(Token),
    Ret;
apply_return(Token, Ret = {reply, _, _, _}) ->
    ok = handled(Token),
    Ret;
apply_return(_Token, Ret = {stop, _, _}) ->
    %% A stopping machine handles nothing more, and a deadline left in
    %% `eta_time`'s wheel for a dead process is a stray. Unconditional.
    _ = drop(),
    Ret;
apply_return(_Token, Ret = {stop, _, _, _}) ->
    _ = drop(),
    Ret;
apply_return(_Token, Ret) ->
    Ret.

%% A message was handled. That cancels the time-out that was pending when the
%% callback started — and only that one. A different token means the body armed
%% a fresh deadline through a nested state function, and that one stands.
handled(Token) ->
    case enter() of
        Token ->
            _ = drop(),
            ok;
        _ ->
            ok
    end.

%% ---------------------------------------------------------------------------
%% Arming
%% ---------------------------------------------------------------------------

arm(infinity) ->
    _ = drop(),
    ok;
arm(hibernate) ->
    error(
        {?MODULE,
            {unsupported_timeout, hibernate, <<
                "eta virtualises gen_fsm's time-outs and not hibernation, which "
                "is a real-clock behaviour of the process rather than of the "
                "machine. Return a time or infinity, or run without a clock"
            >>}}
    );
arm(0) ->
    %% `receive ... after 0`: the event fires now if nothing is waiting, and
    %% otherwise the waiting message wins and there is no time-out. A self-send
    %% lands behind nothing, so it is the next thing the loop takes.
    _ = drop(),
    Ref = make_ref(),
    Msg = message(Ref),
    case erlang:process_info(self(), message_queue_len) of
        {message_queue_len, 0} ->
            self() ! Msg,
            _ = erlang:put(?ARMED, #{ref => Ref, msg => Msg, tref => undefined}),
            ok;
        _ ->
            ok
    end;
arm(Time) when is_integer(Time), Time > 0 ->
    _ = drop(),
    Ref = make_ref(),
    Msg = message(Ref),
    TRef = eta_time:arm_self(Time, Msg),
    _ = erlang:put(?ARMED, #{ref => Ref, msg => Msg, tref => TRef}),
    ok.

%% The message `gen_fsm` will dispatch as a `timeout` event. Shaped as
%% `send_event_after/2`'s, which is what makes delivery free.
message(Ref) ->
    {timeout, Ref, {'$gen_event', timeout}}.

%% Removes the pending time-out, flushing its message if it already landed — a
%% cancelled time-out produces no event, not even a discarded one. See
%% `eta_time:disarm_self/2`; the zero form was a plain self-send and is flushed
%% the same way.
drop() ->
    case erlang:erase(?ARMED) of
        undefined ->
            none;
        #{tref := undefined, msg := Msg} ->
            receive
                Msg -> ok
            after 0 -> ok
            end,
            zero;
        #{tref := TRef, msg := Msg} ->
            ok = eta_time:disarm_self(TRef, Msg),
            eta
    end.

-if(?DOCATTRS).
-doc "Whether this process has a `gen_fsm` time-out pending.".
-endif.
-spec armed() -> boolean().
armed() ->
    enter() =/= undefined.

%% ---------------------------------------------------------------------------
%% gen_fsm's own timer functions
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
`gen_fsm:send_event_after/2` on the virtual clock. The same
`erlang:start_timer/3` it wraps, pointed at `eta_time`, so the event arrives
as `{timeout, Ref, {'$gen_event', Event}}` and `gen_fsm` dispatches it as usual.
""".
-endif.
-spec send_event_after(non_neg_integer(), term()) -> reference().
send_event_after(Time, Event) ->
    eta_time:start_timer(Time, self(), {'$gen_event', Event}).

-if(?DOCATTRS).
-doc "`gen_fsm:start_timer/2` on the virtual clock.".
-endif.
-spec start_timer(non_neg_integer(), term()) -> reference().
start_timer(Time, Msg) ->
    eta_time:start_timer(Time, self(), {'$gen_timer', Msg}).

-if(?DOCATTRS).
-doc """
`gen_fsm:cancel_timer/1` on the virtual clock, with the same contract: the
time remaining, or `false` if it had fired, in which case its message is
removed from the mailbox.
""".
-endif.
-spec cancel_timer(reference()) -> non_neg_integer() | false.
cancel_timer(Ref) ->
    case eta_time:cancel_timer(Ref) of
        false ->
            receive
                {timeout, Ref, _} -> 0
            after 0 -> false
            end;
        Remaining ->
            Remaining
    end.
