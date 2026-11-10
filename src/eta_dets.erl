-module(eta_dets).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
DETS, in the calling process.

A real DETS table is served by a process of its own, started under `kernel` and
registered with `dets_server`. Every `dets` call is a message to it and a wait for
the reply, so under a run each one waits on a process the scheduler doesn't own,
and the names of the tables are one namespace for the whole VM.

`eta_transform` points the `dets` calls a system makes here. A table is an ETS
table of its own, named in the opening process's namespace (see `eta_ns`), and every change writes
the whole table to the table's file before the call returns, with `prim_file` in
the calling process. Reopening a table reads that file, so a table survives a
node being killed and rebooted the way a file on disk does.

## The fault model, and its limits

Every change is durable when the call returns: there is no window in which a
crash loses a write that `dets` would have buffered. That is stronger than DETS,
which writes through its own cache and repairs on reopen, so a bug that only
appears when an unsynced write is lost will not appear here. It is the right
default for a system that calls `dets:sync/1` after the writes it needs to keep,
as Raft implementations do for their term and vote.

The file is this module's own format, not DETS's: a table written here is read
back only by this module.

`open_file/2` honours `file`, `type` and `keypos`. Other options are accepted and
ignored. Functions not listed here raise while a scheduler is active.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    open_file/2,
    close/1,
    sync/1,
    lookup/2,
    member/2,
    insert/2,
    delete/2,
    delete_all_objects/1,
    select/2,
    select_delete/2,
    foldl/3,
    to_ets/2,
    info/2
]).

%% Where each open table's file is, by its real name.
-define(FILE_KEY(Tab), {?MODULE, file, Tab}).

-if(?DOCATTRS).
-doc "`dets:open_file/2`. See the module doc.".
-endif.
-spec open_file(atom(), list()) -> {ok, atom()} | {error, term()}.
open_file(Name, Opts) ->
    Tab = tab(Name),
    File = proplists:get_value(file, Opts, atom_to_list(Name)),
    case ets:whereis(Tab) of
        undefined ->
            Type = proplists:get_value(type, Opts, set),
            KeyPos = proplists:get_value(keypos, Opts, 1),
            _ = ets:new(Tab, [named_table, public, Type, {keypos, KeyPos}]),
            persistent_term:put(?FILE_KEY(Tab), File),
            case prim_file:read_file(File) of
                {ok, Bin} ->
                    {Type, KeyPos, Objects} = binary_to_term(Bin),
                    true = ets:insert(Tab, Objects);
                {error, enoent} ->
                    ok = persist(Tab)
            end,
            {ok, Name};
        _ ->
            {ok, Name}
    end.

-if(?DOCATTRS).
-doc "`dets:close/1`. The table is gone from this namespace; its file stays.".
-endif.
-spec close(atom()) -> ok.
close(Name) ->
    Tab = tab(Name),
    ok = persist(Tab),
    true = ets:delete(Tab),
    _ = persistent_term:erase(?FILE_KEY(Tab)),
    ok.

-if(?DOCATTRS).
-doc "`dets:sync/1`. Every change is already written, so this writes it again.".
-endif.
-spec sync(atom()) -> ok.
sync(Name) -> persist(tab(Name)).

-if(?DOCATTRS).
-doc "`dets:lookup/2`.".
-endif.
lookup(Name, Key) -> ets:lookup(tab(Name), Key).

-if(?DOCATTRS).
-doc "`dets:member/2`.".
-endif.
member(Name, Key) -> ets:member(tab(Name), Key).

-if(?DOCATTRS).
-doc "`dets:insert/2`, written before it returns.".
-endif.
insert(Name, Objects) -> change(Name, fun(T) -> ets:insert(T, Objects) end).

-if(?DOCATTRS).
-doc "`dets:delete/2`, written before it returns.".
-endif.
delete(Name, Key) -> change(Name, fun(T) -> ets:delete(T, Key) end).

-if(?DOCATTRS).
-doc "`dets:delete_all_objects/1`, written before it returns.".
-endif.
delete_all_objects(Name) -> change(Name, fun ets:delete_all_objects/1).

-if(?DOCATTRS).
-doc "`dets:select/2`, in a stable order under a run. See `eta_ets`.".
-endif.
select(Name, Spec) -> eta_ets:select(tab(Name), Spec).

-if(?DOCATTRS).
-doc "`dets:select_delete/2`, written before it returns.".
-endif.
select_delete(Name, Spec) ->
    Tab = tab(Name),
    N = ets:select_delete(Tab, Spec),
    ok = persist(Tab),
    N.

-if(?DOCATTRS).
-doc "`dets:foldl/3`, in a stable order under a run. See `eta_ets`.".
-endif.
foldl(Fun, Acc, Name) -> eta_ets:foldl(Fun, Acc, tab(Name)).

-if(?DOCATTRS).
-doc "`dets:to_ets/2`: every object, inserted into `EtsTab`.".
-endif.
to_ets(Name, EtsTab) ->
    true = ets:insert(eta_ns:tab(EtsTab), ets:tab2list(tab(Name))),
    EtsTab.

-if(?DOCATTRS).
-doc "`dets:info/2`, for the items ETS can answer and `filename`.".
-endif.
info(Name, filename) -> persistent_term:get(?FILE_KEY(tab(Name)), undefined);
info(Name, Item) -> ets:info(tab(Name), Item).

%% The ETS table holding a DETS table's objects. DETS names and ETS names are
%% separate namespaces, and a system may use one atom for both, as ra does with
%% `dets:to_ets(Tab, Tab)`, so the storage gets a name of its own.
tab(Name) -> binary_to_atom(<<"$dets/", (atom_to_binary(eta_ns:name(Name)))/binary>>).

change(Name, Fun) ->
    Tab = tab(Name),
    true = Fun(Tab),
    persist(Tab).

persist(Tab) ->
    File = persistent_term:get(?FILE_KEY(Tab)),
    Bin = term_to_binary({ets:info(Tab, type), ets:info(Tab, keypos), ets:tab2list(Tab)}),
    prim_file:write_file(File, Bin).
