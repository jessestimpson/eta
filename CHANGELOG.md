# Changelog

## 0.1.1 (TBD)

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
