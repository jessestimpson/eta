-module(eta_elect).
-behaviour(gen_statem).

%% Leader election by heartbeat lease — a member of a small cluster that agrees
%% on one leader at a time, and notices when it goes away.
%%
%% The third worked example in this repository, after two-phase commit
%% (`eta_2pc`) and the ABD quorum register in the walkthrough, and it is here
%% because it is the one whose correctness is a statement about *time*. 2PC and
%% ABD are driven by messages; an election is driven by the absence of them. A
%% follower that hears nothing for long enough concludes the leader is gone,
%% and every interesting behaviour follows from how long "long enough" is
%% relative to how often the leader speaks.
%%
%% That makes it the natural thing to test `eta_statem` against, because every
%% one of those deadlines is a `state_timeout` and each exercises a different
%% rule:
%%
%% - A follower rearms its election deadline on every heartbeat with a
%%   `keep_state` — which works only because a transition to the *same* state
%%   does not cancel a state time-out, and the new action does.
%% - Winning an election is a state change, which must cancel the election
%%   deadline the new leader no longer wants. Nothing here cancels it explicitly.
%% - A candidate retrying is `{next_state, candidate, ...}` from `candidate` —
%%   not a state change, and the deadline is replaced by the action rather than
%%   by the transition.
%% - A new leader arms `{state_timeout, 0, heartbeat}` so its first heartbeat
%%   goes out before it processes anything else.
%%
%% ## The protocol
%%
%% A term is a number that only increases. A member votes at most once per term,
%% and a member needs votes from a majority to lead — so two members cannot both
%% lead in the same term, because two majorities of the same set intersect and
%% the member in the intersection would have had to vote twice. That is the
%% safety property, and `at_most_one_leader_per_term/1` is it written down.
%%
%% Liveness comes from the deadlines. A follower that hears no heartbeat within
%% its election period stands for election; a leader that holds the term
%% heartbeats often enough to stop that happening.
%%
%% ## Election periods are staggered, not random
%%
%% Real implementations randomise the election period, because members that time
%% out together split the vote and no one wins. Under a virtual clock the tie is
%% worse than unlikely, it is *permanent*: deadlines equal to the millisecond
%% fire in creation order, the same order on every run, so a split vote would
%% repeat forever.
%%
%% Each member is given a different period instead. Deterministic, replayable,
%% and it makes the same point randomisation makes — that this algorithm needs
%% its deadlines to disagree. `eta_time`'s `skew_ms` is the other way to get it.
%%
%% ## The bug
%%
%% `#{bug => true}` makes a member grant a vote it has already given away: it
%% checks that the candidate's term is not *older* than its own, and forgets to
%% check whether it has voted in that term already. One line, and the kind that
%% survives review, because on a healthy network it does nothing at all.
%%
%% It needs two candidates to reach the **same term** before it can show, and
%% that cannot happen while the messages are getting through. The first member to
%% time out tells everyone else its term, and they defer to it and rearm; a
%% second member standing later has necessarily seen the first and stands in a
%% higher term. One vote per term, one leader per term, no matter how the votes
%% are counted.
%%
%% Cut one link and the argument stops holding. A member that cannot hear the
%% first candidate has no reason not to time out into the same term, and a
%% double-voting third member can then give both of them a majority — of the same
%% three, in the same term. That is why the bug is planted here rather than in
%% the timing: it is a *safety* failure that only a fault makes reachable, which
%% is the case for injecting faults, stated as a test.
%%
%% Off by default. `test/eta_state_timeout_test.exs` shows it needing both
%% ingredients: the fault alone elects one leader, and the bug alone elects one
%% leader.

-include_lib("eta/include/eta.hrl").

%% The data is published on every callback return so an invariant can read it
%% while the scheduler has the member suspended. `role` is in there as well as
%% being the state name, because the observability pass publishes the *data* — a
%% state machine's state name is one atom a trace already carries, and duplicating
%% it here is what lets `check/1` be written without reading the trace.
-eta_observe(all).

-export([start_link/1, role/1, stop/1]).
-export([at_most_one_leader_per_term/1, leaders/1]).
-export([callback_mode/0, init/1, follower/3, candidate/3, leader/3, terminate/3]).

-define(ELECTION_MS, 150).
-define(HEARTBEAT_MS, 50).

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

