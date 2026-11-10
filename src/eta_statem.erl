-module(eta_statem).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
`gen_statem`'s own time-outs, on the virtual clock.

A `parse_transform` reaches a module's calls. It does not reach `gen_statem`,
and a state time-out is armed by `erlang:start_timer/4` *inside* `gen_statem` —
so a state machine under simulation held one real-clock dependence that no
amount of rewriting its own code could remove.

Worse than a slow run. The timer lands in the VM's wheel rather than
`eta_time`'s, so `strays/0` cannot see it and nothing reports it: the driver
finds nothing runnable, finds no deadline to advance to, and the run either ends
early or waits out the wall clock, with the interleaving from that point decided
by the machine rather than by the seed.

This module takes the time-out away from `gen_statem` instead, through the one
seam it does offer — the action list a callback **returns**, which is an
ordinary term the transform can read before OTP ever sees it.

## Three pieces, and none of them works without the other two

1. **Arming.** `eta_transform` wraps every state callback so its return passes
   through `return/3`. A `{state_timeout, Time, Content}` action is taken out of
   the list and a virtual deadline armed in its place, so `gen_statem` never
   learns a time-out was asked for and never starts a timer of its own.
2. **Delivery.** The deadline sends `{'$eta_statem', Ref}` to the machine, where
   it arrives as an ordinary `info` event. A clause `eta_transform` **prepends**
   to every state callback catches it — before the module's own clauses, which
   is the whole point, since they would not match it and the machine would die of
   `function_clause` — and returns
   `{keep_state_and_data, [{next_event, state_timeout, Content}]}`. `gen_statem`
   then delivers a genuine `state_timeout` event through its own machinery, so
   the callback sees exactly the event type and content it would have seen.
3. **Cancelling.** `return/3` compares the state the callback was called in with
   the state its return names, and cancels on a change. That is `gen_statem`'s
   rule, and getting it wrong in either direction is a bug you would not spot:
   cancel too eagerly and a heartbeat stops rearming, too lazily and a machine
   fires an election it already won.

## Except for `Time = 0`, which stays `gen_statem`'s

A zero time-out consults no clock. `gen_statem` registers it against a ref that
is not a timer ref and queues it, so there is nothing in it to virtualise, and it
is passed straight through.

That is not a shortcut, it is the only faithful option. A zero time-out is
delivered when the event *queue* drains and before the next message is taken from
the mailbox — after inserted and postponed events, and before anything new. It is
also still cancellable while it waits: `loop_t0q/5` re-checks the timer table
before delivering, so an inserted or postponed event that changes state first
means it never arrives at all. "Do this next, unless I leave the state before I
get to it" is the whole reason the idiom exists, and neither substitution
available here reproduces it — `{next_event, ...}` goes to the head of the queue
and can no longer be cancelled, and a message to self goes behind whatever is
already in the mailbox.

The cost is that the single state time-out is sometimes `gen_statem`'s and
sometimes this module's, so this module tracks which. When it is `gen_statem`'s,
a cancel or a replacement is put *back* into the action list for `gen_statem` to
apply to itself rather than being applied here. Split ownership with nobody
tracking it was the first version, and it fires the time-out twice: the machine
arms a zero, an inserted event replaces it with a real one, and both go off.

Forging `gen_statem`'s own timer message was tried first and cannot work. It
matches `{timeout, TimerRef, TimeoutType}` and then looks `TimerRef` up in a
`timers` map held in its private loop state, so a message from outside is never
recognised as a time-out and falls through to `info`.

## The cancellation rules, exactly

Taken from `gen_statem`'s implementation rather than from its documentation,
because two of them are not written down anywhere near each other:

- **A state change cancels it.** A change is `NextState =/= State`, compared with
  `=:=`. So `keep_state`, `keep_state_and_data`, `repeat_state`,
  `repeat_state_and_data` and `{next_state, SameState, _}` all leave it running.
  A machine that rearms on every heartbeat with `{keep_state, D, [{state_timeout,
  T, election}]}` depends on both halves of that: no cancel from the return, and
  a fresh deadline from the action.
- **Setting one cancels any running one.** There is at most one per machine.
- **`Time = infinity` cancels and starts nothing**, and `{state_timeout, cancel}`
  is the same thing said clearly.
- **`{state_timeout, update, Content}` changes the content and leaves the clock
  alone** — and if nothing is running it is *not* an error. It inserts the event
  immediately, which `gen_statem` documents as "a time-out autostart with
  immediate expiry, so there will be noise for example if a generic time-out name
  was misspelled". Mirrored rather than improved on.
