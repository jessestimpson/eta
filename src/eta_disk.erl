-module(eta_disk).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
A simulated disk: unsynced writes that a crash loses, and file operations that
fail.

A real file keeps every byte that a process wrote, even when the process is
killed. A system that never calls `file:sync/1` therefore passes a simulation
that kills its processes. This module adds the faults that a machine crash and a
failing disk produce, and makes them a function of the seed.

`eta_transform` points these calls here: `file:open/2`, `write/2`, `pwrite/3`,
`truncate/1`, `sync/1`, `datasync/1` and `close/1`. `eta_file` calls this module
for `write_file/2,3`, `delete/1` and `rename/2`.

With no disk running, every function delegates to `file` or `prim_file`. A disk
runs only when a harness starts one, with `eta_disk:start/1` or the `disk`
option of `eta_run:run/2`.

## The model

Every operation is performed on the real file system at once, so every reader
sees the data that was written. The disk records which data is not yet durable:

- **File contents.** The contents of a file are durable as of the last
  successful `sync/1` or `datasync/1` on a handle of that file. The first change
  after a sync saves the durable contents.
- **Directory entries.** Creating, deleting and renaming a file are durable when
  a handle of the parent directory is synced. A handle of a directory is opened
  with the `directory` mode. A sync of a file does not make the directory entry
  of the file durable.

Only handles opened with the `raw` mode are tracked. A call with any other
handle delegates to `file`.

## A crash

`crash/1` applies a machine crash to the files of one node. A file belongs to
the node of the process that changed it. `eta_net:kill_node/2` calls `crash/1`
for the node that it kills, unless the policy sets `lose_on_kill` to `false`.

A crash does the following, in this order:

1. It closes the tracked handles of the node.
2. It keeps a prefix of the directory operations that are not durable, and
   undoes the rest in reverse order.
3. For each file with contents that are not durable, it decides what remains.
   If the file only grew, a prefix of the new bytes remains. Otherwise either
   the durable contents or the current contents remain.

The seed decides the length of each prefix. A third of the decisions keep
everything, a third keep nothing, and a third keep a part. A part of the new
bytes is a torn write.

## Errors

With `error_p` above 0, a tracked `write/2`, `pwrite/3`, `sync/1`,
`datasync/1`, `write_file/2` or `rename/2` fails with that probability.

- A failed write stores a prefix of the data and returns `{error, enospc}`.
- A failed sync returns `{error, eio}`. The contents stay not durable.
- A failed rename does nothing and returns `{error, eio}`.

## Limits

- A tracked sync does not sync the real file. The simulation decides what is
  durable.
- Creating, deleting and renaming a directory are durable at once.
- `position/2` and `read/2` are not redirected. They work on a tracked handle
  as they do on any handle.
- A file that two nodes change is rolled back by the crash of the node that
  changed it first after the last sync.
- A module that the transform did not rewrite uses real handles. A sync through
  such a handle makes nothing durable in the simulation. Recompile every module
  of the system after the transform changes.
- Elixir's `File` module calls `file` from inside the Elixir standard library,
  which the transform does not rewrite unless the module is instrumented.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

%% Lifecycle and policy.
-export([
    start/0,
    start/1,
    stop/0,
    running/0,
    set_policy/1,
    policy/0,
    stats/0
]).

%% Faults a harness injects.
-export([crash/1, node_killed/1]).

%% What `eta_transform` points a module's `file` calls at.
-export([
    open/2,
    write/2,
    pwrite/3,
    truncate/1,
    sync/1,
    datasync/1,
    close/1
]).

%% What `eta_file` calls while a disk is running.
-export([write_file/2, delete/1, rename/2]).

-export_type([policy/0]).

-type policy() :: #{error_p => float(), lose_on_kill => boolean()}.

-define(STATE, eta_disk_state).
%% `{Fd, Path, Node, file | dir}` for each tracked handle.
-define(OPEN, eta_disk_open).
%% `{Path, Node, DurableContents}` for each file whose contents are not durable.
-define(DIRTY, eta_disk_dirty).
%% `{Seq, Dir, Node, Op}` for each directory operation that is not durable.
-define(OPS, eta_disk_ops).

-define(COUNTERS, [
    syncs,
    write_errors,
    sync_errors,
    rename_errors,
    crashes,
    files_kept,
    files_torn,
    files_lost,
    ops_undone
]).

