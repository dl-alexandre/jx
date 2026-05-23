defmodule JX.HostCapacity.Evaluator do
  @moduledoc """
  Analyses stored `Observation` records for a host and recommends whether to
  raise, lower, or hold the `capacity_limit`.

  ## How it works

  The evaluator looks at observations collected **while sessions were running**
  and computes the average RAM headroom per active session:

      headroom_per_session = ram_available_mb / active_sessions

  It compares that against the configured profile's `ram_mb_per_slot` (the
  assumed cost per session) to determine memory pressure:

      pressure_ratio = headroom_per_session / profile.ram_mb_per_slot

  | pressure_ratio | signal        | action          |
  |----------------|---------------|-----------------|
  | > 2.0          | under-used    | suggest raising |
  | 0.5 – 2.0      | healthy range | hold            |
  | < 0.5          | tight         | suggest lowering|

  The load average (when available) is used as a secondary signal: sustained
  load > 80% of logical cores triggers a lower recommendation regardless of RAM.

  Recommendations are advisory — the operator applies them with
  `jx host capacity set <host> <n>`.
  """

  alias JX.HostCapacity
  alias JX.HostCapacity.Observer

  @under_used_threshold 2.0
  @tight_threshold 0.5
  @load_pressure_ratio 0.8

  # Minimum observations required before we'll produce a non-trivial verdict
  @min_observations 3

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Evaluates stored observations for `host_name` and returns a recommendation
  map:

      %{
        host:                   "host-a",
        observations_analysed:  42,
        avg_headroom_per_slot:  4096,       # MB
        avg_load_ratio:         0.45,       # fraction of total cores, nil if unavailable
        current_limit:          8,          # nil = formula-derived
        verdict:                :raise | :lower | :hold | :insufficient_data,
        suggested_limit:        10,         # nil when verdict is :hold or :insufficient_data
        reasoning:              "..."
      }
  """
  @spec evaluate(String.t(), keyword()) :: map()
  def evaluate(host_name, opts \\ []) do
    profile = Keyword.get(opts, :profile, HostCapacity.default_profile())
    current_limit = Keyword.get(opts, :current_limit)

    observations = Observer.under_load(host_name)

    if length(observations) < @min_observations do
      %{
        host: host_name,
        observations_analysed: length(observations),
        avg_headroom_per_slot: nil,
        avg_load_ratio: nil,
        current_limit: current_limit,
        verdict: :insufficient_data,
        suggested_limit: nil,
        reasoning:
          "Need at least #{@min_observations} observations under load; " <>
            "only #{length(observations)} recorded so far. " <>
            "Run more sessions and observe again."
      }
    else
      analyse(host_name, observations, profile, current_limit)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp analyse(host_name, observations, profile, current_limit) do
    avg_headroom = avg_headroom_per_slot(observations)
    avg_load_ratio = avg_load_ratio(observations)
    pressure_ratio = avg_headroom / profile.ram_mb_per_slot

    ram_verdict = ram_verdict(pressure_ratio)
    cpu_verdict = cpu_verdict(avg_load_ratio, observations)

    # CPU pressure overrides an "under-used" RAM signal
    final_verdict =
      cond do
        cpu_verdict == :lower -> :lower
        ram_verdict == :lower -> :lower
        ram_verdict == :raise and cpu_verdict != :lower -> :raise
        true -> :hold
      end

    effective_limit = current_limit || avg_active_sessions(observations)

    suggested_limit =
      case final_verdict do
        :raise -> ceil(effective_limit * 1.25) |> max(effective_limit + 1)
        :lower -> max(floor(effective_limit * 0.75), 1)
        :hold -> nil
      end

    %{
      host: host_name,
      observations_analysed: length(observations),
      avg_headroom_per_slot: round(avg_headroom),
      avg_load_ratio: avg_load_ratio && Float.round(avg_load_ratio, 2),
      current_limit: current_limit,
      verdict: final_verdict,
      suggested_limit: suggested_limit,
      reasoning: build_reasoning(final_verdict, pressure_ratio, avg_load_ratio, profile)
    }
  end

  defp avg_headroom_per_slot(observations) do
    observations
    |> Enum.map(fn o ->
      sessions = max(o.active_sessions, 1)
      o.ram_available_mb / sessions
    end)
    |> avg()
  end

  defp avg_load_ratio(observations) do
    load_points =
      observations
      |> Enum.filter(&(&1.load_avg_1m != nil and &1.cpu_cores > 0))
      |> Enum.map(&(&1.load_avg_1m / &1.cpu_cores))

    if load_points == [], do: nil, else: avg(load_points)
  end

  defp avg_active_sessions(observations) do
    observations |> Enum.map(& &1.active_sessions) |> avg() |> round()
  end

  defp avg(list) when list == [], do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp ram_verdict(pressure_ratio) do
    cond do
      pressure_ratio > @under_used_threshold -> :raise
      pressure_ratio < @tight_threshold -> :lower
      true -> :hold
    end
  end

  defp cpu_verdict(nil, _observations), do: :hold

  defp cpu_verdict(avg_load_ratio, _observations) do
    if avg_load_ratio > @load_pressure_ratio, do: :lower, else: :hold
  end

  defp build_reasoning(:raise, pressure_ratio, avg_load_ratio, profile) do
    ratio_pct = round(pressure_ratio * 100)
    load_note = if avg_load_ratio, do: "; avg CPU load #{round(avg_load_ratio * 100)}%", else: ""

    "Average RAM headroom per session is #{ratio_pct}% of the #{profile.ram_mb_per_slot} MB " <>
      "profile threshold (pressure_ratio #{Float.round(pressure_ratio, 2)})#{load_note}. " <>
      "Host appears under-utilised — consider raising the limit."
  end

  defp build_reasoning(:lower, pressure_ratio, avg_load_ratio, profile) do
    ratio_pct = round(pressure_ratio * 100)

    cpu_note =
      if avg_load_ratio && avg_load_ratio > @load_pressure_ratio do
        "; avg CPU load #{round(avg_load_ratio * 100)}% exceeds #{round(@load_pressure_ratio * 100)}% threshold"
      else
        ""
      end

    "Average RAM headroom per session is #{ratio_pct}% of the #{profile.ram_mb_per_slot} MB " <>
      "profile threshold (pressure_ratio #{Float.round(pressure_ratio, 2)})#{cpu_note}. " <>
      "Host is under pressure — consider lowering the limit."
  end

  defp build_reasoning(:hold, pressure_ratio, avg_load_ratio, _profile) do
    ratio_pct = round(pressure_ratio * 100)
    load_note = if avg_load_ratio, do: "; avg CPU load #{round(avg_load_ratio * 100)}%", else: ""

    "RAM pressure ratio #{Float.round(pressure_ratio, 2)} (#{ratio_pct}% of profile) is " <>
      "within the healthy 0.5–2.0 range#{load_note}. Current limit looks right."
  end
end
