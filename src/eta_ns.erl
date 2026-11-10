-module(eta_ns).

%% `register/2`, `unregister/1`, `whereis/1`, `registered/0` and `process_info/2`
%% are the API names, shadowing the auto-imported BIFs. The originals are always
%% reached qualified.
-compile(
    {no_auto_import, [register/2, unregister/1, whereis/1, registered/0, process_info/2]}
).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
A namespace per simulated node: registered names, named ETS tables and
`persistent_term` keys.

Every simulated node is the same VM, so it has one process registry, one ETS
namespace and one `persistent_term`. A system that runs one instance per node
registers the same local names on every node, and the second instance fails to
start. `eta_transform` points the calls that name things at this module instead,
and a process on a simulated node gets a namespace of its own:

| Call | On simulated node `N` |
|---|---|
| `register(Name, Pid)` | registers the real name `'N/Name'` |
| `whereis(Name)`, `Name ! Msg`, `gen_server:call(Name, ...)` | `'N/Name'` if it is registered, otherwise `Name` |
| `{Name, N2} ! Msg` | `'N2/Name'` on simulated node `N2` |
| `ets:new(Name, [named_table])` | creates the table `'N/Name'`, and returns `Name` |
| `ets:F(Name, ...)` | `'N/Name'` if it exists, otherwise `Name` |
| `persistent_term:put(Key, V)` | stores under `{'$eta_ns', N, Key}` |
| `persistent_term:get(Key)` | the node's key if it exists, otherwise `Key` |

A lookup that finds nothing in the node's namespace falls through to the VM's. That
is what lets a process on a simulated node still reach what every node shares:
`logger`, `code_server`, `application_controller`, and the tables a harness keeps
for itself. Anything created on a node goes into the node's namespace.

A process on no simulated node — a harness, a test, anything unplaced — sees the
VM's namespace, unchanged. `eta_net:with_node/2` lets it act for a node. With no
network running, every function here is the call it replaces.

## What it doesn't cover

- **Code that isn't rewritten.** A name passed to a module the transform never
  saw is looked up there under its real name. Instrument the dependencies a system
  runs on; see `Eta.Beam.instrument/1`.
- **Names a system reads back.** `ets:info(Tab, name)` and the name in a crash
  report are the real, prefixed name. `registered/0` and
  `process_info(Pid, registered_name)` give the unprefixed one.
- **Applications.** `application_controller` is one per VM, so an application
  can't be started once per node. Start its top supervisor on each node instead.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([
    name/1,
    name/2,
    dest/1,
    register/2,
    unregister/1,
    whereis/1,
    registered/0,
    process_info/2,
    ets_new/2,
    tab/1,
    pt_get/1,
    pt_get/2,
    pt_put/2,
    pt_erase/1
]).

%% ---------------------------------------------------------------------------
%% Names
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
The real name `Name` has in the caller's namespace: `'N/Name'` on simulated node
`N`, and `Name` itself anywhere else.
""".
-endif.
-spec name(atom()) -> atom().
name(Name) when is_atom(Name) ->
    case eta_net:local_node() of
        undefined -> Name;
        Node -> name(Node, Name)
    end.

-if(?DOCATTRS).
-doc "The real name `Name` has on simulated node `Node`.".
-endif.
-spec name(term(), atom()) -> atom().
name(Node, Name) when is_atom(Name) ->
    binary_to_atom(<<(prefix(Node))/binary, (atom_to_binary(Name))/binary>>).

prefix(Node) when is_atom(Node) -> <<(atom_to_binary(Node))/binary, "/">>;
prefix(Node) -> iolist_to_binary([io_lib:format("~0p", [Node]), "/"]).

%% `Name` without the prefix of `Node`'s namespace, if it has it.
unprefixed(Node, Name) ->
    Prefix = prefix(Node),
    Bin = atom_to_binary(Name),
    case Bin of
        <<Prefix:(byte_size(Prefix))/binary, Rest/binary>> -> binary_to_atom(Rest);
        _ -> Name
    end.

-if(?DOCATTRS).
-doc """
A destination for code that sends without going through `eta_net`: `gen`'s `call`,
`sys:get_state/1`, a timer addressed by name.

