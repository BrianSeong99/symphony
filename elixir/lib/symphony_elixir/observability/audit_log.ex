defmodule SymphonyElixir.Observability.AuditLog do
  @moduledoc """
  Builders for canonical Symphony audit events.

  These are local audit payloads first. Downstream Linear or GitHub summaries can
  project selected facts, but raw policy decisions and runtime state stay in
  Symphony.
  """

  @actions %{
    linear_triggered_action: "linear.action",
    github_sync_attempt: "github.sync",
    policy_decision: "policy.decision",
    run_started: "run.started",
    run_stopped: "run.stopped",
    validation_outcome: "validation.outcome",
    loop_breaker_event: "loop_breaker.triggered"
  }

  @type event_kind ::
          :linear_triggered_action
          | :github_sync_attempt
          | :policy_decision
          | :run_started
          | :run_stopped
          | :validation_outcome
          | :loop_breaker_event

  @spec required_action_names() :: [String.t()]
  def required_action_names, do: Map.values(@actions)

  @spec event(event_kind(), map()) :: map()
  def event(kind, attrs) when is_atom(kind) and is_map(attrs) do
    action = Map.fetch!(@actions, kind)

    %{
      project_id: map_get(attrs, :project_id),
      symphony_issue_id: map_get(attrs, :symphony_issue_id),
      actor: map_get(attrs, :actor, "symphony"),
      action: action,
      target_type: map_get(attrs, :target_type, target_type_for(kind)),
      target_id: map_get(attrs, :target_id) || target_id_for(kind, attrs),
      payload: %{
        kind: kind,
        source: map_get(attrs, :source, "symphony"),
        status: map_get(attrs, :status),
        decision: map_get(attrs, :decision),
        evidence: map_get(attrs, :evidence, %{}),
        occurred_at: map_get(attrs, :occurred_at)
      }
    }
  end

  @spec runtime_events(map()) :: [map()]
  def runtime_events(attrs) when is_map(attrs) do
    @actions
    |> Map.keys()
    |> Enum.map(&event(&1, attrs))
  end

  defp target_type_for(:linear_triggered_action), do: "linear"
  defp target_type_for(:github_sync_attempt), do: "github"
  defp target_type_for(:policy_decision), do: "policy"
  defp target_type_for(:run_started), do: "run"
  defp target_type_for(:run_stopped), do: "run"
  defp target_type_for(:validation_outcome), do: "validation"
  defp target_type_for(:loop_breaker_event), do: "loop_breaker"

  defp target_id_for(:linear_triggered_action, attrs), do: map_get(attrs, :linear_issue_id)
  defp target_id_for(:github_sync_attempt, attrs), do: map_get(attrs, :github_url)
  defp target_id_for(:policy_decision, attrs), do: map_get(attrs, :policy_id)
  defp target_id_for(_kind, attrs), do: map_get(attrs, :run_id) || map_get(attrs, :symphony_issue_id)

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
