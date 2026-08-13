# Review: Elixir support and stress SUTs

## Summary

This changeset adds Elixir support to `eta` via an explicit-macro approach
(`use Eta` + `Eta.*` macros) that avoids the parse transform entirely, plus a
dense `gen_statem`-based stress SUT (`eta_stress` / `eta_stress_member`) and
additional determinism tests. The work spans:

- `lib/eta.ex` — the `Eta` module: macros, `@before_compile` wrapper
- `test/support/eta_elixir_counter.ex`, `eta_elixir_worker.ex` — Elixir SUTs
- `test/support/eta_elixir_harness.ex`, `eta_elixir_worker_harness.ex` — harnesses
- `test/support/eta_stress.erl`, `eta_stress_member.erl` — Erlang stress SUT
- `test/eta_elixir_test.exs`, `eta_elixir_non_dst_test.exs`, `eta_stress_test.exs`
- `test/eta_run_test.exs` — new determinism stress block
- `mix.exs` — `elixirc_paths`, compile alias, package files
- `README.md`, `docs/01-04-05` — documentation

The design is sound, the documentation is thorough, and the test coverage is
strong. One issue is likely to bite external users; the rest are minor.

---

## Issues

### 1. `elixirc_paths` omits `"lib"` for `:dst` env — external Elixir users cannot `use Eta`

**Severity: high**

`mix.exs:34-35`:

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: []
```

The catch-all returns `[]`, so in any env other than `:test` — including the
`:dst` env the docs in `docs/02-setting-up.md:204-249` walk users through
setting up — `lib/eta.ex` is **not compiled**. When a user runs `mix dst`
(which sets `MIX_ENV=dst`), Mix compiles `:eta` with `Mix.env() == :dst`,
`elixirc_paths(:dst)` hits the catch-all, and the `Eta` module is absent.
Any `use Eta` in the user's code fails with `undefined module Eta`.

The library's own tests pass because they run in `:test` env, where `lib/`
is included. The bug is invisible to this repo and only surfaces downstream.

**Fix:** always compile `lib/`; scope `test/support` to `:test`:

```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

### 2. `@eta_after` attribute registered but never read

**Severity: low**

`lib/eta.ex:76` registers `@eta_after` with `persist: true`, but
`__before_compile__/1` never reads it and no macro references it. It's either
dead code or a placeholder for `receive ... after` virtualization (which the
docs explicitly say is unsupported). Either remove it or add a comment noting
it's reserved.

### 3. Non-DST verification test uses binary substring match on serialized AST

**Severity: low**

`test/eta_elixir_non_dst_test.exs:96-106` checks that the compiled BEAM's
abstract code doesn't reference `eta_time`/`eta_net`/`eta_sched`/`eta_log` via
`:binary.match/2` on `term_to_binary/1` of the AST. This works today but is
brittle: any module/variable/literal containing those substrings would trip
a false positive. An AST walk matching `{:remote, _, {:atom, _, :eta_time}, _}`
patterns would be more precise. Not blocking — the test is correct for the
modules it compiles.

### 4. `list_to_atom/1` in `eta_stress:node_name/1`

**Severity: low**

`test/support/eta_stress.erl:189-192` calls `list_to_atom/1` per member to
derive node names. This is bounded by `?MEMBERS` (default 4) and is inert in
a no-network run, but a config with a large `members` count grows the atom
table. Consider `binary_to_atom/2` with a stable scheme or pre-generating the
names once in `init/2`.

---

## Observations (not issues)

### `Eta` only wraps `gen_server` callbacks for observe

`lib/eta.ex:316` gates the `@before_compile` wrapper on `:gen_server in
behaviours`. A module with `@eta_observe :all` that is **not** a `gen_server`
(e.g., a raw `spawn`-loop process) gets no state publishing. This is
documented ("wraps `gen_server` callback bodies") and the Erlang parse transform
remains the path for non-`gen_server` Erlang modules. Worth a one-liner in
`docs/02-setting-up.md` to make the Elixir limitation explicit, since the
Erlang `-eta_observe(all)` works on any module.

### `Eta.send/2` and the `!` operator

The docs and gotchas are clear that `!` is not rewritten. The `Eta.send/2`
macro correctly expands to `Kernel.send/2` (which is `:erlang.send/2`) in
release builds and `:eta_net.send/2` in DST builds. The argument-order swap
in `Eta.send_after/3` (Elixir's `dest, msg, ms` vs. Erlang's `Time, Dest,
Msg`) is handled correctly in `lib/eta.ex:103-109`.

### `__publish__` and `__route_reply__` coverage

