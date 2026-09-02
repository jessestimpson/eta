-module(eta_rand).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
Seeded stand-in for the process-local `rand` state.

`rand:uniform/1` and friends draw from a state kept in the process dictionary,
and when a process has never been seeded OTP seeds it for them — from
`erlang:system_time/0` and `erlang:unique_integer/1`, inside the `rand` module,
where no transform of user code reaches. So a system that picks a gossip peer
with `lists:nth(rand:uniform(length(Peers)), Peers)` has a schedule that is not a
function of the seed, and nothing in a run result says so: the scheduler's
accounting is clean, no module loaded late, and the same seed produces a
different trace on every run.

`eta_transform` points a module's `rand:uniform/0,1`, `uniform_real/0`,
`normal/0,2` and `seed/1,2` here. Inert unless a run has started this module —
every function delegates to `rand` otherwise — so a transformed module behaves
normally outside a simulation.

## How a process gets its stream

Each process draws from a stream of its own, kept in its process dictionary
under a key `rand` does not use. The stream is created on the process's first
draw, from the run's seed and a counter this module keeps: the first process to
draw gets stream 1, the second stream 2, and so on. Under `eta_sched` exactly one
process runs at a time, so the order in which processes first draw is a function
of the schedule, and the streams are therefore a function of the seed.

That counter is the one design choice worth knowing about. A stream could
instead be derived from the scheduler's id for the process, which would survive
an edit to the trace better — but a process cannot ask the scheduler anything
while it is being stepped, since the scheduler is waiting on that very step. The
counter needs no conversation. What it costs is that a shrunk trace reassigns
streams to processes that first draw *after* the deleted entry, which is the same
cost `eta_net`'s fault schedule already pays and is accounted for the same way:
`eta_shrink` verifies a shrunk trace by replaying it, and only hands back one
that still reproduces.

A stream is tagged with the run that created it, so a process that outlives one
run and draws in the next is reseeded rather than continuing where it left off.

## Explicit seeding is honoured

`rand:seed(Alg, Seed)` with an explicit seed is deterministic already, and a
system that calls it means something by it. It replaces the process's stream
with `rand:seed_s(Alg, Seed)`. `rand:seed(Alg)` — algorithm only, real entropy —
replaces the stream with a fresh one from the counter instead, which is the
deterministic reading of "reseed me".

## What is counted

`stats/0` reports `streams`, `draws`, and `unmanaged` — draws made while a
scheduler was active by a process other than the one being stepped. Such a draw
happened at a moment wall clock chose, and the stream it created or advanced is
therefore not a function of the schedule. `eta_run:audit/1` checks it, next to
`net.unmanaged`, which is the same failure for sends.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    start/0,
    start/1,
    stop/0,
    running/0,
    stats/0
]).

%% What `eta_transform` points a module's `rand` calls at.
-export([
    uniform/0,
    uniform/1,
    uniform_real/0,
    normal/0,
    normal/2,
    seed/1,
    seed/2
]).

-define(STATE, eta_rand_state).
%% Deliberately not `rand`'s own key, so a system's untransformed `rand` calls
%% and this module's streams never share a state.
-define(KEY, '$eta_rand').