- **A cancelled time-out that had already fired produces no event at all.**
  `gen_statem` parks the ref and drops the message when it arrives, without
  invoking a callback. `eta_time:disarm_self/2` flushes it from the mailbox
  instead, which reaches the same place: `return/2` runs *in* the machine's
  process, between two of `gen_statem`'s receives, so the message is sitting in
  the mailbox where a selective receive can take it.

## Generic time-outs

`{{timeout, Name}, Time, Content}` is owned the same way, one entry per name,
and delivered as a `{timeout, Name}` event. Two of the rules differ, as they do
in `gen_statem`: a state change does not cancel one, and setting one replaces only
the time-out of the same name. A machine that stops drops all of them, so none is
left behind as a stray.

## What is not owned here, and what happens if you ask

Event time-outs (`{timeout, Time, Content}`, or a bare integer action) are **not**
virtualised, and raise while a clock is running rather than quietly staying on
the wall clock. Same position `eta_net` takes on the messaging it cannot route:
the boundary is discoverable by using it rather than by reading a table.

They are not merely unimplemented, they are unsafe to leave alone here. Every
event `gen_statem` processes cancels a running event time-out, and delivery
above spends one — the `info` event carrying `{'$eta_statem', Ref}`. So a
machine holding both would find its event time-out cancelled by this module's
own traffic.

`hibernate` is untouched and unsupported for the same reasons as before.

## Inert unless a clock is running

`return/2` hands the term straight back when there is none, so every action goes
to `gen_statem` and behaves exactly as it always did. A module built with the
transform is therefore unchanged outside a simulation — including in the
ordinary test suite that runs alongside one.

The one hazard is the same one timers have always had here: a state time-out
armed *before* the clock started belongs to `gen_statem`, and this module will
not know about it. Start the clock before the system, which is what `eta_run`
does.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

%% What `eta_transform` generates calls to.
-export([tag/0, return/3, init_return/1, fire/1]).

%% Observation.
-export([armed/0]).

%% Where the deadlines this module owns are recorded, in the process dictionary
%% of the machine that owns them.
%%
%% ETS would be wrong here in a way it is not wrong for `eta_time`: this is
%% per-process state with no reader outside the process, and the process
%% dictionary is where `eta_observe` already keeps that kind of thing. It also
%% dies with the machine, which is the correct lifetime.
%%
%% A map keyed by time-out **type**: `state_timeout`, and `{timeout, Name}` for
%% each generic time-out.
-define(ARMED, '$eta_statem_timeouts').

-type timeout_type() :: state_timeout | {timeout, term()}.

%% Who holds the one state time-out. The first shape is a virtual deadline this
%% module armed; the second is a zero time-out `gen_statem` has queued and not yet
%% delivered, which this module only remembers so it knows to forward a cancel or
%% a replacement rather than applying one. See `arm/4`.
-type armed() ::
    #{ref := reference(), tref := reference(), content := term()}
    | #{otp := true, content := term()}.

-if(?DOCATTRS).
-doc """
The atom heading the message a virtual deadline delivers.

Read by `eta_transform` **at compile time** to build the clause it prepends, so
the pattern that catches the message and the code that sends it cannot drift
apart. Same trick, and the same reason, as `eta_observe:key/0`.
""".
-endif.
-spec tag() -> atom().
tag() ->
    '$eta_statem'.

-if(?DOCATTRS).
-doc """
What a state callback's return means for the time-outs this module owns, given
the state the callback was called in.

`eta_transform` wraps every state callback with this. Two jobs, in `gen_statem`'s
own order: a state *change* cancels the state time-out, and then the action list
is read for new ones. Returns the value with the actions it consumed removed.

`State` is the state the callback ran in — the third argument in
`handle_event_function` mode, and the function's own name in `state_functions`
mode, where the transform supplies it as a literal.
""".
-endif.
-spec return(term(), term(), Ret) -> Ret.
return(EventType, State, Ret) ->
    case eta_time:running() of
        false ->
            Ret;
        true ->
            ok = delivered(EventType),
            actions(transition(State, Ret))
    end.

