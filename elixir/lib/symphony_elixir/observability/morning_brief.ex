defmodule SymphonyElixir.Observability.MorningBrief do
  @moduledoc """
  Builds Linear-safe morning brief projections from Symphony runtime state.
  """

  alias SymphonyElixir.Observability.RunMetrics
  alias SymphonyElixir.ProjectionTemplates

  @section_keys [
    :ready_work,
    :blocked_work,
    :overnight_outcomes,
    :checkpoint_requests,
    :recommended_next_actions
  ]

  @spec build(map()) :: map()
  def build(attrs), do: build(attrs, [])

  @spec build(map(), keyword()) :: map()
  def build(attrs, opts) when is_map(attrs) and is_list(opts) do
    template = Keyword.get(opts, :template, :homelab)
    metrics = RunMetrics.aggregate(map_get(attrs, :runs, []), opts)
    sections = sections(attrs)
    body = brief_body(sections, metrics)
    projection = linear_projection(template, body, metrics, attrs)

    %{
      generated_for: map_get(attrs, :date),
      source_of_truth: "symphony",
      sections: sections,
      metrics: metrics,
      checkpoint_count: length(sections.checkpoint_requests),
      linear_update: %{
        body: projection.allowed[:public_comments] || body,
        projection: projection,
        private_fields_included: private_fields_included?(projection.allowed)
      }
    }
  end

  defp sections(attrs) do
    Map.new(@section_keys, fn key -> {key, List.wrap(map_get(attrs, key, []))} end)
  end

  defp linear_projection(template, body, metrics, attrs) do
    ProjectionTemplates.preview_surface(template, :linear_comment, %{
      public_comments: body,
      validation: validation_summary(attrs),
      run_metrics: metrics
    })
  end

  defp validation_summary(attrs) do
    [
      count_phrase(map_get(attrs, :ready_work, []), "ready"),
      count_phrase(map_get(attrs, :blocked_work, []), "blocked"),
      count_phrase(map_get(attrs, :checkpoint_requests, []), "checkpoint")
    ]
    |> Enum.join(", ")
  end

  defp count_phrase(values, label), do: "#{length(List.wrap(values))} #{label}"

  defp brief_body(sections, metrics) do
    [
      "Morning brief",
      section_line("Ready work", sections.ready_work),
      section_line("Blocked work", sections.blocked_work),
      section_line("Overnight outcomes", sections.overnight_outcomes),
      section_line("Checkpoint requests", sections.checkpoint_requests),
      section_line("Recommended next actions", sections.recommended_next_actions),
      metrics_line(metrics)
    ]
    |> Enum.join("\n")
  end

  defp section_line(label, []), do: "#{label}: none"

  defp section_line(label, values) do
    "#{label}: #{Enum.map_join(values, "; ", &item_summary/1)}"
  end

  defp item_summary(value) when is_binary(value), do: value

  defp item_summary(value) when is_map(value) do
    [
      map_get(value, :identifier),
      map_get(value, :title),
      map_get(value, :reason)
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" - ")
  end

  defp item_summary(value), do: inspect(value)

  defp metrics_line(metrics) do
    "Metrics: plan #{format_metric(metrics.time_to_plan_seconds)}s, PR #{format_metric(metrics.time_to_pr_seconds)}s, retries #{metrics.retry_count}, CI #{metrics.ci_pass_rate}, review findings #{metrics.review_finding_rate}, loop breaker #{metrics.loop_breaker_rate}, cost proxy #{metrics.runtime_cost_proxy}, human #{metrics.human_intervention_count}"
  end

  defp format_metric(nil), do: "n/a"
  defp format_metric(value), do: to_string(value)

  defp private_fields_included?(allowed) do
    Enum.any?([:workpad, :agent_memory, :private_comments], &Map.has_key?(allowed, &1))
  end

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
