-module(eta_preempt_forms).

%% Runs `eta_transform' on the source text of a module and counts calls in
%% the result, for the tests of the preemption pass.

-export([count/2]).

%% The number of qualified calls of `Mod:Fun' in the transformed forms of
%% `Source'.
-spec count(string(), {module(), atom()}) -> non_neg_integer().
count(Source, {Mod, Fun}) ->
    calls(eta_transform:parse_transform(forms(Source), []), Mod, Fun).

forms(Source) ->
    {ok, Tokens, _} = erl_scan:string(Source),
    lists:map(
        fun(FormTokens) ->
            {ok, Form} = erl_parse:parse_form(FormTokens),
            Form
        end,
        split(Tokens, [])
    ).

split([], []) -> [];
split([{dot, _} = Dot | Rest], Acc) -> [lists:reverse([Dot | Acc]) | split(Rest, [])];
split([Token | Rest], Acc) -> split(Rest, [Token | Acc]).

calls({call, _, {remote, _, {atom, _, Mod}, {atom, _, Fun}}, Args}, Mod, Fun) ->
    1 + calls(Args, Mod, Fun);
calls(Node, Mod, Fun) when is_tuple(Node) ->
    calls(tuple_to_list(Node), Mod, Fun);
calls(Nodes, Mod, Fun) when is_list(Nodes) ->
    lists:sum([calls(Node, Mod, Fun) || Node <- Nodes]);
calls(_Node, _Mod, _Fun) ->
    0.
