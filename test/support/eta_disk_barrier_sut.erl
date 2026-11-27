-module(eta_disk_barrier_sut).
-behaviour(eta_harness).

%% A harness for the `barrier' policy of `eta_disk'. Run it with the option
%% `disk => #{policy => #{sync => barrier}}'.
%%
%% An operation appends to one of 2 files, syncs one of the files, or calls
%% `eta_disk:flush/0'. A scheduled process performs each operation and records
%% the operation in an ETS table. The table therefore holds the operations in
%% the order in which they ran.
%%
%% `check_final/2' crashes the disk of the node and reads the 2 files. It
%% computes a model from the recorded operations:
%%
%% - the contents of each file at the last flush
%% - the syncs after the last flush, oldest first, as `{File, Contents}'
%%
%% The crash must leave the flushed contents and the first K syncs, for some K
%% from 0 to the number of syncs. Every other state is the violation
%% `barrier_prefix': a torn write, data that no sync recorded, a later sync
%% without an earlier one, or a loss of flushed data.

-export([init/2, processes/1, generate/2, execute/2, check/1, check_final/2, terminate/1]).
-export([shrink_op/1]).

-define(FILES, [a, b]).

init(Seed, #{dir := Base}) ->
    Dir = filename:join(Base, [
        integer_to_list(Seed), $-, integer_to_list(erlang:unique_integer([positive]))
    ]),
    ok = filelib:ensure_path(Dir),
    %% The files exist and are empty before an operation runs. `prim_file' is
    %% not tracked, so the creation and the empty contents are durable.
    Paths = maps:from_list([{F, filename:join(Dir, atom_to_list(F))} || F <- ?FILES]),
    maps:foreach(fun(_F, Path) -> ok = prim_file:write_file(Path, <<>>) end, Paths),
    Log = ets:new(?MODULE, [public, ordered_set]),
    {ok, #{dir => Dir, paths => Paths, log => Log, next => 1, procs => []}}.

processes(#{procs := Procs}) ->
    Procs.

%% 5 of 10 operations append, 4 sync and 1 flushes.
generate(#{next := N}, Rand0) ->
    {Kind, Rand1} = rand:uniform_s(10, Rand0),
    {FileNo, Rand2} = rand:uniform_s(length(?FILES), Rand1),
    File = lists:nth(FileNo, ?FILES),
    Op =
        if
            Kind =< 5 -> {append, File, <<(integer_to_binary(N))/binary, $.>>};
            Kind =< 9 -> {sync, File};
            true -> flush
        end,
    {Op, Rand2}.

execute(Op, Sut = #{paths := Paths, log := Log, next := N, procs := Procs}) ->
    Pid = eta_run:spawn_op(fun() ->
        ok = perform(Op, Paths),
        true = ets:insert(Log, {ets:info(Log, size) + 1, Op})
    end),
    Sut#{next := N + 1, procs := Procs ++ [Pid]}.

%% The calls go to `eta_disk' directly, as the calls of a transformed module
%% do. An operation has no `receive', so it runs in one step.
perform({append, File, Data}, Paths) ->
    {ok, Fd} = eta_disk:open(maps:get(File, Paths), [append, raw, binary]),
    ok = eta_disk:write(Fd, Data),
    eta_disk:close(Fd);
perform({sync, File}, Paths) ->
    {ok, Fd} = eta_disk:open(maps:get(File, Paths), [append, raw, binary]),
    ok = eta_disk:datasync(Fd),
    eta_disk:close(Fd);
perform(flush, _Paths) ->
    eta_disk:flush().

check(_Sut) ->
    ok.

check_final(_Settled, #{paths := Paths, log := Log}) ->
    Ops = [Op || {_Seq, Op} <- ets:tab2list(Log)],
    ok = eta_disk:crash(node()),
    After = maps:map(
        fun(_File, Path) ->
            {ok, Contents} = prim_file:read_file(Path),
            Contents
        end,
        Paths
    ),
    Allowed = allowed(lists:foldl(fun model/2, model(), Ops)),
    case lists:member(After, Allowed) of
        true ->
            ok;
        false ->
            {violation, #{property => barrier_prefix, found => After, allowed => Allowed, ops => Ops}}
    end.

terminate(#{dir := Dir, log := Log, procs := Procs}) ->
    %% An operation that the run did not step would run now, after the table
    %% and the files are gone.
    lists:foreach(fun(Pid) -> exit(Pid, kill) end, Procs),
    catch ets:delete(Log),
    _ = file:del_dir_r(Dir),
    ok.

%% An operation on the file `b' is tried on the file `a'. A failure that needs
%% one file only then shrinks to one file.
shrink_op({append, b, Data}) -> [{append, a, Data}];
shrink_op({sync, b}) -> [{sync, a}];
shrink_op(_Op) -> [].

%% ---------------------------------------------------------------------------
%% The model
%% ---------------------------------------------------------------------------

model() ->
    Empty = maps:from_list([{F, <<>>} || F <- ?FILES]),
    #{now => Empty, flushed => Empty, syncs => []}.

model({append, File, Data}, M = #{now := Now}) ->
    M#{now := Now#{File := <<(maps:get(File, Now))/binary, Data/binary>>}};
model({sync, File}, M = #{now := Now, flushed := Flushed, syncs := Syncs}) ->
    Contents = maps:get(File, Now),
    %% A sync that finds the contents of the previous sync of the file, or the
    %% flushed contents when the file has no sync, records nothing.
    case recorded(File, Syncs, Flushed) of
        Contents -> M;
        _ -> M#{syncs := Syncs ++ [{File, Contents}]}
    end;
model(flush, M = #{flushed := Flushed, syncs := Syncs}) ->
    M#{flushed := maps:merge(Flushed, maps:from_list(Syncs)), syncs := []}.

recorded(File, Syncs, Flushed) ->
    case [Contents || {F, Contents} <- Syncs, F =:= File] of
        [] -> maps:get(File, Flushed);
        Recorded -> lists:last(Recorded)
    end.

%% The states that a crash may leave: the flushed contents and the first K
%% syncs, for each K.
allowed(#{flushed := Flushed, syncs := Syncs}) ->
    [
        maps:merge(Flushed, maps:from_list(lists:sublist(Syncs, K)))
     || K <- lists:seq(0, length(Syncs))
    ].
