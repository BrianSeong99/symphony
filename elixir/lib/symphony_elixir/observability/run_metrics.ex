defmodule SymphonyElixir.Observability.RunMetrics do
  @moduledoc """
  Aggregates Symphony run effectiveness metrics.
  """

  @type aggregate :: %{
          required(:run_count) => non_neg_integer(),
          required(:time_to_plan_seconds) => float() | nil,
          required(:time_to_pr_seconds) => float() | nil,
          required(:retry_count) => non_neg_integer(),
          required(:ci_pass_rate) => float(),
          required(:review_finding_rate) => float(),
          required(:loop_breaker_rate) => float(),
          required(:runtime_cost_proxy) => float(),
          required(:human_intervention_count) => non_neg_integer()
        }

  @spec aggregate([map()]) :: aggregate()
  def aggregate(runs), do: aggregate(runs, [])

  @spec aggregate([map()], keyword()) :: aggregate()
  def aggregate(runs, opts) when is_list(runs) and is_list(opts) do
    run_count = length(runs)

    %{
      run_count: run_count,
      time_to_plan_seconds: average_duration(runs, :plan_started_at, :plan_completed_at),
      time_to_pr_seconds: average_duration(runs, :plan_completed_at, :pr_opened_at),
      retry_count: sum_int(runs, [:retry_count, :retries]),
      ci_pass_rate: ci_pass_rate(runs),
      review_finding_rate: review_finding_rate(runs),
      loop_breaker_rate: rate(runs, &truthy?(map_get(&1, :loop_breaker_triggered?))),
      runtime_cost_proxy: runtime_cost_proxy(runs, opts),
      human_intervention_count: sum_int(runs, [:human_intervention_count, :human_interventions])
    }
  end

  defp average_duration(runs, start_key, stop_key) do
    durations =
      runs
      |> Enum.map(&duration(&1, start_key, stop_key))
      |> Enum.reject(&is_nil/1)

    average(durations)
  end

  defp duration(run, start_key, stop_key) do
    with %DateTime{} = started <- datetime(map_get(run, start_key)),
         %DateTime{} = stopped <- datetime(map_get(run, stop_key)) do
      max(DateTime.diff(stopped, started, :second), 0)
    else
      _other -> nil
    end
  end

  defp ci_pass_rate(runs) do
    ci_runs = Enum.filter(runs, &(not is_nil(map_get(&1, :ci_status))))
    rate(ci_runs, &(map_get(&1, :ci_status) in [:passed, "passed", :green, "green", :success, "success"]))
  end

  defp review_finding_rate(runs) do
    reviewed =
      Enum.filter(runs, fn run ->
        not is_nil(map_get(run, :review_findings)) or truthy?(map_get(run, :reviewed?))
      end)

    case length(reviewed) do
      0 -> 0.0
      count -> reviewed |> sum_int([:review_findings]) |> Kernel./(count) |> Float.round(4)
    end
  end

  defp runtime_cost_proxy(runs, opts) do
    input_weight = Keyword.get(opts, :input_token_weight, 1.0)
    output_weight = Keyword.get(opts, :output_token_weight, 4.0)

    runs
    |> Enum.reduce(0.0, fn run, total ->
      total +
        int_value(run, :input_tokens) * input_weight +
        int_value(run, :output_tokens) * output_weight
    end)
    |> Kernel./(1000)
    |> Float.round(4)
  end

  defp rate([], _predicate), do: 0.0

  defp rate(values, predicate) when is_function(predicate, 1) do
    matches = Enum.count(values, predicate)

    (matches / length(values))
    |> Float.round(4)
  end

  defp average([]), do: nil

  defp average(values) do
    values
    |> Enum.sum()
    |> Kernel./(length(values))
    |> Float.round(2)
  end

  defp sum_int(values, keys) do
    Enum.reduce(values, 0, fn value, total ->
      total + first_present_int(value, keys)
    end)
  end

  defp first_present_int(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      if key_present?(map, key), do: int_value(map, key)
    end)
  end

  defp int_value(map, key) do
    case map_get(map, key, 0) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      value when is_binary(value) -> parse_int(value)
      _other -> 0
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp datetime(%DateTime{} = value), do: value

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp datetime(_value), do: nil

  defp truthy?(value), do: value in [true, true, "true", "yes", "1", 1]

  defp key_present?(map, key) when is_map(map) and is_atom(key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end

  defp key_present?(map, key) when is_map(map), do: Map.has_key?(map, key)
  defp key_present?(_map, _key), do: false

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