`lib/eta.ex:393-401` covers every `gen_server` callback return shape:
`{:ok, s}`, `{:ok, s, _}`, `{:noreply, s}`, `{:noreply, s, _}`, `{:reply, _, s}`,
`{:reply, _, s, _}`, `{:stop, _, s}`, `{:stop, _, _, s}`. The catch-all
`def __publish__(_), do: :ok` handles `ignore` and `{stop, Reason}` without
crashing. `__route_reply__/2` (`lib/eta.ex:418-433`) similarly covers the
three reply-carrying shapes and passes everything else through. The
composition (publish then route) is correct: state is published before the
reply is split off, so the observed state always reflects the return value.

### Hygiene in `maybe_publish`

`lib/eta.ex:380-386` uses a hardcoded `result` variable inside a `quote`.
Elixir's macro hygiene ensures this doesn't collide with any `result` in the
user's body. Verified against `eta_elixir_worker.ex`'s `:measure` handler,
which has its own `result` inside a spawned `fn` — no conflict.

### `wrap_clause` for `handle_call/3`

`lib/eta.ex:362` pattern-matches `[req, from, state] = args`. This binds
`from` to the AST element for whatever the user named the second argument,
not a variable literally named `from`. Unquoting it into `__route_reply__`
produces a reference to the original argument. Works for any argument name
and for pattern-match arguments like `{pid, _} = from`.

### Stress SUT design

`eta_stress.erl` and `eta_stress_member.erl` are well-constructed. The
"ticker mesh" design (each member on its own simulated node, broadcasting to
all peers on each tick, with state-timeout arming/cancellation/rearming
cycles) exercises every surface where nondeterminism has historically leaked:
`state_timeout`, fan-out casts, monitor retirement, `noconnection` DOWN
delivery, and the virtual clock on the critical path. The `check/1` reads
from ETS (not suspended processes), following the harness contract. The
`eta_net:running()` guard makes the SUT work with and without a network.

### Determinism stress tests in `eta_run_test.exs`

The new tests (`test/eta_run_test.exs:210-250`) sweep 12 seeds with 3 runs
each and assert full-result equality (not just trace equality), plus a
reproducibility test that finds a failing seed and verifies byte-identical
reproduction across 3 runs. The non-vacuity assertions (`ops == 25`,
`steps > 50`) prevent a no-op run from satisfying the determinism claim.

### Compile ordering

The `compile: ["compile.erlang", "compile.elixir", "compile.app"]` alias
(`mix.exs:112`) is necessary because `lib/eta.ex`'s `dst?/0` calls
`Code.ensure_loaded?(:eta_time)` at macro expansion time. The
`@before_compile` callback also calls `dst?()`, so this ordering is
load-bearing. The docs in `docs/02-setting-up.md:253-269` and
`docs/05-gotchas.md:272-285` cover this for adopters.

---

## Code quality

- The macro dispatch (`if dst?() do ... else ... end`) is uniform across all
  14 macros — easy to audit.
- `Eta.dst?/0`'s `:__eta_dst_override__` PD key allows testing the non-DST
  path from a DST build without recompiling `:eta`. The separation of
  `eta_elixir_non_dst_test.exs` (which uses `Code.compile_string` and can
  interfere with `modules_loaded` tracking) from determinism tests is
  thoughtful.
- `gen_server_helpers/0` returns `[]` with a comment noting it's a hook for
  future use. Fine as-is.
- `combine_guards/1` correctly builds a left-associative `and` chain and is
  only called when `guards` is non-empty (the empty case is handled by
  `build_def/4`'s first clause).
- The `@dialyzer {:nowarn_function, ...}` annotations on `__publish__/1` and
  `__route_reply__/2` are appropriate — the broad patterns are intentional
  and per-SUT type inference can't see that.

---

## Documentation

The docs are excellent. `docs/02-setting-up.md` has a complete macro table
with DST-build and release-build expansions, clear guidance on
`@behaviour :gen_server` vs `use GenServer`, and honest coverage of the three
things macros cannot do (`!`, `receive ... after`, `gen_statem` state
timeouts). `docs/05-gotchas.md` mirrors these as build-time hazards. The
README update is concise and the "Known gaps" section is honest about
Elixir being best-effort.

One doc gap: `docs/02-setting-up.md` doesn't mention that `@eta_observe`
only works on `gen_server` modules in Elixir (see Observations above).

---

## Verdict

The changeset is well-designed and well-tested. The one high-severity issue
(`elixirc_paths` omitting `"lib"` for `:dst` env) should be fixed before
this ships to external users — it's invisible to the library's own test
suite and will surface as `undefined module Eta` the first time someone
follows the documented `:dst` env setup. The rest are minor.
