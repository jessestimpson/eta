# Changelog

## v0.2.0 (TBD)

### Enhancements

- Elixir support via a mix compiler step. It uses the same mechanism as the parse_transform,
  but operates on BEAM files on disk.
- Added `Eta.Beam.instrument/1`, which rewrites modules a project does not own in
  memory, for dependencies and for the OTP and Elixir stdlib modules a system runs
  on. `Task` and `Agent` no longer raise once their modules have been instrumented.
  This feature is not supported for Erlang.
- Added `eta_ets`, which the parse_transform uses so that iterating a hash-based ETS
  table is stable under a run. Keys holding references or pids otherwise iterate in
  a different order in every VM, which `audit/1` cannot see.
- The parse_transform points node identity and membership at `eta_net`:
  `node/0,1`, `nodes/0,1`, `is_alive/0`, `net_kernel:monitor_nodes/1,2`,
  `connect_node/1`, `disconnect_node/1`, `net_adm:ping/1`, `send_nosuspend/2,3`
  and their Elixir `Node` forms. `eta_net` answers from its topology and keeps
  connections as distribution does, so a system on a simulated node needs no seam
  of its own for them. `node()` in a guard is handled; `node(X)` in a guard is
  refused at compile time.
- `eta_net` delivers `nodeup`/`nodedown` to `monitor_nodes/1` subscribers on
  `connect_node/1`, `disconnect_node/1`, `partition/3` and `kill_node/2`.
- Added a busy-link fault to `eta_net`'s policy, `busy_p` and `busy_ms`:
  `send_nosuspend` returns `false` while the link is busy. Counted as `busy`.
- `eta_net:register_name/3` takes `{local, Name}`, an alias resolved at each send,
  and `{Name, Node}` resolves a real registered name held by a process on `Node`.
- Added `eta_net:with_node/2`, for a harness reading a node's state through the
  system's API.
- Added `eta_ns`: each simulated node has its own registered names, named ETS
  tables and `persistent_term` keys, so a system can run under the same names on
  every node. The parse_transform points the calls that name things at it.
- Added `eta_rpc`: `rpc:call/4,5`, `rpc:cast/4`, `erpc:call/2..5` and
  `erpc:cast/2,4` to a simulated node run on that node. The request crosses the
  simulated network, and the result comes back in the worker's exit, as with
  `erpc`, so a partition mid-call ends the call.
- `gen_statem` generic time-outs, `{{timeout, Name}, Time, Content}`, are on the
  virtual clock. Event time-outs still raise.
- `erlang:monitor_node/2,3` is simulated between simulated nodes.
- The parse_transform gates `proc_lib:start*` and `gen:start/5,6`, so a behaviour
  built on `gen` (`gen_batch_server`, say) starts under the scheduler.
- Added `eta_disk`, a simulated disk. The parse_transform points `file:open/2`,
  `write/2`, `pwrite/3`, `truncate/1`, `sync/1`, `datasync/1` and `close/1` at
  it, and `eta_file` calls it for `write_file/2,3`, `delete/1` and `rename/2`.
  With the `disk` option of `eta_run:run/2`, `eta_net:kill_node/2` loses the
  file contents and the directory operations that the node did not sync, as the
  seed decides. A policy can make writes, syncs and renames fail. With no disk
  running, every call delegates to `file`. A run reports `disk` statistics.
- Added `eta_app`, `eta_file` and `eta_dets`, which the parse_transform points
  `application` starts, `file_server`'s `file` and `filelib` functions, and `dets`
  at, so none of them waits on a VM service outside the schedule. `eta_dets`
  writes every change through to the table's file.
- A gated `gen_server` whose `init/1` returns `{ok, State, hibernate}` starts.
- Added an optional `settle_done/1` harness callback. A harness for a system that
  never goes quiet can end the settle phase once its final read has finished,
  instead of spending `settle_steps` on every run. The run ends as
  `settle_done`.
- Added a `busy_steps` run option. After that many actions without the clock
  moving, the clock moves to the next deadline, so a system that spins in zero
  time, like a client retrying a server that keeps redirecting it, can't stop its
  own timers from firing.
- A one-sided partition (`learns => a` or `b`) reaches the other side when it
  heals. Its monitors fire `noconnection` and its `monitor_nodes` subscribers get
  `nodedown`, as a real connection reset delivers them.
- `spawn(Node, ...)` and the rest of the distributed spawn forms are simulated
  between simulated nodes: the child is a gated spawn placed on `Node`, the spawn
  connects the two nodes as distribution does, and a spawn across a cut gives a
  child that exits `noconnection`. From a process on no simulated node, or to a
  node the network doesn't know, they still raise while a run is active.

### Bug fixes

- `monitor(process, {Name, Node})` from a process on a simulated node, to a
  simulated node where nothing holds `Name`, delivers the DOWN distribution
  would: `noconnection` if the two nodes cannot connect, as for a node that was
  killed and not restarted, and `noproc` if they can. It fell through to
  `erlang:monitor/3`, which raises `badarg` for a node the VM does not know, so
  the caller crashed instead.
- The bare distributed spawns, `spawn(Node, M, F, A)` and the other
  auto-imported forms with a node argument, are rewritten. Only the local forms
  were, so a bare distributed spawn ran ungated and was counted as
  `adopted_late`.
- `erlang:is_process_alive/1` no longer hangs a run. On another process it waits
  for that process to run, and under a run it is suspended.
- A start made by a process the scheduler doesn't own, such as `kernel_safe_sup`
  running an instrumented `supervisor`, goes to OTP rather than waiting for a
  token that never comes.
