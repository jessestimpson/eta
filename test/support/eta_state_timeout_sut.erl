-module(eta_state_timeout_sut).
-behaviour(gen_statem).

%% A machine that does nothing but let a test drive `gen_statem`'s state
%% time-out through each of its rules one at a time. See `eta_statem`.
%%
%% Written in `handle_event_function` mode, which is the half of the pass where
%% the state is an *argument* — `eta_elect` covers `state_functions`, where it is
%% the function's name.
%%
%% Two things about it are deliberate and would be mistakes anywhere else:
%%
%% **There is no `info` clause.** The virtual deadline is delivered as an
%% ordinary `info` event, so a machine written like this one dies of
%% `function_clause` unless the clause `eta_transform` prepends goes *before* its
%% own. Adding a catch-all here would hide the failure this module exists to
%% catch.
%%
%% **Every operation is a cast, followed by a synchronous `sync` call.** A reply
%% is sent by `eta_net:reply/2` from inside the callback, so a test that drove
%% the machine with a call could be released and advance the clock while the
%% callback was still running — before the action list had been read and the
%% deadline armed. Casting and then calling puts the arming strictly before the
%% test hears anything, because `gen_statem` processes one event at a time.

-include_lib("eta/include/eta.hrl").

-export([start_link/1, start_link/2, drive/2, stop/1]).
-export([callback_mode/0, init/1, handle_event/4]).

callback_mode() ->
    handle_event_function.

start_link(Owner) ->
    start_link(Owner, []).

%% `Actions` are `init/1`'s, which is the only way to arm a time-out before the
%% machine has processed an event.
start_link(Owner, Actions) ->
    gen_statem:start_link(?MODULE, {Owner, Actions}, []).

%% Issue an operation and return once it has been applied. See the note above on
%% why this is not one call.
drive(Pid, Op) ->
    ok = gen_statem:cast(Pid, Op),
    synced = gen_statem:call(Pid, sync),
    ok.

stop(Pid) ->
    gen_statem:stop(Pid).

init({Owner, Actions}) ->
    {ok, a, #{owner => Owner}, Actions}.

%% Every state time-out that reaches the machine is reported with the state it
%% arrived in, so a test can assert on both — a deadline that survives a
%% transition it should not have survived arrives in the wrong state rather than
%% not at all.
handle_event(state_timeout, Content, State, #{owner := Owner}) ->
    Owner ! {fired, State, Content},
    keep_state_and_data;
handle_event({call, From}, sync, _State, _Data) ->
    {keep_state_and_data, [{reply, From, synced}]};
handle_event({call, From}, state, State, _Data) ->
    {keep_state_and_data, [{reply, From, State}]};
%% Arm, in each of the forms the action can take.
handle_event(cast, {arm, Time, Content}, _State, _Data) ->
    {keep_state_and_data, [{state_timeout, Time, Content}]};
handle_event(cast, {arm, Time, Content, Opts}, _State, _Data) ->
    {keep_state_and_data, [{state_timeout, Time, Content, Opts}]};
handle_event(cast, cancel, _State, _Data) ->
    {keep_state_and_data, [{state_timeout, cancel}]};
handle_event(cast, {update, Content}, _State, _Data) ->
    {keep_state_and_data, [{state_timeout, update, Content}]};
%% The four ways of not changing state, which must all leave a deadline running,
%% and the one way of changing it, which must cancel.
handle_event(cast, {next_state, State}, _Old, Data) ->
    {next_state, State, Data};
handle_event(cast, keep, _State, _Data) ->
    keep_state_and_data;
handle_event(cast, keep_data, _State, Data) ->
    {keep_state, Data};
handle_event(cast, repeat, _State, _Data) ->
    repeat_state_and_data;
handle_event(cast, repeat_data, _State, Data) ->
    {repeat_state, Data};
%% An action list that is a single action rather than a list of them, which
%% `gen_statem` accepts and a pass that only walked lists would miss.
handle_event(cast, {bare, Time, Content}, _State, _Data) ->
    {keep_state_and_data, {state_timeout, Time, Content}};
%% A zero time-out armed alongside an inserted event, which is where its delivery
%% position stops being a detail: the inserted event is processed first, and what
%% it does decides whether the time-out is delivered at all.
handle_event(cast, {zero_then, Inserted}, _State, _Data) ->
    {keep_state_and_data, [
        {state_timeout, 0, zero},
        {next_event, internal, Inserted}
    ]};
handle_event(internal, {goto, State}, _Old, Data) ->
    {next_state, State, Data};
handle_event(internal, {arm, Time, Content}, _State, _Data) ->
    {keep_state_and_data, [{state_timeout, Time, Content}]};
handle_event(internal, Event, _State, #{owner := Owner}) ->
    Owner ! {inserted, Event},
    keep_state_and_data;
%% Whatever the test hands over, for the time-out kinds that are not supported.
handle_event(cast, {raw, Action}, _State, _Data) ->
    {keep_state_and_data, [Action]}.
