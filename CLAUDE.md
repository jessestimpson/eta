# CLAUDE.md

## Paired walkthrough documents

`docs/06-a-journey-through-dst.md` (Erlang) and
`docs/07-a-journey-through-dst-elixir.md` (Elixir) are twins: the same
walkthrough with the prose kept in lockstep, differing only in code and in
captured outputs. **Any change to either document must be accounted for in
the other** — port the edit across, or record in the changed document why it
does not apply to its twin.

The RESULT blocks in each are real outputs from running that walkthrough end
to end against this repo. If an edit would change them, re-run the affected
steps and capture the new output rather than guessing numbers.
