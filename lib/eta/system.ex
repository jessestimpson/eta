defmodule Eta.System do
  @moduledoc """
  Where the unit-argument `System` clock reads land after the rewrite.

  The zero-arity forms need nothing here — the Elixir compiler inlines
  `System.system_time/0` to `:erlang.system_time/0` and `System.os_time/0` to
  `:os.system_time/0`, which the rewrite tables already point at `eta_time`.
  The unit-argument forms are real functions inside the Elixir stdlib, and
  what they add over their `:erlang` counterparts is unit normalisation:
  the legacy plural units (`:milliseconds` and kin) still convert. That
  happens where no transform reaches, so it is reproduced here, ahead of
  `eta_time`.

  `os_time` and `system_time` both read `eta_time:system_time/1`: eta has one
  virtual wall clock, the same collapse the Erlang table makes in mapping
  `os:system_time/1` and `erlang:system_time/1` to a single target.

  `eta_time` delegates to the real clock when no virtual one is running, so a
  module rewritten to land here behaves normally outside a simulation.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  @doc "`System.monotonic_time/1` on the virtual clock."
  def monotonic_time(unit), do: :eta_time.monotonic_time(normalize(unit))

  @doc "`System.system_time/1` on the virtual clock."
  def system_time(unit), do: :eta_time.system_time(normalize(unit))

  @doc "`System.os_time/1` on the virtual clock."
  def os_time(unit), do: :eta_time.system_time(normalize(unit))

  # `System`'s legacy plural units, converted the way its own normalisation
  # does. (Elixir also warns at runtime; the conversion is what keeps code
  # running, and the warning stays Elixir's business.) Anything else is handed
  # through for the clock to judge, so a bad unit raises just as it would have.
  defp normalize(:seconds), do: :second
  defp normalize(:milliseconds), do: :millisecond
  defp normalize(:microseconds), do: :microsecond
  defp normalize(:nanoseconds), do: :nanosecond
  defp normalize(other), do: other
end
