-module(eta_ets).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
Iteration order for hash-based ETS tables, made a function of the data.

A `set`, `bag` or `duplicate_bag` table hands its rows over in hash order. For an
atom or an integer key that order is stable. For a key holding a reference or a
pid it is not: the bits being hashed differ from one VM to the next, so two runs
of a seed visit the rows in a different order. A system that sends a message per
row then sends them in a different order, and a seed stops reproducing itself.

Nothing in a run result says so. No process escaped the schedule and no clock was
read, so `eta_run:audit/1` passes, and a strict replay in the same VM usually
passes too. It shows up as a seed that fails on one machine and not on another.

`eta_transform` points a module's iterating `ets` calls here. While a scheduler is
active, results from a hash-based table come back sorted. An `ordered_set` is passed
straight through, since it has an order of its own that code may depend on.

Sorting is only stable in a VM started with one scheduler, `+S 1:1`. How 2 references
compare depends on the scheduler threads that made them, so with several threads a
seed can still fork. Setting `schedulers_online` once the VM is running is not enough.

Inert unless a scheduler is active: every function delegates to `ets` otherwise.

`first/1`, `next/2` and the continuation forms of `select` are left alone. They
walk a table one step at a time, and sorting cannot be done from inside that walk.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([tab2list/1, select/2, match/2, match_object/2, foldl/3]).

-if(?DOCATTRS).
-doc "`ets:tab2list/1`, in a stable order under a run.".
-endif.
-spec tab2list(ets:table()) -> [tuple()].
tab2list(Table) ->
    stable(Table, ets:tab2list(Table)).

-if(?DOCATTRS).
-doc "`ets:select/2`, in a stable order under a run.".
-endif.
-spec select(ets:table(), ets:match_spec()) -> [term()].
select(Table, MatchSpec) ->
    stable(Table, ets:select(Table, MatchSpec)).

-if(?DOCATTRS).
-doc "`ets:match/2`, in a stable order under a run.".
-endif.
-spec match(ets:table(), ets:match_pattern()) -> [[term()]].
match(Table, Pattern) ->
    stable(Table, ets:match(Table, Pattern)).

-if(?DOCATTRS).
-doc "`ets:match_object/2`, in a stable order under a run.".
-endif.
-spec match_object(ets:table(), ets:match_pattern()) -> [tuple()].
match_object(Table, Pattern) ->
    stable(Table, ets:match_object(Table, Pattern)).

-if(?DOCATTRS).
-doc "`ets:foldl/3`, visiting rows in a stable order under a run.".
-endif.
-spec foldl(fun((tuple(), Acc) -> Acc), Acc, ets:table()) -> Acc.
foldl(Fun, Acc, Table) ->
    case hashed_under_run(Table) of
        true -> lists:foldl(Fun, Acc, lists:sort(ets:tab2list(Table)));
        false -> ets:foldl(Fun, Acc, Table)
    end.

stable(Table, Rows) ->
    case hashed_under_run(Table) of
        true -> lists:sort(Rows);
        false -> Rows
    end.

hashed_under_run(Table) ->
    eta_sched:active() andalso ets:info(Table, type) =/= ordered_set.