%% ---------------------------------------------------------------------------
%% Lifecycle
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "Starts with seed 0. See `start/1`.".
-endif.
-spec start() -> ok.
start() ->
    start(#{}).

-if(?DOCATTRS).
-doc """
Starts the module, so that draws from transformed modules come from seeded
streams. `eta_run` does this for you, before `init/2`.

One per VM, as with `eta_time` and `eta_net`, so runs must be serial. Starting
over a running instance resets it; starting over one another live process owns
raises.
""".
-endif.
-spec start(#{seed => integer()}) -> ok.
start(Opts) ->
    ok = claim(),
    stop(),
    ?STATE = ets:new(?STATE, [named_table, public, set]),
    true = ets:insert(?STATE, [
        {seed, maps:get(seed, Opts, 0)},
        %% Names this run, so a stream left in a process dictionary by an earlier
        %% run is recognised as stale. See `stream/0`.
        {run, make_ref()},
        {streams, 0},
        {draws, 0},
        {unmanaged, 0}
    ]),
    ok.

claim() ->
    case ets:info(?STATE, owner) of
        undefined ->
            ok;
        Self when Self =:= self() ->
            ok;
        Other ->
            error(
                {eta_rand,
                    {rand_in_use, Other, <<
                        "one per VM; keep runs serial (`async: false`) and do "
                        "not drive two at once"
                    >>}}
            )
    end.

-if(?DOCATTRS).
-doc "Stops the module. Safe to call when it is not running.".
-endif.
-spec stop() -> ok.
stop() ->
    try
        ets:delete(?STATE)
    catch
        error:badarg -> ok
    end,
    ok.

-if(?DOCATTRS).
-doc "Whether the module is running. When false, every draw delegates to `rand`.".
-endif.
-spec running() -> boolean().
running() ->
    ets:whereis(?STATE) =/= undefined.

-if(?DOCATTRS).
-doc """
What happened so far: `streams` created, `draws` made, and `unmanaged` draws —
those made while a scheduler was active by a process other than the one being
stepped. See the module doc.
""".
-endif.
-spec stats() -> #{streams | draws | unmanaged => non_neg_integer()}.
stats() ->
    #{
        streams => ets:lookup_element(?STATE, streams, 2),
        draws => ets:lookup_element(?STATE, draws, 2),
        unmanaged => ets:lookup_element(?STATE, unmanaged, 2)
    }.

%% ---------------------------------------------------------------------------
%% The rewrite targets
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "`rand:uniform/0`, from the process's seeded stream.".
-endif.
-spec uniform() -> float().
uniform() ->
    draw(fun rand:uniform_s/1, fun rand:uniform/0).

-if(?DOCATTRS).
-doc "`rand:uniform/1`, from the process's seeded stream.".
-endif.
-spec uniform(pos_integer()) -> pos_integer().
uniform(N) ->
    draw(fun(S) -> rand:uniform_s(N, S) end, fun() -> rand:uniform(N) end).

-if(?DOCATTRS).
-doc "`rand:uniform_real/0`, from the process's seeded stream.".
-endif.
-spec uniform_real() -> float().
uniform_real() ->
    draw(fun rand:uniform_real_s/1, fun rand:uniform_real/0).

-if(?DOCATTRS).
-doc "`rand:normal/0`, from the process's seeded stream.".
-endif.
-spec normal() -> float().
normal() ->
    draw(fun rand:normal_s/1, fun rand:normal/0).

-if(?DOCATTRS).
-doc "`rand:normal/2`, from the process's seeded stream.".
-endif.
-spec normal(number(), number()) -> float().
normal(Mean, Variance) ->
    draw(
        fun(S) -> rand:normal_s(Mean, Variance, S) end,
        fun() -> rand:normal(Mean, Variance) end
    ).

-if(?DOCATTRS).
-doc """
`rand:seed/1`. Algorithm only, which outside a simulation means real entropy;
here it replaces the process's stream with a fresh one from the counter.
""".
-endif.
-spec seed(rand:builtin_alg() | rand:state() | rand:export_state()) -> rand:state().
seed(AlgOrState) ->
    case running() of
        false ->
            rand:seed(AlgOrState);
        true ->
            State =
                case AlgOrState of
                    %% A state or an exported state, rather than an algorithm
                    %% name, is deterministic and carries its own algorithm.
                    {_, _} -> rand:seed_s(AlgOrState);
                    Alg -> fresh_stream(Alg)
                end,
            put(?KEY, {run(), State}),
            State
    end.

-if(?DOCATTRS).
-doc "`rand:seed/2`. An explicit seed is deterministic already, and is honoured.".
-endif.
-spec seed(rand:builtin_alg(), term()) -> rand:state().
seed(Alg, Seed) ->
    case running() of
        false ->
            rand:seed(Alg, Seed);
        true ->
            State = rand:seed_s(Alg, Seed),
            put(?KEY, {run(), State}),
            State
    end.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

draw(Sim, Real) ->
    case running() of
        false ->
            Real();
        true ->
            {Value, State} = Sim(stream()),
            put(?KEY, {run(), State}),
            ok = count(),
            Value
    end.

%% The process's stream, created on first use. A stream tagged with another run
%% is stale — the process outlived the run that seeded it — and is replaced.
stream() ->
    Run = run(),
    case get(?KEY) of
        {Run, State} -> State;
        _ -> fresh_stream(exsss)
    end.

fresh_stream(Alg) ->
    Seed = ets:lookup_element(?STATE, seed, 2),
    N = ets:update_counter(?STATE, streams, 1),
    rand:seed_s(Alg, {Seed, N, Seed bxor (N * 7919)}).

run() ->
    ets:lookup_element(?STATE, run, 2).

%% A draw by a process the scheduler is not stepping happened at a moment wall
%% clock chose. Only meaningful while a scheduler is active: with none, nothing
%% is being stepped and there is nothing to be outside of.
count() ->
    _ = ets:update_counter(?STATE, draws, 1),
    case eta_sched:active() andalso eta_sched:stepping() =/= self() of
        true ->
            _ = ets:update_counter(?STATE, unmanaged, 1),
            ok;
        false ->
            ok
    end.
