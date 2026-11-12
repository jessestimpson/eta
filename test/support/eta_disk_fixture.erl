-module(eta_disk_fixture).

%% File operations as a system writes them, for exercising `eta_disk`.
%%
%% Every call to `file' in this module is rewritten by `eta_transform'. The
%% tests call these functions, and never call `eta_disk' for the operations
%% themselves, so that the tests also show that the transform reaches the
%% calls.

-include_lib("eta/include/eta.hrl").

-export([append/3, overwrite/3, replace/3, create/2, remove/2, read/1]).

%% Appends `Data' to `File'. Syncs the file if `Sync' is true.
append(File, Data, Sync) ->
    {ok, Fd} = file:open(File, [append, raw, binary]),
    Result = file:write(Fd, Data),
    SyncResult =
        case Sync of
            true -> file:datasync(Fd);
            false -> ok
        end,
    ok = file:close(Fd),
    {Result, SyncResult}.

%% Writes `Data' at the start of `File', over what is there.
overwrite(File, Data, Sync) ->
    {ok, Fd} = file:open(File, [read, write, raw, binary]),
    ok = file:pwrite(Fd, 0, Data),
    ok = file:truncate(position(Fd, byte_size(Data))),
    _ = Sync andalso (ok = file:sync(Fd)),
    ok = file:close(Fd).

position(Fd, Offset) ->
    {ok, Offset} = file:position(Fd, Offset),
    Fd.

%% Replaces the contents of `File' with a temporary file and a rename, the
%% way a system writes a file atomically. `Sync' is `none', `file' (the
%% temporary file is synced) or `all' (the directory is synced as well).
replace(File, Data, Sync) ->
    Tmp = File ++ ".tmp",
    {ok, Fd} = file:open(Tmp, [write, raw, binary]),
    ok = file:write(Fd, Data),
    _ = Sync =/= none andalso (ok = file:sync(Fd)),
    ok = file:close(Fd),
    case file:rename(Tmp, File) of
        ok ->
            _ = Sync =:= all andalso (ok = sync_dir(filename:dirname(File))),
            ok;
        Error ->
            Error
    end.

%% Creates `File' with `write_file'. Syncs the directory if `SyncDir' is true.
create(File, SyncDir) ->
    ok = file:write_file(File, <<"created">>),
    _ = SyncDir andalso (ok = sync_dir(filename:dirname(File))),
    ok.

remove(File, SyncDir) ->
    ok = file:delete(File),
    _ = SyncDir andalso (ok = sync_dir(filename:dirname(File))),
    ok.

read(File) ->
    file:read_file(File).

sync_dir(Dir) ->
    {ok, Fd} = file:open(Dir, [read, raw, directory]),
    Result = file:sync(Fd),
    ok = file:close(Fd),
    Result.
