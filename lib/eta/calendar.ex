defmodule Eta.Calendar do
  @moduledoc """
  Where the calendar constructors land after the rewrite.

  `DateTime.utc_now/0,1,2`, `NaiveDateTime.utc_now/0,1,2`, `Time.utc_now/0,1,2`
  and `Date.utc_today/0,1` all read `os:system_time` *inside* their own
  modules — a clock dependence no transform of user code can reach, and one
  that does not even look like a clock read at the call site. Their call
  sites are rewritten here instead, and each value is rebuilt from
  `eta_time:system_time/1` through `DateTime.from_unix!/3`, which is pure.

  The dispatch mirrors the originals': the optional argument is a calendar
  unless it is one of the canonical time units, and the unit variants carry
  the same precision the real constructors give them (a `:millisecond`
  `utc_now` truncates to three digits here as there).

  `eta_time` delegates to the real clock when no virtual one is running, so a
  module rewritten to land here behaves normally outside a simulation.

  *This documentation is LLM-generated. See the AI disclosure in `README.md`.*
  """

  @time_units [:second, :millisecond, :microsecond, :nanosecond, :native]

  @doc "`DateTime.utc_now/0,1,2` on the virtual clock."
  def datetime_utc_now(calendar_or_time_unit \\ Calendar.ISO)

  def datetime_utc_now(unit) when unit in @time_units do
    datetime_utc_now(unit, Calendar.ISO)
  end

  def datetime_utc_now(calendar) do
    DateTime.from_unix!(:eta_time.system_time(), :native, calendar)
  end

  def datetime_utc_now(unit, calendar) when unit in @time_units do
    DateTime.from_unix!(:eta_time.system_time(unit), unit, calendar)
  end

  @doc "`NaiveDateTime.utc_now/0,1,2` on the virtual clock."
  def naive_utc_now(calendar_or_time_unit \\ Calendar.ISO)

  def naive_utc_now(calendar_or_time_unit) do
    DateTime.to_naive(datetime_utc_now(calendar_or_time_unit))
  end

  @doc false
  def naive_utc_now(unit, calendar) do
    DateTime.to_naive(datetime_utc_now(unit, calendar))
  end

  @doc "`Time.utc_now/0,1,2` on the virtual clock."
  def time_utc_now(calendar_or_time_unit \\ Calendar.ISO)

  def time_utc_now(calendar_or_time_unit) do
    DateTime.to_time(datetime_utc_now(calendar_or_time_unit))
  end

  @doc false
  def time_utc_now(unit, calendar) do
    DateTime.to_time(datetime_utc_now(unit, calendar))
  end

  @doc "`Date.utc_today/0,1` on the virtual clock."
  def date_utc_today(calendar \\ Calendar.ISO) do
    DateTime.to_date(datetime_utc_now(calendar))
  end
end
