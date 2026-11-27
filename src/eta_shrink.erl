-module(eta_shrink).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
Delta-debugging a failing trace down to one a human can read (design:
`docs/design.md`).

A run that finds a violation hands back the trace that produced it, and for a real
system that is not a bug report: a three-member registry cluster produces around
1900 entries, of
which almost all are heartbeats and unrelated members making progress. Shrinking
searches for the shortest trace that still fails.

```erlang
#{outcome := {violation, _}, trace := Trace} = eta_run:run(my_sut, #{seed => 3}),
#{trace := Minimal} = eta_shrink:shrink(my_sut, Trace, #{seed => 3}).
```

## The oracle has three answers, not two

This is the part that decides whether a shrinker is any good.

A candidate trace is tested by replaying it, and the result is one of:

| Result | Meaning |
|---|---|
| the same violation | the removal was safe — keep the shorter trace |
| a clean run | the removed entries mattered — put them back |
| a *divergence* | the candidate is not a valid schedule; **no evidence either way** |

Conflating the last two is the classic way to build a shrinker that appears to work
and quietly discards the minimal case: a candidate that diverges gets recorded as
"still fails? no", so a removal that was in fact safe is reverted.

Here divergence is avoided rather than classified. `eta_run:replay/3` runs candidates
in `lenient` mode, where a step naming a process that is not currently runnable is
skipped instead of reported. That matters because entries are not independent:
removing an operation necessarily strands the steps belonging to the process it
spawned, so under a strict replay nearly every candidate would diverge and the
search would learn nothing.

## Why the result is re-recorded

A lenient replay is not a faithful one — it silently dropped entries — so the
shrunk *candidate* is not a trace anyone should be handed. What the run actually
executed is, and `eta_run` records exactly that. So the last step of a shrink is to
take the surviving candidate's own recorded trace and verify it **strictly**: a
minimal trace that does not replay is not a repro.

That verification is not a formality. It is the only thing standing between this
and a shrinker that reports a beautifully small trace nobody can reproduce.

## What it shrinks, and what it cannot

Both dimensions at once, since both are entries in the same list: operations
disappear entirely, and so do scheduling decisions. Removing an operation is the
larger win and usually happens first because ddmin works coarse-to-fine; what
survives at the end is close to a minimal interleaving.

**A shrunk trace is not an explanation, and this doc used to claim otherwise.**
It said the result was "nearly a proof sketch of the defect", which is true for
somebody who already knows the protocol and how ids were assigned, and false for
everybody else. `{step, 8}` names a position, not a process, and says nothing
about what that process did. Reading one means reconstructing every mailbox
state by hand.

Pinning ids fixed which process an entry names, and that is not the same as
saying what it did — `{step, 8}` is a stable name and still a number. What
shrinking gives you is a trace short enough to be worth narrating. `eta_log` is
what narrates it, and the order matters:

```erlang
#{trace := Minimal} = eta_shrink:shrink(Mod, Trace, Opts),
eta_run:replay(Mod, Minimal, Opts),
eta_log:analyze().
```

**The replay is not optional.** `eta_log` collection restarts with every run,
and a shrink has just performed several hundred of them, so the log currently
holds whatever its last candidate did. Replaying the surviving trace is what
puts your failure in the log and nothing else.

It cannot shrink below what the system needs to reach the violation at all.

## Shrinking the content of an operation

`shrink/3` also replaces an operation with a smaller operation, when the harness
exports the optional callback `shrink_op/1` of `eta_harness`. `shrink_op(Op)`
returns the operations to try in place of `Op`, in the order to try them.

1. `shrink/3` removes entries from the trace, as described above.
2. For each operation of the remaining trace, from the first to the last,
   `shrink/3` replays the trace with each operation that `shrink_op/1` returns.
   The first replay that gives the same violation keeps its operation.
   `shrink/3` then calls `shrink_op/1` on the kept operation, until no
   replacement gives the same violation.
3. If step 2 replaced an operation, `shrink/3` repeats from step 1. A smaller
   operation can make other entries unnecessary.

A replacement keeps the ids of the processes that the original operation
created. Each replay of step 2 counts against `max_tests`. `ops_shrunk` in the
result is the number of replacements that were kept.

A harness without `shrink_op/1` gets step 1 only, and `ops_shrunk` is 0.

## Ids used to be positional, and that used to bound the whole search

An id named a process by counting — "the Nth process this run adopted" — so
deleting an operation renumbered every process created after it and the surviving
`{step, Id}` entries stopped naming what they named. The oracle then read a clean
run and concluded the removal mattered, when all that had happened was arithmetic.
It was the single largest thing holding results back, and it is closed:
`eta_run` records on each entry the ids that entry created, and `eta_sched:pin/2`
hands them back on replay instead of recounting. An id now means "the process the
trace called 7", which no deletion elsewhere can change.