%% ---------------------------------------------------------------------------
%% Lifecycle
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc "Starts a disk with the default policy. See `start/1`.".
-endif.
-spec start() -> ok.
start() ->
    start(#{}).

-if(?DOCATTRS).
-doc """
Starts the disk.

Options:

- `seed` — seeds the fault decisions, so a run replays.
- `policy` — see `set_policy/1`.

One disk per VM, as with `eta_net`, so runs must be serial. Starting over a
running disk resets it.
""".
-endif.
-spec start(#{seed => integer(), policy => policy()}) -> ok.
start(Opts) ->
    stop(),
    ?STATE = ets:new(?STATE, [named_table, public, set]),
    ?OPEN = ets:new(?OPEN, [named_table, public, set]),
    ?DIRTY = ets:new(?DIRTY, [named_table, public, set]),
    ?OPS = ets:new(?OPS, [named_table, public, ordered_set]),
    Seed = maps:get(seed, Opts, 0),
    ets:insert(?STATE, [
        {rand, rand:seed_s(exsss, {Seed + 5, Seed + 17, Seed + 31})},
        {seq, 0},
        {policy, merge_policy(maps:get(policy, Opts, #{}))}
        | [{C, 0} || C <- ?COUNTERS]
    ]),
    ok.

-if(?DOCATTRS).
-doc """
Stops the disk. Safe to call when none is running.

The files stay as they are. Data that was not durable stays in the files.
""".
-endif.
-spec stop() -> ok.
stop() ->
    lists:foreach(
        fun(Tab) ->
            try
                ets:delete(Tab)
            catch
                error:badarg -> ok
            end
        end,
        [?STATE, ?OPEN, ?DIRTY, ?OPS]
    ),
    ok.

-if(?DOCATTRS).
-doc "Whether a disk is running. When false, every function here delegates.".
-endif.
-spec running() -> boolean().
running() ->
    ets:whereis(?STATE) =/= undefined.

-if(?DOCATTRS).
-doc """
Sets the policy.

- `error_p` — the probability that a tracked write, sync or rename fails.
  Defaults to `0.0`.
- `lose_on_kill` — whether `eta_net:kill_node/2` applies `crash/1` to the node
  that it kills. Defaults to `true`.

A key that is absent is set to its default.
""".
-endif.
-spec set_policy(policy()) -> ok.
set_policy(Policy) ->
    ok = require_running(set_policy),
    true = ets:insert(?STATE, {policy, merge_policy(Policy)}),
    ok.

-if(?DOCATTRS).
-doc "The policy in force.".
-endif.
-spec policy() -> policy().
policy() ->
    ets:lookup_element(?STATE, policy, 2).

merge_policy(Policy) ->
    case maps:keys(Policy) -- [error_p, lose_on_kill] of
        [] -> maps:merge(#{error_p => 0.0, lose_on_kill => true}, Policy);
        Unknown -> error({eta_disk, {unknown_policy_keys, Unknown}})
    end.

-if(?DOCATTRS).
-doc """
What the disk did.

- `syncs` — successful syncs of a tracked handle.
- `write_errors`, `sync_errors`, `rename_errors` — injected errors.
- `crashes` — calls to `crash/1`.
- `files_kept`, `files_torn`, `files_lost` — for each file with contents that
  were not durable at a crash: whether all, a part, or none of the new contents
  remained.
- `ops_undone` — directory operations that a crash undid.

A run whose `crashes` is above 0 and whose `files_torn`, `files_lost` and
`ops_undone` are all 0 lost nothing: every crash found only durable data.
""".
-endif.
-spec stats() -> #{atom() => non_neg_integer()}.
stats() ->
    ok = require_running(stats),
    maps:from_list([{C, ets:lookup_element(?STATE, C, 2)} || C <- ?COUNTERS]).

require_running(What) ->
    case running() of
        true -> ok;
        false -> error({eta_disk, {not_running, What}})
    end.

%% ---------------------------------------------------------------------------
%% Crash
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
Applies a machine crash to the files of `Node`. See "A crash" in the module doc.

Call this after the processes of the node are dead. A process that is still
running keeps its handles and may write again.
""".
-endif.
-spec crash(term()) -> ok.
crash(Node) ->
    ok = require_running(crash),
    bump(crashes),
    lists:foreach(
        fun([Fd]) ->
            %% The owner of the handle is dead. The close may be refused for
            %% that reason. The VM closes the file when it collects the handle.
            _ = (catch file:close(Fd)),
            true = ets:delete(?OPEN, Fd)
        end,
        lists:sort(ets:match(?OPEN, {'$1', '_', Node, '_'}))
    ),
    Ops = lists:sort(ets:match_object(?OPS, {'_', '_', Node, '_'})),
    {_Kept, Undone} = lists:split(cut(length(Ops)), Ops),
    lists:foreach(
        fun({_Seq, _Dir, _Node, Op}) ->
            bump(ops_undone),
            undo(Op)
        end,
        lists:reverse(Undone)
    ),
    lists:foreach(fun(Op) -> true = ets:delete_object(?OPS, Op) end, Ops),
    lists:foreach(fun roll_back/1, lists:sort(ets:match_object(?DIRTY, {'_', Node, '_'}))),
    ok.

-if(?DOCATTRS).
-doc false.
-endif.
%% What `eta_net:kill_node/2` calls. A no-op with no disk, or with a policy
%% that keeps the files of a killed node.
-spec node_killed(term()) -> ok.
node_killed(Node) ->
    case running() andalso maps:get(lose_on_kill, policy()) of
        true -> crash(Node);
        false -> ok
    end.

undo({create, Path}) ->
    _ = prim_file:delete(Path),
    true = ets:delete(?DIRTY, Path),
    ok;
undo({delete, Path, Contents}) ->
    _ = prim_file:write_file(Path, Contents),
    ok;
undo({rename, From, To, Overwritten}) ->
    _ = prim_file:rename(To, From),
    ok = move_dirty(To, From),
    case Overwritten of
        none -> ok;
        {contents, Contents} -> _ = prim_file:write_file(To, Contents)
    end,
    ok.

%% Decides what remains of a file whose contents are not durable.
roll_back(Row = {Path, _Node, Durable}) ->
    true = ets:delete_object(?DIRTY, Row),
    Size = byte_size(Durable),
    case prim_file:read_file(Path) of
        {ok, Durable} ->
            %% Nothing changed since the last sync. No decision is made, so no
            %% number is drawn.
            ok;
        {ok, <<Durable:Size/binary, New/binary>>} ->
            case cut(byte_size(New)) of
                Keep when Keep =:= byte_size(New) ->
                    bump(files_kept);
                0 ->
                    bump(files_lost),
                    ok = prim_file:write_file(Path, Durable);
                Keep ->
                    bump(files_torn),
                    ok = prim_file:write_file(Path, [Durable, binary:part(New, 0, Keep)])
            end;
        {ok, _Overwritten} ->
            case draw() < 0.5 of
                true ->
                    bump(files_kept);
                false ->
                    bump(files_lost),
                    ok = prim_file:write_file(Path, Durable)
            end;
        {error, _} ->
            %% The file is gone. A deleted file has no contents to decide.
            ok
    end.

%% How many of `N' items remain after a crash. A third of the answers are all
%% of them, a third are none, and a third are uniform over 0..N. Nothing is
%% drawn when there is nothing to decide.
cut(0) ->
    0;
cut(N) ->
    case draw() of
        P when P < 1 / 3 -> N;
        P when P < 2 / 3 -> 0;
        P -> min(N, trunc((P - 2 / 3) * 3 * (N + 1)))
    end.

%% ---------------------------------------------------------------------------
%% Handles
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
`file:open/2`. A handle opened with the `raw` mode while a disk is running is
tracked. Every other open delegates.
""".
-endif.
-spec open(file:name_all(), [term()]) -> {ok, file:io_device()} | {error, term()}.
open(File, Modes) ->
    case running() andalso is_list(Modes) andalso lists:member(raw, Modes) of
        true -> open_tracked(File, Modes);
        false -> file:open(File, Modes)
    end.

open_tracked(File, Modes) ->
    Path = path(File),
    Node = here(),
    Kind =
        case lists:member(directory, Modes) of
            true -> dir;
            false -> file
        end,
    Existed = exists(Path),
    %% `write' alone empties an existing file as it opens it. The durable
    %% contents are saved before that happens.
    Empties =
        lists:member(write, Modes) andalso
            not lists:member(read, Modes) andalso
            not lists:member(append, Modes),
    _ = Kind =:= file andalso Existed andalso Empties andalso dirty(Path, Node),
    case file:open(File, Modes) of
        {ok, Fd} ->
            _ = Kind =:= file andalso not Existed andalso add_op(Path, Node, {create, Path}),
            true = ets:insert(?OPEN, {Fd, Path, Node, Kind}),
            {ok, Fd};
        Error ->
            Error
    end.

-if(?DOCATTRS).
-doc "`file:write/2`. A write to a tracked handle is not durable until a sync.".
-endif.
-spec write(file:io_device(), iodata()) -> ok | {error, term()}.
write(Fd, Data) ->
    case tracked(Fd) of
        {Path, Node, file} ->
            ok = dirty(Path, Node),
            case fault(write_errors) of
                true ->
                    _ = file:write(Fd, strict_prefix(Data)),
                    {error, enospc};
                false ->
                    file:write(Fd, Data)
            end;
        _ ->
            file:write(Fd, Data)
    end.

-if(?DOCATTRS).
-doc "`file:pwrite/3`. As `write/2`.".
-endif.
-spec pwrite(file:io_device(), term(), iodata()) -> ok | {error, term()}.
pwrite(Fd, Location, Data) ->
    case tracked(Fd) of
        {Path, Node, file} ->
            ok = dirty(Path, Node),
            case fault(write_errors) of
                true ->
                    _ = file:pwrite(Fd, Location, strict_prefix(Data)),
                    {error, enospc};
                false ->
                    file:pwrite(Fd, Location, Data)
            end;
        _ ->
            file:pwrite(Fd, Location, Data)
    end.

-if(?DOCATTRS).
-doc "`file:truncate/1`. The cut is not durable until a sync.".
-endif.
-spec truncate(file:io_device()) -> ok | {error, term()}.
truncate(Fd) ->
    case tracked(Fd) of
        {Path, Node, file} -> ok = dirty(Path, Node);
        _ -> ok
    end,
    file:truncate(Fd).

-if(?DOCATTRS).
-doc """
`file:sync/1`. A sync of a tracked file makes the contents of the file durable.
A sync of a tracked directory makes the directory operations in it durable. The
real file is not synced.
""".
-endif.
-spec sync(file:io_device()) -> ok | {error, term()}.
sync(Fd) ->
    sync(Fd, fun file:sync/1).

-if(?DOCATTRS).
-doc "`file:datasync/1`. As `sync/1`.".
-endif.
-spec datasync(file:io_device()) -> ok | {error, term()}.
datasync(Fd) ->
    sync(Fd, fun file:datasync/1).

sync(Fd, Real) ->
    case tracked(Fd) of
        untracked ->
            Real(Fd);
        {Path, _Node, Kind} ->
            case fault(sync_errors) of
                true ->
                    {error, eio};
                false ->
                    bump(syncs),
                    case Kind of
                        file -> true = ets:delete(?DIRTY, Path);
                        dir -> true = ets:match_delete(?OPS, {'_', Path, '_', '_'})
                    end,
                    ok
            end
    end.

-if(?DOCATTRS).
-doc "`file:close/1`. A close does not make anything durable.".
-endif.
-spec close(file:io_device()) -> ok | {error, term()}.
close(Fd) ->
    _ = running() andalso ets:delete(?OPEN, Fd),
    file:close(Fd).

tracked(Fd) ->
    case running() andalso ets:lookup(?OPEN, Fd) of
        [{_Fd, Path, Node, Kind}] -> {Path, Node, Kind};
        _ -> untracked
    end.

%% ---------------------------------------------------------------------------
%% Whole files. `eta_file` calls these while a disk is running.
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc false.
-endif.
-spec write_file(file:name_all(), iodata()) -> ok | {error, term()}.
write_file(Name, Bytes) ->
    Path = path(Name),
    Node = here(),
    Existed = exists(Path),
    ok = dirty(Path, Node),
    Result =
        case fault(write_errors) of
            true ->
                _ = prim_file:write_file(Name, strict_prefix(Bytes)),
                {error, enospc};
            false ->
                prim_file:write_file(Name, Bytes)
        end,
    _ = not Existed andalso exists(Path) andalso add_op(Path, Node, {create, Path}),
    Result.

-if(?DOCATTRS).
-doc false.
-endif.
-spec delete(file:name_all()) -> ok | {error, term()}.
delete(Name) ->
    Path = path(Name),
    Durable = durable(Path),
    case prim_file:delete(Name) of
        ok ->
            true = ets:delete(?DIRTY, Path),
            _ = is_binary(Durable) andalso add_op(Path, here(), {delete, Path, Durable}),
            ok;
        Error ->
            Error
    end.

-if(?DOCATTRS).
-doc false.
-endif.
-spec rename(file:name_all(), file:name_all()) -> ok | {error, term()}.
rename(From0, To0) ->
    From = path(From0),
    To = path(To0),
    case is_regular(From) of
        false ->
            %% A directory. See "Limits" in the module doc.
            prim_file:rename(From0, To0);
        true ->
            case fault(rename_errors) of
                true ->
                    {error, eio};
                false ->
                    Overwritten =
                        case durable(To) of
                            none -> none;
                            Contents -> {contents, Contents}
                        end,
                    case prim_file:rename(From0, To0) of
                        ok ->
                            true = ets:delete(?DIRTY, To),
                            ok = move_dirty(From, To),
                            ok = move_open(From, To),
                            add_op(To, here(), {rename, From, To, Overwritten}),
                            ok;
                        Error ->
                            Error
                    end
            end
    end.

%% ---------------------------------------------------------------------------
%% Internals
%% ---------------------------------------------------------------------------

%% Saves the durable contents of a file before its first change since the
%% last sync. A file that does not exist has the durable contents `<<>>`: if
%% a crash keeps the creation of the file and loses the contents, the file is
%% empty.
dirty(Path, Node) ->
    case ets:member(?DIRTY, Path) of
        true ->
            ok;
        false ->
            Contents =
                case prim_file:read_file(Path) of
                    {ok, Bin} -> Bin;
                    {error, _} -> <<>>
                end,
            true = ets:insert(?DIRTY, {Path, Node, Contents}),
            ok
    end.

%% The durable contents of a file, or `none' if the file does not exist.
durable(Path) ->
    case ets:lookup(?DIRTY, Path) of
        [{_Path, _Node, Contents}] ->
            Contents;
        [] ->
            case is_regular(Path) andalso prim_file:read_file(Path) of
                {ok, Bin} -> Bin;
                _ -> none
            end
    end.

move_dirty(From, To) ->
    case ets:take(?DIRTY, From) of
        [{_From, Node, Contents}] -> true = ets:insert(?DIRTY, {To, Node, Contents});
        [] -> true
    end,
    ok.

%% An open handle follows its file through a rename.
move_open(From, To) ->
    lists:foreach(
        fun({Fd, _Path, Node, Kind}) -> true = ets:insert(?OPEN, {Fd, To, Node, Kind}) end,
        ets:match_object(?OPEN, {'_', From, '_', '_'})
    ),
    ok.

add_op(Path, Node, Op) ->
    Seq = ets:update_counter(?STATE, seq, 1),
    true = ets:insert(?OPS, {Seq, filename:dirname(Path), Node, Op}),
    ok.

%% The key of a file: its absolute name, as a binary. `filename:absname/1`
%% asks `file_server' for the working directory, so the working directory is
%% read with `prim_file'.
path(Name) ->
    {ok, Cwd} = prim_file:get_cwd(),
    unicode:characters_to_binary(filename:absname(filename:flatten(Name), Cwd)).

exists(Path) ->
    case prim_file:read_file_info(Path) of
        {ok, _} -> true;
        {error, _} -> false
    end.

is_regular(Path) ->
    eta_file:is_regular(Path).

%% The node whose files the calling process changes.
here() ->
    case eta_net:running() of
        true -> eta_net:node();
        false -> erlang:node()
    end.

%% Whether this operation fails. The generator advances only when the policy
%% could make the operation fail.
fault(Counter) ->
    case maps:get(error_p, policy()) of
        P when P > 0.0 ->
            case draw() < P of
                true ->
                    bump(Counter),
                    true;
                false ->
                    false
            end;
        _ ->
            false
    end.

%% A prefix of the data that is shorter than the data.
strict_prefix(Data) ->
    Bin = iolist_to_binary(Data),
    binary:part(Bin, 0, trunc(draw() * byte_size(Bin))).

%% Read-modify-write on the generator. This is safe because one process runs
%% at a time under `eta_sched'.
draw() ->
    {P, Next} = rand:uniform_s(ets:lookup_element(?STATE, rand, 2)),
    true = ets:insert(?STATE, {rand, Next}),
    P.

bump(Counter) ->
    _ = ets:update_counter(?STATE, Counter, 1),
    ok.
