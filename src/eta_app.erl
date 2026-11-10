-module(eta_app).

-define(DOCATTRS, ?OTP_RELEASE >= 27).

-if(?DOCATTRS).
-moduledoc """
Starting an application, from inside a run.

`application:start/1,2` and `application:ensure_all_started/1,2,3` are calls into
`application_controller`, one process per VM that the scheduler doesn't own. A
process making one under a run waits on something outside the schedule, the same
real-time dependence as `code_server`, and the run can end looking quiet while it
is still waiting.

Systems often ensure an application is started on a path that runs every time,
as ra does for `seshat` when it initialises its counters. So `eta_transform`
points these calls here:

- An application that is already running is answered without asking
  `application_controller`: `{ok, []}` from `ensure_all_started`, and
  `{error, {already_started, App}}` from `start`. Whether it is running is an ETS
  read.
- One that isn't running raises while a scheduler is active, naming it. Start it
  before the run.
- With no scheduler, every call is the original.

*This documentation is LLM-generated. See the AI disclosure in `README.md`.*
""".
-endif.

-export([start/1, start/2, ensure_all_started/1, ensure_all_started/2, ensure_all_started/3]).

-if(?DOCATTRS).
-doc "`application:start/1`. See the module doc.".
-endif.
-spec start(atom()) -> ok | {error, term()}.
start(App) ->
    start(App, temporary).

-if(?DOCATTRS).
-doc "`application:start/2`. See the module doc.".
-endif.
-spec start(atom(), atom()) -> ok | {error, term()}.
start(App, Type) ->
    case gate([App], {application, start, [App, Type]}) of
        running -> {error, {already_started, App}};
        delegate -> application:start(App, Type)
    end.

-if(?DOCATTRS).
-doc "`application:ensure_all_started/1`. See the module doc.".
-endif.
-spec ensure_all_started(atom() | [atom()]) -> {ok, [atom()]} | {error, term()}.
ensure_all_started(Apps) ->
    ensure_all_started(Apps, temporary).

-if(?DOCATTRS).
-doc "`application:ensure_all_started/2`. See the module doc.".
-endif.
-spec ensure_all_started(atom() | [atom()], atom()) -> {ok, [atom()]} | {error, term()}.
ensure_all_started(Apps, Type) ->
    case gate(List = apps(Apps), {application, ensure_all_started, [Apps, Type]}) of
        running -> {ok, []};
        delegate -> application:ensure_all_started(apps_arg(Apps, List), Type)
    end.

-if(?DOCATTRS).
-doc "`application:ensure_all_started/3`. See the module doc.".
-endif.
-spec ensure_all_started(atom() | [atom()], atom(), atom()) ->
    {ok, [atom()]} | {error, term()}.
ensure_all_started(Apps, Type, Mode) ->
    case gate(apps(Apps), {application, ensure_all_started, [Apps, Type, Mode]}) of
        running -> {ok, []};
        delegate -> application:ensure_all_started(Apps, Type, Mode)
    end.

apps(App) when is_atom(App) -> [App];
apps(Apps) when is_list(Apps) -> Apps.

apps_arg(App, _) when is_atom(App) -> App;
apps_arg(_, List) -> List.

%% `running` when there is nothing to start, `delegate` when there is and no run
%% is in progress, and an error when there is and one is.
gate(Apps, Call) ->
    case lists:all(fun running/1, Apps) of
        true ->
            running;
        false ->
            case eta_sched:active() of
                false ->
                    delegate;
                true ->
                    error(
                        {eta_sched,
                            {application_not_started, [A || A <- Apps, not running(A)], Call, <<
                                "starting an application is a call into application_controller, "
                                "outside the schedule. Start it before the run"
                            >>}}
                    )
            end
    end.

running(App) ->
    is_pid(application_controller:get_master(App)).