Measured by deleting a trace's leading operation and counting how many of the steps
behind it still ran — 76/105, 84/96 and 73/107 on three 2PC seeds before, 101/105,
94/96 and 100/107 after. End to end over 30 failing 2PC seeds: mean result 9.4
entries down to 7.6, the worst seed from 22 entries to 7, and the `max_tests`
budget went from binding on one seed to binding on none, the hungriest search now
using 336 of its 500.

Not every seed improved — one went from 7 entries to 8. ddmin's path through the
partitions depends on the oracle's answers, so answering more of them correctly
can still land somewhere marginally worse; nothing about that is unsound, and the
result is verified either way.

**What remains is the real bound, and it is smaller.** Removing an operation still
strands the steps belonging to the processes it created, because those processes
genuinely never exist — no naming scheme fixes that, and it is the correct
behaviour. So minimality is still approximate; it is now approximate for a reason
that is about causality rather than about counting.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([shrink/3]).

-export_type([result/0]).

-type result() :: #{
    trace := [eta_run:entry()],
    original := non_neg_integer(),
    shrunk := non_neg_integer(),
    tests := non_neg_integer(),
    %% The number of operations that were replaced by a smaller operation. See
    %% "Shrinking the content of an operation" in the module doc.
    ops_shrunk := non_neg_integer(),
    outcome := eta_run:outcome(),
    verified := boolean()
}.

-record(s, {
    mod :: module(),
    opts :: map(),
    match :: fun((eta_harness:violation()) -> boolean()),
    tests = 0 :: non_neg_integer(),
    ops_shrunk = 0 :: non_neg_integer(),
    budget :: integer()
}).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Shrinks `Trace` to the shortest prefix-free subsequence that still violates. If
the harness exports `shrink_op/1`, `shrink/3` also replaces operations with
smaller operations. See "Shrinking the content of an operation" in the module
doc.

`Opts` are `eta_run:run/2`'s, plus:

- `match` — a predicate on the violation deciding whether a candidate counts as
  "the same failure". The default is derived from the original: if the violation is
  a map carrying a `property` key, a candidate must report the *same* property;
  otherwise any violation counts.

  Overriding this matters for a system with more than one invariant, where the
  default's fallback would happily shrink one bug into a different one — a smaller
  trace for a failure you were not investigating, which is worse than no shrink
  because it looks like progress.

- `max_tests` (500) — bound on candidate replays. Shrinking is a search, and on a
  large trace it is the expensive part of a run. It used to be **binding**, back
  when a deletion could renumber the trace and the search spent its budget
  relearning that; over the same 30 failing 2PC seeds the hungriest now finishes in
  336 candidates. Still worth raising when a result looks larger than it should —
  a system with more processes than 2PC has more schedule to search.

