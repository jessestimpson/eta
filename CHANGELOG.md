# Changelog

## v0.2.0 (TBD)

### Enhancements

- Elixir support: `use Eta` and the `mix compile.eta` compiler.
- `Eta.Beam.instrument/1` rewrites dependency and stdlib modules in memory.
- `eta_disk`: a simulated disk that loses unsynced writes on `kill_node/2`.
- `eta_ns`: per-node registered names, named ETS tables and `persistent_term` keys.
- `eta_rpc`: `rpc` and `erpc` between simulated nodes.
- `eta_app`, `eta_file`, `eta_dets`: `application`, `file`, `filelib` and `dets`
  without VM service processes.
- `eta_ets`: stable iteration order for hash-based ETS tables.
- `eta_ets`: `ets:tab2file/2,3` and `ets:file2tab/1,2` without `disk_log`.
- `eta_file`: `filelib:ensure_path/1`, `filelib:safe_relative_path/2`,
  `file:del_dir_r/1` and `file:consult/1` without `file_server`.
- `eta_disk` tracks `prim_file:write_file/2`.
- `eta_sched:yield/0` ends the step of the calling process and leaves it
  runnable. A `gen_server` that returns a time-out of 0 from `init/1` or from a
  callback yields before its `timeout`, so other processes can run in between.
- `eta_net` answers node identity and membership calls from its topology.
- `eta_net` simulates distributed spawns, `monitor_node/2,3` and
  `monitor_nodes/1,2` events.
- `eta_net` policy: busy-link fault (`busy_p`, `busy_ms`).
- `eta_net:register_name/3` accepts `{local, Name}` and `{Name, Node}`.
- `eta_net:with_node/2`.
- `eta_net` routes the asynchronous request and response interface of
  `gen_server` and `gen_statem`: `send_request/2,4`, `wait_response`,
  `receive_response` and `check_response`.
- A one-sided partition delivers its events to the other side when it heals.
- `gen_statem` generic time-outs on the virtual clock.
- Gated starts for `proc_lib:start*` and `gen:start/5,6`.
- `rand:bytes/1` and `crypto:strong_rand_bytes/1` are seeded.
- Harness callback `settle_done/1`.
- Run options `busy_steps` and `check_timeout`.
- Faster scheduler steps. A seed can produce a different schedule than in 0.1,
  and a trace recorded with 0.1 may not replay.

### Bug fixes

- A process that kills a scheduled process no longer waits out its receive
  time-out for the `DOWN`.
- `Process.send_after/3,4` is on the virtual clock under Elixir 1.20.
- `monitor(process, {Name, Node})` to an unregistered name on a simulated node.
- Bare distributed spawns are gated.
- `erlang:is_process_alive/1` no longer hangs a run.
- A start from a process the scheduler does not own goes to OTP.
- An instrumented OTP 28 `supervisor` arms no real hibernate timer.
- A gated `supervisor` starts on OTP 28.
- A gated `gen_server` whose `init/1` returns `{ok, State, hibernate}` starts.
- A gated `gen_server` whose `init/1` returns `{ok, State, 0}` starts.
- The functions that the transform generates have a spec, so a module that is
  compiled with `warn_missing_spec_all` and `warnings_as_errors` compiles.
- A gated start returns `{error, Reason}` when the child dies before it
  acknowledges.
- Messages on one node-to-node link keep their order across senders.
- `eta_net:send/3` honours `noconnect` and `nosuspend`.
- `eta_net:call/3` to a callee that has already exited fails with `noproc`
  without a VM monitor.
- `eta_net:kill_node/2` waits until the `DOWN` messages of VM monitors on the
  killed processes have reached the suspended processes that hold them.
- `erlang:is_process_alive/1` on a suspended process no longer ends the step
  of the caller at a time that the VM decides. `eta_sched:is_alive/1` answers
  from the record of the scheduler.
- A delayed message to a process that has already exited arms no timer, and
  is not reported as a stray timer.
- `eta_net` accepts any term as a node name.
- `eta_net` no longer queries a suspended process during a send.
- A cast, send or `gen_fsm` event to an unregistered `{Name, Node}` is dropped.

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