%% A time-out event means the time-out that produced it has stopped running, and
%% the ownership table has to agree before the return is read — a callback
%% handling one may set another, and `{TimeoutType, update, _}` in particular
%% means something different depending on whether one is still running.
%%
%% Only an OTP-owned entry needs clearing. An eta-owned one was taken by `fire/1`
%% on the way in, which is the same moment for the same reason: `gen_statem`
%% removes a time-out from its table before delivering it.
delivered(Type) when Type =:= state_timeout; element(1, Type) =:= timeout ->
    case maps:find(Type, table()) of
        {ok, #{otp := true}} -> put_table(maps:remove(Type, table()));
        _ -> ok
    end;
delivered(_EventType) ->
    ok.

-if(?DOCATTRS).
-doc """
The same for `init/1`'s return, which can carry actions and therefore a state
time-out.

Separate from `return/2` because there is no state to have changed — the machine
is entering its first one — so there is nothing to cancel and no previous state
to compare against. `eta_sched:statem_start_link/3` hands `init/1`'s actions
straight to `gen_statem:enter_loop/6`, so a time-out set here would otherwise be
armed by OTP on the real clock before the machine had processed a single event.
""".
-endif.
-spec init_return(Ret) -> Ret.
init_return(Ret) ->
    case eta_time:running() of
        false -> Ret;
        true -> actions(Ret)
    end.

-if(?DOCATTRS).
-doc """
Turns a delivered deadline into the event `gen_statem` would have produced.

Called from the clause `eta_transform` prepends to every state callback. Returns
`{keep_state_and_data, [{next_event, state_timeout, Content}]}` for a deadline
that is still armed, and plain `keep_state_and_data` for one that is not.

The second case should be unreachable — cancelling flushes the message — and is
answered rather than raised on, because the cost of being wrong is a state
machine that dies on a message it was never meant to see.

The entry is **taken**, not read. When a real time-out fires `gen_statem` removes
it from its timer table before delivering the event, so a callback handling a
state time-out has none running; `{state_timeout, update, _}` in that callback
autostarts rather than updating, and this has to agree.
""".
-endif.
-spec fire(reference()) -> gen_statem:event_handler_result(term()).
fire(Ref) ->
    case take_ref(Ref) of
        {ok, Type, Content} -> {keep_state_and_data, [{next_event, Type, Content}]};
        error -> keep_state_and_data
    end.

-if(?DOCATTRS).
-doc """
The time-outs this process currently has armed, as `#{Type => Content}`.

For a test that wants to state "the election deadline is still running" without
waiting to find out. Empty when none are, which is also what a process with no
state machine in it reports.
""".
-endif.
-spec armed() -> #{timeout_type() => term()}.
armed() ->
    maps:map(fun(_Type, #{content := C}) -> C end, table()).

%% ---------------------------------------------------------------------------
%% State changes
%% ---------------------------------------------------------------------------

%% `gen_statem` cancels the state time-out when the state changes, and only then.
%% The comparison is `=:=` against the state the callback ran in, so returning
%% `{next_state, S, D}` from state `S` is *not* a change and leaves the deadline
%% running — which is the one people get wrong.
%% Nothing is forwarded from here even when the dropped time-out was
%% `gen_statem`'s: it cancels the state time-out on a state change itself, before
%% it reads the action list. Forwarding a second cancel would be harmless and
%% would also be a lie about who did it.
transition(State, Ret) ->
    case next_state(Ret) of
        {state, State} ->
            Ret;
        {state, _Other} ->
            _ = drop(state_timeout),
            Ret;
        stop ->
            %% Not `gen_statem`'s rule — it has no need for one, since a machine
            %% that is stopping will not process another event. Ours is a
            %% deadline in `eta_time`'s wheel, and one belonging to a process
            %% that has exited is a stray: it stops being able to make anything
            %% runnable while still being a reason the clock moved. See
            %% `eta_time:advance_to_next/1`.
            _ = [drop(Type) || Type <- maps:keys(table())],
            Ret;
        keep ->
            Ret
    end.

%% Which of the three things a return says about the next state. Anything
%% unrecognised is `keep`, which changes nothing — the safe direction for a value
%% this module does not understand.
next_state({next_state, S, _}) -> {state, S};
next_state({next_state, S, _, _}) -> {state, S};
next_state({stop, _}) -> stop;
next_state({stop, _, _}) -> stop;
next_state({stop_and_reply, _, _}) -> stop;
next_state({stop_and_reply, _, _, _}) -> stop;
next_state(_) -> keep.

%% ---------------------------------------------------------------------------
%% Actions
%% ---------------------------------------------------------------------------

%% Where the action list lives in each return shape.
%%
%% `stop_and_reply` is deliberately absent: its list is `[reply_action()]` and
%% cannot carry a time-out, so there is nothing to take out of it. `{ok, _, _, _}`
%% is `init/1`'s.
action_pos({next_state, _, _, _}) -> 4;
action_pos({keep_state, _, _}) -> 3;
action_pos({keep_state_and_data, _}) -> 2;
action_pos({repeat_state, _, _}) -> 3;
action_pos({repeat_state_and_data, _}) -> 2;
action_pos({ok, _, _, _}) -> 4;
action_pos(_) -> none.

actions(Ret) ->
    case action_pos(Ret) of
        none ->
            Ret;
        Pos ->
            %% `Actions :: [action()] | action()` — a single action needs no list
            %% around it, and a machine returning `{keep_state, D, postpone}` is
            %% ordinary enough that treating the bare form as unrecognised would
            %% quietly leave its time-outs real.
            case element(Pos, Ret) of
                As when is_list(As) -> setelement(Pos, Ret, lists:flatmap(fun action/1, As));
                A -> setelement(Pos, Ret, action(A))
            end
    end.

%% Each action becomes a list: `[]` for one consumed, `[A]` for one left alone,
%% and occasionally a substitution.
action({state_timeout, cancel}) ->
    forward(state_timeout, drop(state_timeout));
action({state_timeout, update, Content}) ->
    update(state_timeout, Content);
action({state_timeout, Time, Content}) ->
    arm(state_timeout, Time, Content, []);
action({state_timeout, Time, Content, Opts}) ->
    arm(state_timeout, Time, Content, Opts);
%% Generic time-outs: one per name, set and cancelled only by name, and left
%% running across a state change. Owned the same way as the state time-out,
%% keyed by `{timeout, Name}`.
action({{timeout, _} = Type, cancel}) ->
    forward(Type, drop(Type));
action({{timeout, _} = Type, update, Content}) ->
    update(Type, Content);
action({{timeout, _} = Type, Time, Content}) ->
    arm(Type, Time, Content, []);
action({{timeout, _} = Type, Time, Content, Opts}) ->
    arm(Type, Time, Content, Opts);
%% Event time-outs are not owned. See the moduledoc for why these raise rather
%% than being passed through to `gen_statem`.
action({timeout, _, _} = A) ->
    unsupported(A);
action({timeout, _, _, _} = A) ->
    unsupported(A);
action({timeout, cancel} = A) ->
    unsupported(A);
%% The bare form of an event time-out: an action that is just a time. Matched
%% last among the time-outs so the tuples above win, and guarded so `postpone`
%% and the other bare atoms fall through to the catch-all.
action(A) when is_integer(A); A =:= infinity ->
    unsupported(A);
action(A) ->
    [A].

unsupported(Action) ->
    error(
        {eta_statem,
            {unsupported_timeout, Action, <<
                "eta virtualises gen_statem's state and generic time-outs and not "
                "yet its event time-outs, and this one would stay on the real clock "
                "while the rest of the run did not - so when it fired would be "
                "decided by machine load. It cannot be left alone either: every "
                "event cancels a running event time-out, and delivering one of the "
                "others spends one. Use state_timeout or a generic time-out, or run "
                "without a clock"
            >>}}
    ).

%% ---------------------------------------------------------------------------
%% Arming
%% ---------------------------------------------------------------------------

%% A zero time-out is **given back to `gen_statem`**, and that is the exact
%% answer rather than a shortcut.
%%
%% It never involves a timer there. `gen_statem` registers it against a ref that
%% is not a timer ref and queues it, so no wall clock is consulted and there is
%% nothing to move onto a virtual one. Taking it over could only make it less
%% faithful, and did: it is delivered when the event *queue* drains and before
%% the next message is taken from the mailbox, which is neither the head of the
%% queue (where `{next_event, ...}` would put it) nor the tail of the mailbox
%% (where a self-send would). Inserted events and postponed events go first, and
%% any of them can still cancel it — `loop_t0q/5` re-checks the timer table
%% before delivering. That "do this next, unless I leave the state first" is the
%% whole reason the idiom exists.
%%
%% What it costs is knowing who owns the time-out, since there is only one and it
%% is now sometimes `gen_statem`'s. See `forward/2`.
%%
%% `Opts` is dropped because `gen_statem` drops it too: its own `Time` dispatch
%% matches the literal 0 before it looks at them, so `{abs, true}` on a zero is
%% already meaningless there.
arm(Type, 0, Content, _Opts) ->
    _ = drop(Type),
    ok = put_armed(Type, #{otp => true, content => Content}),
    [{Type, 0, Content}];
%% `infinity` cancels and starts nothing, which is what `gen_statem` optimises it
%% to as well.
arm(Type, infinity, _Content, _Opts) ->
    forward(Type, drop(Type));
arm(Type, Time, Content, Opts) ->
    Forward = forward(Type, drop(Type)),
    Ref = make_ref(),
    TRef = eta_time:arm_self(delay(Time, Opts), {tag(), Ref}),
    ok = put_armed(Type, #{ref => Ref, tref => TRef, content => Content}),
    Forward.

%% What has to be said to `gen_statem` about the time-out that was just dropped.
%%
%% Nothing, unless it was the one `gen_statem` holds — a zero time-out it has
%% queued and not yet delivered. `drop/1` cannot reach that one, so the cancel
%% goes back in the action list for `gen_statem` to apply to itself. It handles a
%% cancel of a zero exactly as it handles the one a state change performs:
%% `erlang:cancel_timer/1` on a ref that is not a timer says `false`, the ref is
%% parked, and `loop_t0q/5` skips it.
forward(Type, otp) -> [{Type, cancel}];
forward(_Type, _) -> [].

%% `{abs, true}` makes `Time` a point on the monotonic clock rather than a
%% distance from now — and under simulation that clock is `eta_time`'s, so a
%% machine computing a deadline from `erlang:monotonic_time/1` (which the
%% transform already points here) and one counting milliseconds forward agree.
%%
%% A point already past clamps to zero, which arms a deadline at the current
%% instant rather than delivering immediately. It fires at the next idle step
%% without the clock moving, which is a step later than a real timer would
%% manage and is deterministic either way.
delay(Time, Opts) ->
    case abs_opt(Opts) of
        true -> max(0, Time - eta_time:now_ms());
        false -> Time
    end.

abs_opt(Opts) when is_list(Opts) -> proplists:get_value(abs, Opts, false);
abs_opt({abs, Abs}) -> Abs;
abs_opt(_) -> false.

%% Changes the content of a running time-out and leaves its deadline alone.
%%
%% With nothing running this is *not* an error — `gen_statem` autostarts a zero
%% time-out instead, deliberately, so that a misspelled generic time-out name
%% makes noise. Forwarded rather than approximated, which gets the autostart's
%% delivery position right for free: it is a zero time-out like any other.
update(Type, Content) ->
    case maps:find(Type, table()) of
        {ok, Armed = #{otp := true}} ->
            ok = put_armed(Type, Armed#{content := Content}),
            [{Type, update, Content}];
        {ok, Armed} ->
            ok = put_armed(Type, Armed#{content := Content}),
            [];
        error ->
            ok = put_armed(Type, #{otp => true, content => Content}),
            [{Type, update, Content}]
    end.

%% Removes whatever is armed, and says which kind it was.
%%
%% An eta-owned deadline is disarmed here, and the disarm **flushes** — which is
%% what makes it equivalent to `gen_statem` dropping the message of a timer that
%% fired just before it was called off. This runs in the machine's process,
%% between two of its receives, so the message is in a mailbox a selective
%% receive can reach. See `eta_time:disarm_self/2`.
%%
%% An OTP-owned one is only forgotten. Cancelling it is `gen_statem`'s to do, and
%% the caller says so with `forward/2` — except after a state change, where
%% `gen_statem` has already done it unprompted.
drop(Type) ->
    case maps:take(Type, table()) of
        {#{otp := true}, Rest} ->
            ok = put_table(Rest),
            otp;
        {#{ref := Ref, tref := TRef}, Rest} ->
            ok = eta_time:disarm_self(TRef, {tag(), Ref}),
            ok = put_table(Rest),
            eta;
        error ->
            none
    end.

%% ---------------------------------------------------------------------------
%% The table
%% ---------------------------------------------------------------------------

-spec table() -> #{timeout_type() => armed()}.
table() ->
    case erlang:get(?ARMED) of
        undefined -> #{};
        Table when is_map(Table) -> Table
    end.

put_table(Table) when map_size(Table) =:= 0 ->
    _ = erlang:erase(?ARMED),
    ok;
put_table(Table) ->
    _ = erlang:put(?ARMED, Table),
    ok.

put_armed(Type, Armed) ->
    put_table(maps:put(Type, Armed, table())).

%% Which time-out a delivered ref belongs to, removing it. Linear in the number
%% of armed time-outs: one state time-out and a generic one per name.
take_ref(Ref) ->
    Table = table(),
    case [{T, C} || T := #{ref := R, content := C} <- Table, R =:= Ref] of
        [{Type, Content}] ->
            ok = put_table(maps:remove(Type, Table)),
            {ok, Type, Content};
        [] ->
            error
    end.