Returns the minimal trace *as executed*, verified to replay strictly. `verified =>
false` means the search found something smaller but it did not survive strict
replay, and the reported trace is the original — see the module doc.
""".
-endif.
-spec shrink(module(), [eta_run:entry()], map()) -> result().
shrink(Mod, Trace, Opts) ->
    case classify(Mod, Trace, Opts) of
        {violation, Detail} ->
            S = #s{
                mod = Mod,
                opts = maps:remove(match, Opts),
                match = maps:get(match, Opts, default_match(Detail)),
                budget = maps:get(max_tests, Opts, 500)
            },
            {Minimal, S1} = minimise(Trace, S),
            finish(Trace, Minimal, S1);
        Other ->
            %% Nothing to shrink. Reporting it beats returning a "minimal" trace
            %% for a failure that did not happen.
            #{
                trace => Trace,
                original => length(Trace),
                shrunk => length(Trace),
                tests => 0,
                ops_shrunk => 0,
                outcome => Other,
                verified => false
            }
    end.

%% The surviving candidate is only a *recipe*; the trace it actually executed is
%% the artefact, and it has to replay strictly or it is not a repro.
finish(Original, Minimal, S = #s{mod = Mod, opts = Opts}) ->
    Lenient = eta_run:replay(Mod, Minimal, Opts#{lenient => true}),
    Executed = maps:get(trace, Lenient),
    Strict = eta_run:replay(Mod, Executed, Opts#{lenient => false}),

    case matches(maps:get(outcome, Strict), S) of
        true ->
            #{
                trace => Executed,
                original => length(Original),
                shrunk => length(Executed),
                tests => S#s.tests,
                ops_shrunk => S#s.ops_shrunk,
                outcome => maps:get(outcome, Strict),
                verified => true
            };
        false ->
            #{
                trace => Original,
                original => length(Original),
                shrunk => length(Original),
                tests => S#s.tests,
                ops_shrunk => 0,
                outcome => maps:get(outcome, Strict),
                verified => false
            }
    end.

%% Removes entries, then replaces operations with smaller operations. A smaller
%% operation can make other entries unnecessary, so the two passes repeat until
%% the second pass replaces nothing. Every kept replacement costs one test, so
%% the budget bounds the number of repetitions.
minimise(Trace, S) ->
    {Shorter, S1} = ddmin(Trace, 2, S),
    case shrink_ops(Shorter, S1) of
        {Shorter, S2} -> {Shorter, S2};
        {Smaller, S2} -> minimise(Smaller, S2)
    end.

%% ---------------------------------------------------------------------------
%% The content of an operation
%% ---------------------------------------------------------------------------

%% `shrink_op/1` is an optional callback. The harness is loaded here, because
%% `classify/3` has replayed the trace.
shrink_ops(Trace, S = #s{mod = Mod}) ->
    case erlang:function_exported(Mod, shrink_op, 1) of
        true -> shrink_ops([], Trace, S);
        false -> {Trace, S}
    end.

%% `Done` holds the entries before the current entry, newest first.
shrink_ops(Done, [], S) ->
    {lists:reverse(Done), S};
shrink_ops(Done, [Entry | Rest], S = #s{mod = Mod}) ->
    case eta_run:action(Entry) of
        {op, Op} ->
            case first_smaller(Done, Entry, Mod:shrink_op(Op), Rest, S) of
                %% The kept operation is tried again, so the callback can return
                %% one level of smaller operations at a time.
                {ok, Entry1, S1} -> shrink_ops(Done, [Entry1 | Rest], S1);
                {none, S1} -> shrink_ops([Entry | Done], Rest, S1)
            end;
        _ ->
            shrink_ops([Entry | Done], Rest, S)
    end.

first_smaller(_Done, _Entry, [], _Rest, S) ->
    {none, S};
first_smaller(_Done, _Entry, _Ops, _Rest, S = #s{budget = B}) when B =< 0 ->
    {none, S};
first_smaller(Done, Entry, [Op | Ops], Rest, S) ->
    %% The second element of an entry is the operation. A third element, the ids
    %% of the processes that the operation created, stays as it is.
    Entry1 = setelement(2, Entry, Op),
    case still_fails(lists:reverse(Done, [Entry1 | Rest]), S) of
        {true, S1} -> {ok, Entry1, S1#s{ops_shrunk = S1#s.ops_shrunk + 1}};
        {false, S1} -> first_smaller(Done, Entry, Ops, Rest, S1)
    end.

%% ---------------------------------------------------------------------------
%% Delta debugging
%% ---------------------------------------------------------------------------

%% Standard ddmin: try ever-finer partitions, preferring a failing *subset* (a big
%% jump) over a failing *complement* (removing one chunk), and stop when the
%% granularity cannot increase.
ddmin(Trace, _N, S = #s{budget = B}) when B =< 0 ->
    {Trace, S};
ddmin(Trace, N, S) when length(Trace) >= 2 ->
    Chunks = partition(Trace, min(N, length(Trace))),
    case first_failing(Chunks, S) of
        {ok, Subset, S1} ->
            ddmin(Subset, 2, S1);
        {none, S1} ->
            Complements = [Trace -- C || C <- Chunks],
            case first_failing(Complements, S1) of
                {ok, Complement, S2} ->
                    ddmin(Complement, max(N - 1, 2), S2);
                {none, S2} when N < length(Trace) ->
                    ddmin(Trace, min(2 * N, length(Trace)), S2);
                {none, S2} ->
                    {Trace, S2}
            end
    end;
ddmin(Trace, _N, S) ->
    {Trace, S}.

first_failing([], S) ->
    {none, S};
first_failing([[] | Rest], S) ->
    first_failing(Rest, S);
first_failing([Candidate | Rest], S = #s{budget = B}) when B > 0 ->
    case still_fails(Candidate, S) of
        {true, S1} -> {ok, Candidate, S1};
        {false, S1} -> first_failing(Rest, S1)
    end;
first_failing(_, S) ->
    {none, S}.

still_fails(Candidate, S = #s{mod = Mod, opts = Opts, tests = T, budget = B}) ->
    Result = eta_run:replay(Mod, Candidate, Opts#{lenient => true}),
    S1 = S#s{tests = T + 1, budget = B - 1},
    {matches(maps:get(outcome, Result), S1), S1}.

matches({violation, Detail}, #s{match = Match}) -> Match(Detail);
matches(_, _) -> false.

%% Split into N roughly equal chunks, order preserved.
partition(List, N) ->
    Len = length(List),
    Size = max(1, Len div N),
    chunks(List, Size).

chunks([], _Size) ->
    [];
chunks(List, Size) when length(List) =< Size ->
    [List];
chunks(List, Size) ->
    {Head, Tail} = lists:split(Size, List),
    [Head | chunks(Tail, Size)].

%% ---------------------------------------------------------------------------
%% Matching
%% ---------------------------------------------------------------------------

classify(Mod, Trace, Opts) ->
    maps:get(outcome, eta_run:replay(Mod, Trace, Opts#{lenient => true})).

%% Same `property` when the system reports one, any violation otherwise. The
%% fallback is the honest default rather than a good one — see `shrink/3` on why a
%% multi-invariant system should supply `match`.
default_match(#{property := Property}) ->
    fun
        (#{property := P}) -> P =:= Property;
        (_) -> false
    end;
default_match(_) ->
    fun(_) -> true end.
