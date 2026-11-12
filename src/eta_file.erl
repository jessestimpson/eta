-module(eta_file).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
The `file` and `filelib` functions that would ask `file_server`, done in the
calling process instead.

`file:read_file/1`, `file:make_dir/1` and their kin are calls into
`file_server_2`, one process per VM that the scheduler doesn't own. A process
making one under a run waits on something outside the schedule, so when it
continues is up to the wall clock. `prim_file` does the same work in the calling
process, and `eta_transform` points these calls at it. The answers are the same,
apart from a relative path being resolved against the VM's working directory
either way.

Inert in the sense that matters: with no run, the result is still what `file`
would return.

While a simulated disk is running, `write_file/2,3`, `delete/1` and `rename/2`
go through `eta_disk`, so a crash can lose what they did.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    read_file/1,
    write_file/2,
    write_file/3,
    make_dir/1,
    del_dir/1,
    delete/1,
    rename/2,
    list_dir/1,
    read_file_info/1,
    read_file_info/2,
    read_link_info/1,
    read_link_info/2,
    get_cwd/0,
    ensure_dir/1,
    is_file/1,
    is_dir/1,
    is_regular/1
]).

-include_lib("kernel/include/file.hrl").

-if(?DOCATTRS).
-doc "`file:read_file/1`, in the calling process.".
-endif.
read_file(Name) -> prim_file:read_file(Name).

-if(?DOCATTRS).
-doc "`file:write_file/2`, in the calling process.".
-endif.
write_file(Name, Bytes) ->
    case eta_disk:running() of
        true -> eta_disk:write_file(Name, Bytes);
        false -> prim_file:write_file(Name, Bytes)
    end.

-if(?DOCATTRS).
-doc """
`file:write_file/3`, in the calling process. Only the plain write is supported
here; any mode other than `raw`, `binary` or `write` goes to `file`.
""".
-endif.
write_file(Name, Bytes, Modes) ->
    case Modes -- [raw, binary, write] of
        [] -> write_file(Name, Bytes);
        _ -> file:write_file(Name, Bytes, Modes)
    end.

-if(?DOCATTRS).
-doc "`file:make_dir/1`, in the calling process.".
-endif.
make_dir(Name) -> prim_file:make_dir(Name).

-if(?DOCATTRS).
-doc "`file:del_dir/1`, in the calling process.".
-endif.
del_dir(Name) -> prim_file:del_dir(Name).

-if(?DOCATTRS).
-doc "`file:delete/1`, in the calling process.".
-endif.
delete(Name) ->
    case eta_disk:running() of
        true -> eta_disk:delete(Name);
        false -> prim_file:delete(Name)
    end.

-if(?DOCATTRS).
-doc "`file:rename/2`, in the calling process.".
-endif.
rename(From, To) ->
    case eta_disk:running() of
        true -> eta_disk:rename(From, To);
        false -> prim_file:rename(From, To)
    end.

-if(?DOCATTRS).
-doc "`file:list_dir/1`, in the calling process.".
-endif.
list_dir(Name) -> prim_file:list_dir(Name).

-if(?DOCATTRS).
-doc "`file:read_file_info/1`, in the calling process.".
-endif.
read_file_info(Name) -> prim_file:read_file_info(Name).

-if(?DOCATTRS).
-doc "`file:read_file_info/2`, in the calling process.".
-endif.
read_file_info(Name, Opts) -> prim_file:read_file_info(Name, Opts).

-if(?DOCATTRS).
-doc "`file:read_link_info/1`, in the calling process.".
-endif.
read_link_info(Name) -> prim_file:read_link_info(Name).

-if(?DOCATTRS).
-doc "`file:read_link_info/2`, in the calling process.".
-endif.
read_link_info(Name, Opts) -> prim_file:read_link_info(Name, Opts).

-if(?DOCATTRS).
-doc "`file:get_cwd/0`, in the calling process.".
-endif.
get_cwd() -> prim_file:get_cwd().

-if(?DOCATTRS).
-doc "`filelib:ensure_dir/1`, in the calling process.".
-endif.
ensure_dir(Name) ->
    Dir = filename:dirname(Name),
    case is_dir(Dir) of
        true ->
            ok;
        false when Dir =:= Name ->
            ok;
        false ->
            case ensure_dir(Dir) of
                ok ->
                    case prim_file:make_dir(Dir) of
                        ok -> ok;
                        {error, eexist} -> ok;
                        Error -> Error
                    end;
                Error ->
                    Error
            end
    end.

-if(?DOCATTRS).
-doc "`filelib:is_file/1`, in the calling process.".
-endif.
is_file(Name) ->
    case prim_file:read_file_info(Name) of
        {ok, #file_info{type = T}} -> T =:= regular orelse T =:= directory;
        _ -> false
    end.

-if(?DOCATTRS).
-doc "`filelib:is_dir/1`, in the calling process.".
-endif.
is_dir(Name) ->
    case prim_file:read_file_info(Name) of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end.

-if(?DOCATTRS).
-doc "`filelib:is_regular/1`, in the calling process.".
-endif.
is_regular(Name) ->
    case prim_file:read_file_info(Name) of
        {ok, #file_info{type = regular}} -> true;
        _ -> false
    end.
