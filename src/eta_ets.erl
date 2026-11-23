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

## Table files

`ets:tab2file/2,3` and `ets:file2tab/1,2` are pointed here too. OTP implements
them with `disk_log`. `disk_log` runs each open log in a process of its own,
started under `kernel` by `disk_log_sup`. A scheduled process that writes a table
to a file therefore waits on processes that the scheduler does not own, and the
start of the log process goes through `supervisor` from outside the schedule.

While a scheduler is active, `tab2file` writes the options and the rows of the
table to the file with `prim_file`, in the calling process, and `file2tab` reads
them back into a new table. A named table is created in the namespace of the
calling process (see `eta_ns`). The file is the format of this module, not the
format of `disk_log`: a file written here is read back only by this module. The
options of `tab2file/3` and `file2tab/2` are accepted and ignored.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([tab2list/1, select/2, match/2, match_object/2, foldl/3]).
-export([tab2file/2, tab2file/3, file2tab/1, file2tab/2]).

-define(FILE_TAG, eta_ets_tab).
-define(FILE_VERSION, 1).

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

-if(?DOCATTRS).
-doc "`ets:tab2file/2`, in the calling process under a run.".
-endif.
-spec tab2file(ets:table(), file:name()) -> ok | {error, term()}.
tab2file(Table, File) ->
    tab2file(Table, File, []).

-if(?DOCATTRS).
-doc "`ets:tab2file/3`, in the calling process under a run. The options are ignored under a run.".
-endif.
-spec tab2file(ets:table(), file:name(), list()) -> ok | {error, term()}.
tab2file(Table, File, Options) ->
    case eta_sched:active() of
        false ->
            ets:tab2file(Table, File, Options);
        true ->
            case ets:info(Table) of
                undefined ->
                    {error, badtab};
                Info ->
                    Named = proplists:get_value(named_table, Info),
                    Opts =
                        [
                            proplists:get_value(type, Info),
                            proplists:get_value(protection, Info),
                            {keypos, proplists:get_value(keypos, Info)},
                            {read_concurrency, proplists:get_value(read_concurrency, Info)},
                            {write_concurrency, proplists:get_value(write_concurrency, Info)}
                        ] ++
                            [named_table || Named] ++
                            [compressed || proplists:get_value(compressed, Info)],
                    Name = local_name(proplists:get_value(name, Info)),
                    Bin = term_to_binary(
                        {?FILE_TAG, ?FILE_VERSION, Name, Opts, ets:tab2list(Table)}
                    ),
                    prim_file:write_file(File, Bin)
            end
    end.

-if(?DOCATTRS).
-doc "`ets:file2tab/1`, in the calling process under a run.".
-endif.
-spec file2tab(file:name()) -> {ok, ets:table()} | {error, term()}.
file2tab(File) ->
    file2tab(File, []).

-if(?DOCATTRS).
-doc "`ets:file2tab/2`, in the calling process under a run. The options are ignored under a run.".
-endif.
-spec file2tab(file:name(), list()) -> {ok, ets:table()} | {error, term()}.
file2tab(File, Options) ->
    case eta_sched:active() of
        false ->
            ets:file2tab(File, Options);
        true ->
            case prim_file:read_file(File) of
                {ok, Bin} ->
                    try binary_to_term(Bin) of
                        {?FILE_TAG, ?FILE_VERSION, Name, Opts, Rows} ->
                            Table = eta_ns:ets_new(Name, Opts),
                            true = ets:insert(eta_ns:tab(Table), Rows),
                            {ok, Table};
                        _ ->
                            {error, {read_error, {not_a_log_file, File}}}
                    catch
                        error:badarg -> {error, {read_error, {not_a_log_file, File}}}
                    end;
                {error, Reason} ->
                    {error, {read_error, {file_error, File, Reason}}}
            end
    end.

%% The name of a named table without the prefix of the namespace of the
%% calling node, so that `file2tab/1` creates the table in the namespace of the
%% node that reads the file.
local_name(Name) ->
    case eta_net:local_node() of
        undefined ->
            Name;
        Node ->
            Prefix = atom_to_list(Node) ++ "/",
            case lists:prefix(Prefix, atom_to_list(Name)) of
                true -> list_to_atom(lists:nthtail(length(Prefix), atom_to_list(Name)));
                false -> Name
            end
    end.

stable(Table, Rows) ->
    case hashed_under_run(Table) of
        true -> lists:sort(Rows);
        false -> Rows
    end.

hashed_under_run(Table) ->
    eta_sched:active() andalso ets:info(Table, type) =/= ordered_set.