%% `Opts` carries `name`, `members` (every member's registered name, this one
%% included) and optionally `election_ms`, `heartbeat_ms` and `bug`.
start_link(Opts = #{name := Name}) ->
    gen_statem:start_link({local, Name}, ?MODULE, Opts, []).

role(Member) ->
    gen_statem:call(Member, role).

stop(Member) ->
    gen_statem:stop(Member).

%% ---------------------------------------------------------------------------
%% Invariants
%% ---------------------------------------------------------------------------

%% The safety property. Read out of band through `eta_observe`, never by asking
%% the members — a member the scheduler has suspended cannot answer, and an
%% invariant that asks is an invariant that checks nothing.
-spec at_most_one_leader_per_term([atom()]) -> ok | {violation, term()}.
at_most_one_leader_per_term(Members) ->
    ByTerm = lists:foldl(
        fun({Name, Term}, Acc) -> maps:update_with(Term, fun(L) -> [Name | L] end, [Name], Acc) end,
        #{},
        leaders(Members)
    ),
    case [{T, Names} || T := Names <- ByTerm, length(Names) > 1] of
        [] -> ok;
        [_ | _] = Split -> {violation, {split_brain, Split}}
    end.

%% Every member that believes it leads, with the term it believes it leads in.
-spec leaders([atom()]) -> [{atom(), non_neg_integer()}].
leaders(Members) ->
    [
        {Name, Term}
     || Name <- Members,
        #{role := leader, term := Term} <- [observed(Name)]
    ].

observed(Name) ->
    case eta_observe:read(Name) of
        undefined -> #{};
        Data -> Data
    end.

%% ---------------------------------------------------------------------------
%% gen_statem
%% ---------------------------------------------------------------------------

callback_mode() ->
    state_functions.

init(Opts = #{name := Name, members := Members}) ->
    ok = ?ETA_LABEL({member, Name}),
    Data = #{
        name => Name,
        members => Members,
        role => follower,
        term => 0,
        voted_for => undefined,
        votes => 0,
        leader => undefined,
        election_ms => maps:get(election_ms, Opts, ?ELECTION_MS),
        heartbeat_ms => maps:get(heartbeat_ms, Opts, ?HEARTBEAT_MS),
        bug => maps:get(bug, Opts, false)
    },
    %% The first election deadline is armed here rather than on the first event,
    %% so a cluster that is started and then left alone still holds one — which
    %% is the only reason it ever elects anybody.
    {ok, follower, Data, [{state_timeout, election_ms(Data), election}]}.

%% ---------------------------------------------------------------------------
%% follower
%% ---------------------------------------------------------------------------

follower(state_timeout, election, Data) ->
    stand_for_election(Data);
%% The rearm. `keep_state` is not a state change, so the deadline is *not*
%% cancelled by the transition — it is replaced by the action, which is the
%% distinction the whole heartbeat mechanism rests on.
follower(cast, {heartbeat, Term, Leader}, Data = #{term := T}) when Term >= T ->
    Data1 = Data#{term := Term, leader := Leader, voted_for := voted_for(Term, T, Data)},
    {keep_state, Data1, [{state_timeout, election_ms(Data), election}]};
follower(cast, {request_vote, Term, Candidate}, Data) ->
    consider_vote(Term, Candidate, Data);
follower(EventType, Event, Data) ->
    common(EventType, Event, follower, Data).

%% ---------------------------------------------------------------------------
%% candidate
%% ---------------------------------------------------------------------------

%% A retry is `{next_state, candidate, ...}` from `candidate`, which is not a
%% state change. See `stand_for_election/1`.
candidate(state_timeout, election, Data) ->
    stand_for_election(Data);
candidate(cast, {vote, Term, _From}, Data = #{term := T, votes := V}) when Term =:= T ->
    Votes = V + 1,
    case won(Votes, Data) of
        false ->
            {keep_state, Data#{votes := Votes}};
        true ->
            %% Two things at once, and both matter. Changing state cancels the
            %% election deadline this member no longer wants, with nothing here
            %% saying so. And the zero heartbeat is delivered before any queued
            %% message, so the first heartbeat goes out ahead of anything that
            %% might unseat the new leader.
            Data1 = Data#{votes := Votes, role := leader, leader := name(Data)},
            {next_state, leader, Data1, [{state_timeout, 0, heartbeat}]}
    end;
candidate(cast, {heartbeat, Term, Leader}, Data = #{term := T}) when Term >= T ->
    step_down(Term, Leader, Data);
candidate(cast, {request_vote, Term, Candidate}, Data) ->
    consider_vote(Term, Candidate, Data);
candidate(EventType, Event, Data) ->
    common(EventType, Event, candidate, Data).

%% ---------------------------------------------------------------------------
%% leader
%% ---------------------------------------------------------------------------

leader(state_timeout, heartbeat, Data = #{term := Term}) ->
    ok = broadcast(Data, {heartbeat, Term, name(Data)}),
    {keep_state_and_data, [{state_timeout, heartbeat_ms(Data), heartbeat}]};
leader(cast, {heartbeat, Term, Leader}, Data = #{term := T}) when Term > T ->
    step_down(Term, Leader, Data);
leader(cast, {request_vote, Term, Candidate}, Data = #{term := T}) when Term > T ->
    consider_vote(Term, Candidate, Data);
leader(EventType, Event, Data) ->
    common(EventType, Event, leader, Data).

%% ---------------------------------------------------------------------------
%% Shared
%% ---------------------------------------------------------------------------

common({call, From}, role, State, #{term := Term}) ->
    {keep_state_and_data, [{reply, From, {State, Term}}]};
%% Anything stale — a vote for a term that has moved on, a heartbeat from a
%% deposed leader — is dropped rather than acted on.
common(cast, _Event, _State, _Data) ->
    keep_state_and_data;
common(_EventType, _Event, _State, _Data) ->
    keep_state_and_data.

%% Bumps the term, votes for itself, and asks everyone else.
%%
%% From `follower` this is a state change and cancels the election deadline that
%% just fired; from `candidate` it is not a change at all, and the deadline is
%% replaced by the action instead. Both paths are correct and they get there
%% differently, which is why the retry is written as the same function.
stand_for_election(Data = #{term := T}) ->
    Term = T + 1,
    Data1 = Data#{
        term := Term,
        role := candidate,
        voted_for := name(Data),
        votes := 1,
        leader := undefined
    },
    ok = broadcast(Data1, {request_vote, Term, name(Data)}),
    {next_state, candidate, Data1, [{state_timeout, election_ms(Data), election}]}.

step_down(Term, Leader, Data) ->
    Data1 = Data#{
        term := Term,
        role := follower,
        leader := Leader,
        votes := 0,
        voted_for := undefined
    },
    {next_state, follower, Data1, [{state_timeout, election_ms(Data), election}]}.

%% One vote per term, which is the whole of the safety argument: two majorities
%% of one set intersect, so a second leader in a term would need somebody here to
%% have said yes twice.
%% Which is exactly what `bug` breaks. Reading the rule as "the candidate is not
%% behind me, so yes" looks like the same thing and is not: it drops the question
%% of whether this vote has already been spent. See the module doc for why that
%% is invisible until a link is cut.
consider_vote(Term, Candidate, Data = #{term := T, voted_for := Voted}) ->
    Free =
        case bug(Data) of
            true -> Term >= T;
            false -> Term > T orelse (Term =:= T andalso Voted =:= undefined)
        end,
    case Free of
        false ->
            keep_state_and_data;
        true ->
            ok = cast(Candidate, {vote, Term, name(Data)}),
            Data1 = Data#{term := Term, voted_for := Candidate},
            case Term > T of
                %% A newer term deposes whatever this member was.
                true -> {next_state, follower, Data1#{role := follower, votes := 0}, [
                    {state_timeout, election_ms(Data), election}
                ]};
                false -> {keep_state, Data1}
            end
    end.

terminate(_Reason, _State, _Data) ->
    ok.

%% ---------------------------------------------------------------------------
%% Helpers
%% ---------------------------------------------------------------------------

%% A heartbeat for a term this member has already reached leaves its vote alone;
%% one for a newer term clears it, since it has not voted in that term yet.
voted_for(Term, Term, #{voted_for := Voted}) -> Voted;
voted_for(_Term, _T, _Data) -> undefined.

won(Votes, #{members := Members}) ->
    Votes * 2 > length(Members).

broadcast(Data = #{members := Members}, Msg) ->
    lists:foreach(fun(M) -> M =:= name(Data) orelse cast(M, Msg) end, Members),
    ok.

cast(Member, Msg) ->
    gen_statem:cast(Member, Msg).

name(#{name := Name}) -> Name.
election_ms(#{election_ms := Ms}) -> Ms.
heartbeat_ms(#{heartbeat_ms := Ms}) -> Ms.
bug(#{bug := Bug}) -> Bug.