A name becomes its real name in the caller's namespace if it is registered there.
`{Name, Node}` for the caller's own node becomes the same, and for another
simulated node becomes that node's real name. That last delivery is direct: it
does not cross the simulated network, so no fault applies to it.
""".
-endif.
-spec dest(term()) -> term().
dest(Name) when is_atom(Name) ->
    case eta_net:local_node() of
        undefined -> Name;
        Node -> resolved(Node, Name)
    end;
dest({Name, Node} = Dest) when is_atom(Name) ->
    case eta_net:local_node() of
        undefined -> Dest;
        Node -> resolved(Node, Name);
        _ ->
            case eta_net:is_node(Node) of
                true -> name(Node, Name);
                false -> Dest
            end
    end;
dest(Dest) ->
    Dest.

%% The node's real name if it is registered there, otherwise the VM's.
resolved(Node, Name) ->
    Real = name(Node, Name),
    case erlang:whereis(Real) of
        undefined -> Name;
        _ -> Real
    end.

-if(?DOCATTRS).
-doc "`erlang:register/2`, in the caller's namespace.".
-endif.
-spec register(atom(), pid() | port()) -> true.
register(Name, Pid) ->
    erlang:register(name(Name), Pid).

-if(?DOCATTRS).
-doc "`erlang:unregister/1`: the caller's namespace first, then the VM's.".
-endif.
-spec unregister(atom()) -> true.
unregister(Name) ->
    Real = name(Name),
    case erlang:whereis(Real) of
        undefined -> erlang:unregister(Name);
        _ -> erlang:unregister(Real)
    end.

-if(?DOCATTRS).
-doc "`erlang:whereis/1`: the caller's namespace first, then the VM's.".
-endif.
-spec whereis(atom()) -> pid() | port() | undefined.
whereis(Name) ->
    case eta_net:local_node() of
        undefined ->
            erlang:whereis(Name);
        Node ->
            case erlang:whereis(name(Node, Name)) of
                undefined -> erlang:whereis(Name);
                Pid -> Pid
            end
    end.

-if(?DOCATTRS).
-doc "`erlang:registered/0`: on a simulated node, only that node's names.".
-endif.
-spec registered() -> [atom()].
registered() ->
    case eta_net:local_node() of
        undefined ->
            erlang:registered();
        Node ->
            Prefix = prefix(Node),
            [
                unprefixed(Node, N)
             || N <- erlang:registered(),
                binary:longest_common_prefix([atom_to_binary(N), Prefix]) =:= byte_size(Prefix)
            ]
    end.

-if(?DOCATTRS).
-doc """
`erlang:process_info/2`, with `registered_name` given without the namespace's
prefix. Every other item is the BIF's answer.
""".
-endif.
-spec process_info(pid(), atom() | [atom()]) -> term().
process_info(Pid, Item) ->
    Info = erlang:process_info(Pid, Item),
    case eta_net:running() of
        false -> Info;
        true -> unprefix_info(eta_net:node(Pid), Info)
    end.

unprefix_info(Node, {registered_name, Name}) when is_atom(Name) ->
    {registered_name, unprefixed(Node, Name)};
unprefix_info(Node, Items) when is_list(Items) ->
    [unprefix_info(Node, I) || I <- Items];
unprefix_info(_Node, Other) ->
    Other.

%% ---------------------------------------------------------------------------
%% ETS
%% ---------------------------------------------------------------------------

-if(?DOCATTRS).
-doc """
`ets:new/2`. A named table on a simulated node is created under its real name in
that node's namespace, and the name given is returned, as `ets:new/2` returns it.
""".
-endif.
-spec ets_new(atom(), list()) -> ets:table().
ets_new(Name, Opts) ->
    case lists:member(named_table, Opts) andalso eta_net:local_node() of
        Node when Node =/= false, Node =/= undefined ->
            _ = ets:new(name(Node, Name), Opts),
            Name;
        _ ->
            ets:new(Name, Opts)
    end.

-if(?DOCATTRS).
-doc """
The table an ETS call names: the caller's namespace first, then the VM's. A table
id is itself.
""".
-endif.
-spec tab(ets:table()) -> ets:table().
tab(Name) when is_atom(Name) ->
    case eta_net:local_node() of
        undefined ->
            Name;
        Node ->
            Real = name(Node, Name),
            case ets:whereis(Real) of
                undefined -> Name;
                _ -> Real
            end
    end;
tab(Tab) ->
    Tab.

%% ---------------------------------------------------------------------------
%% persistent_term
%% ---------------------------------------------------------------------------

-define(NONE, '$eta_ns_none').

key(Node, Key) -> {'$eta_ns', Node, Key}.

-if(?DOCATTRS).
-doc "`persistent_term:get/1`: the caller's namespace first, then the VM's.".
-endif.
-spec pt_get(term()) -> term().
pt_get(Key) ->
    case pt_lookup(Key) of
        ?NONE -> persistent_term:get(Key);
        Value -> Value
    end.

-if(?DOCATTRS).
-doc "`persistent_term:get/2`: the caller's namespace first, then the VM's.".
-endif.
-spec pt_get(term(), term()) -> term().
pt_get(Key, Default) ->
    case pt_lookup(Key) of
        ?NONE -> persistent_term:get(Key, Default);
        Value -> Value
    end.

pt_lookup(Key) ->
    case eta_net:local_node() of
        undefined -> ?NONE;
        Node -> persistent_term:get(key(Node, Key), ?NONE)
    end.

-if(?DOCATTRS).
-doc "`persistent_term:put/2`, in the caller's namespace.".
-endif.
-spec pt_put(term(), term()) -> ok.
pt_put(Key, Value) ->
    case eta_net:local_node() of
        undefined -> persistent_term:put(Key, Value);
        Node -> persistent_term:put(key(Node, Key), Value)
    end.

-if(?DOCATTRS).
-doc "`persistent_term:erase/1`, in the caller's namespace.".
-endif.
-spec pt_erase(term()) -> boolean().
pt_erase(Key) ->
    case eta_net:local_node() of
        undefined -> persistent_term:erase(Key);
        Node -> persistent_term:erase(key(Node, Key))
    end.