- An instrumented OTP 28 `supervisor` no longer arms its one-second idle-hibernate
  timer. The timer was real, so a supervisor that had taken a call (a
  `start_child`, say) became runnable a wall-clock second later, at a different
  point in each run, and the run didn't replay.
- A message between two simulated nodes is never delivered ahead of one
  scheduled earlier on the same node-to-node link, whoever sent it, as on
  distribution's single connection. Ordering was kept only per pair of
  processes, so a delayed message from one sender could be overtaken by a later
  one from another and manufacture reorderings real distribution can't produce.
- `eta_net:send/3` honours `noconnect` and `nosuspend` between simulated nodes.
  It ignored both, so a send that real distribution would refuse was delivered.

- A gated start now returns `{error, Reason}` when the child is killed before it
  acknowledges. A parent trapping exits, which includes every supervisor, and any
  parent of an unlinked start used to wait forever.
- A gated `supervisor` starts on OTP 28, whose `init/1` asks to hibernate when idle.
- `eta_net` recognises any placed term as a node name. `partition/2` and its
  relatives took only atoms, so a binary name cut nothing and still returned `ok`.
- `eta_net` no longer asks a suspended process who spawned it in the middle of a
  send. `node_of/1` answers for an unplaced process with its spawner's node, and
  found the spawner with `process_info/2` on every routed send. A stepped process
  waiting for that answer looks like one whose step has finished, so the step
  ended partway through a callback, with `timeouts` still 0. `eta_sched` now asks
  once, from its own process, as it takes each process on, and the answer is
  remembered. A run with unplaced processes on a network no longer loses about one
  seed in forty to this.
- A cast, a send or a `gen_fsm` event to `{Name, Node}`, where `Node` is a
  simulated node and nothing is registered as `Name` there, is dropped. It was
  handed to OTP, which took `Node` for a real node: `gen_server:cast/2` spawned a
  process outside the schedule to connect to it. `call/3` already answered `noproc`.

## 0.1.1 (2026-09-04)

### Enhancements

- Added `eta_rand`, a seeded stand-in for the process-local `rand` state.
- `gen_fsm` support
- A `gen_server` or `gen_statem` that is started outside the scheduler
  can be detected in certain cases. In those cases, an error is raised:
  `{eta_sched, {start_outside_schedule, _, _}}`
- `eta_sched:release/1` no longer sends a second gate token to a child that
  already received one.
- The simulated wall clock is a function of the seed.
- The `?LOG_*` macros are routed into the run's log. They expand to
  `erlang:apply(logger, macro_log, [Location, Level | Args])` rather than a
  level call, so the transform now rewrites an `erlang:apply/3` with literal
  module and function when the pair is in its table, and `eta_logger` gained
  `macro_log/3,4,5`.
- Added `eta_time:forget/1`, which cancels every timer addressed to a pid, and
  `eta_net:kill_node/2` now calls it for each process it kills.
- Added `eta_time:universal_time/0`, which the parse_transform uses in place of
  `calendar:universal_time/0`.

## 0.1.0 (2026-08-26)

Initial release. `eta` was extracted from the project that motivated it, a
durable process registry, and developed against 2 example systems that ship in
the test suite: a two-phase commit and an ABD quorum register.

### Added

- `eta_sched`, a deterministic scheduler. Suspends every process it owns and
  resumes exactly one at a time, chosen from the seeded RNG. Spawns are gated
  so a new process cannot run before the scheduler owns it, and the run result
  accounts for anything that escaped (`adopted_late`, `timeouts`,
  `cold_code`).
- `eta_time`, a virtual clock. Timers and clock reads move only when the
  driver advances the clock, so a 30 second timeout costs nothing. Includes
  timer fault injection (`skew_ms`, `drop_p`) and stray-timer detection.
- `eta_transform`, the parse transform that points a module at both of the
  above. Rewrites qualified timer, clock, sleep, and spawn calls; puts
  `receive ... after` and `gen_statem`'s `state_timeout` on the virtual
  clock; routes `logger` calls into the run's log; publishes state fields
  declared with `-eta_observe(...)`. A module opts in by including one
  header, and every rewrite is inert outside a simulation.
- `eta_run`, the driver. Turns a seed into a run against an `eta_harness`
  implementation, records every decision as a trace, and replays a trace
  strictly. `audit/1` checks the accounting that determinism depends on,
  `summary/1` renders a result at shell-friendly size, `preload` keeps the
  code server out of the schedule, and `save_fixture`/`replay_fixture` pin a
  reproduction to disk.
- `eta_harness`, the behaviour a system under test implements: 6 required
  callbacks and 2 optional ones (`labels/1`, `check_final/2`).
- `eta_log`, the narrative log. Records what the system did on the same
  timeline as the scheduler's decisions, with processes named, so a
  counterexample reads as a story instead of a column of integers.
- `eta_observe`, for reading a suspended process's state without message
  passing, which is the only way an invariant can inspect a frozen system.
- `eta_net`, a simulated network between simulated nodes. Injects
  message-delivery faults and delivers the events a real link or node failure
  produces: `nodedown`/`nodeup`, `noconnection` DOWNs for monitors held
  across the break, and node death as a single operation.
- `eta_shrink`, which delta-debugs a failing trace down to the decisions that
  matter and verifies the result still reproduces before handing it back.
- A documentation walkthrough, `docs/01` through `docs/06`: what DST is, how
  to set up a project, a worked two-phase commit example, how to write a
  system under test, the gotchas, and an end-to-end journey building the
  quorum register from an empty directory.
