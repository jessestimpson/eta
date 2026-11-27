-module(eta_dets_user).

%% A module that calls `dets'. `eta_transform' rewrites the calls to
%% `eta_dets', so the functions act on the table of `eta_dets'.

-include_lib("eta/include/eta.hrl").

-export([open/3, put/2, drop/2, get/2, close/1]).

open(Tab, File, Type) -> dets:open_file(Tab, [{file, File}, {type, Type}]).

put(Tab, Objects) -> dets:insert(Tab, Objects).

drop(Tab, Object) -> dets:delete_object(Tab, Object).

get(Tab, Key) -> dets:lookup(Tab, Key).

close(Tab) -> dets:close(Tab).
