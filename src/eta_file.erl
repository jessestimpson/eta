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
go through `eta_disk`, so a crash can lose what they did. `prim_file:write_file/2`
is pointed at `write_file/2` for the same reason.

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
    is_regular/1,
    ensure_path/1,
    del_dir_r/1,
    consult/1,
    safe_relative_path/2
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

-if(?DOCATTRS).
-doc "`filelib:ensure_path/1`, in the calling process.".
-endif.
ensure_path(Path) ->
    case is_dir(Path) of
        true ->
            ok;
        false ->
            case ensure_dir(Path) of
                ok ->
                    case prim_file:make_dir(Path) of
                        ok -> ok;
                        {error, eexist} -> ok;
                        Error -> Error
                    end;
                Error ->
                    Error
            end
    end.

-if(?DOCATTRS).
-doc """
`file:del_dir_r/1`, in the calling process. A file is deleted with `delete/1`, so
a running simulated disk records the deletion.
""".
-endif.
del_dir_r(Name) ->
    case prim_file:read_link_info(Name) of
        {ok, #file_info{type = directory}} ->
            case prim_file:list_dir(Name) of
                {ok, Entries} ->
                    Results = [del_dir_r(filename:join(Name, E)) || E <- lists:sort(Entries)],
                    case [E || {error, _} = E <- Results] of
                        [] -> prim_file:del_dir(Name);
                        [Error | _] -> Error
                    end;
                Error ->
                    Error
            end;
        {ok, _} ->
            delete(Name);
        Error ->
            Error
    end.

-if(?DOCATTRS).
-doc "`file:consult/1`, in the calling process.".
-endif.
consult(Name) ->
    case prim_file:read_file(Name) of
        {ok, Bin} ->
            case unicode:characters_to_list(Bin) of
                Chars when is_list(Chars) -> parse_terms(Chars, 1, []);
                _ -> {error, {1, file_io_server, invalid_unicode}}
            end;
        Error ->
            Error
    end.

parse_terms(Chars, Line, Acc) ->
    case erl_scan:tokens([], Chars, Line) of
        {done, {ok, Tokens, End}, Rest} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Term} -> parse_terms(Rest, End, [Term | Acc]);
                {error, Info} -> {error, Info}
            end;
        {done, {eof, _}, _} ->
            {ok, lists:reverse(Acc)};
        {done, {error, Info, _}, _} ->
            {error, Info};
        {more, _} ->
            case string:trim(Chars) of
                "" -> {ok, lists:reverse(Acc)};
                _ -> {error, {Line, erl_parse, ["syntax error before: ", "end_of_file"]}}
            end
    end.

-if(?DOCATTRS).
-doc """
`filelib:safe_relative_path/2`, in the calling process. OTP resolves each
symbolic link with `file:read_link/1`, which is a call to `file_server`. This
function is a copy of the OTP implementation that calls `prim_file:read_link/1`
instead.
""".
-endif.
safe_relative_path(Path, "") ->
    safe_relative_path(Path, ".");
safe_relative_path(Path, Cwd) ->
    srp_path(filename:split(Path), Cwd, sets:new(), []).

srp_path([], _Cwd, _Seen, []) ->
    "";
srp_path([], _Cwd, _Seen, Acc) ->
    filename:join(Acc);
srp_path([Dot | Segs], Cwd, Seen, Acc) when Dot =:= "."; Dot =:= <<".">> ->
    srp_path(Segs, Cwd, Seen, Acc);
srp_path([DotDot | _Segs], _Cwd, _Seen, []) when DotDot =:= ".."; DotDot =:= <<"..">> ->
    unsafe;
srp_path([DotDot | Segs], Cwd, Seen, [_ | _] = Acc) when DotDot =:= ".."; DotDot =:= <<"..">> ->
    srp_path(Segs, Cwd, Seen, lists:droplast(Acc));
srp_path([clear | Segs], Cwd, _Seen, Acc) ->
    srp_path(Segs, Cwd, sets:new(), Acc);
srp_path([Seg | _] = Segs, Cwd, Seen, Acc) ->
    case filename:pathtype(Seg) of
        relative -> srp_segment(Segs, Cwd, Seen, Acc);
        _ -> unsafe
    end.

srp_segment([Seg | Segs], Cwd, Seen, Acc) ->
    Path = filename:join([Cwd | Acc]),
    case prim_file:read_link(filename:join(Path, Seg)) of
        {ok, LinkPath} ->
            FullLinkPath = filename:join(Path, LinkPath),
            case sets:is_element(FullLinkPath, Seen) of
                true ->
                    unsafe;
                false ->
                    srp_path(
                        filename:split(LinkPath) ++ [clear | Segs],
                        Cwd,
                        sets:add_element(FullLinkPath, Seen),
                        Acc
                    )
            end;
        {error, _} ->
            srp_path(Segs, Cwd, Seen, Acc ++ [Seg])
    end.
