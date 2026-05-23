defmodule SymphonyElixir.Issues do
  @moduledoc """
  Local dashboard-first Symphony issue lifecycle and readiness rules.
  """

  alias SymphonyElixir.Issues.SymphonyIssue

  @statuses [
    :draft,
    :needs_spec,
    :ready,
    :planning,
    :running,
    :reviewing,
    :blocked,
    :human_checkpoint,
    :ready_to_merge,
    :done,
    :cancelled,
    :paused
  ]

  @issue_types ~w(feature bug docs frontend-ui backend-api contract-security infra-homelab test-validation refactor research-spike release-integration follow-up-tech-debt)

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec status_strings() :: [String.t()]
  def status_strings, do: Enum.map(@statuses, &status_to_string/1)

  @spec issue_types() :: [String.t()]
  def issue_types, do: @issue_types

  @spec readiness(SymphonyIssue.t()) :: %{ready?: boolean(), status: String.t(), missing: [atom()]}
  def readiness(%SymphonyIssue{} = issue) do
    missing =
      []
      |> maybe_missing(:issue_type, blank?(issue.issue_type))
      |> maybe_missing(:acceptance_criteria, empty_list?(issue.acceptance_criteria))
      |> maybe_missing(:validation_plan, empty_list?(issue.validation_plan))
      |> maybe_missing(:risk_level, blank?(issue.risk_level))
      |> Enum.reverse()

    if missing == [] do
      %{ready?: true, status: "ready", missing: []}
    else
      %{ready?: false, status: "needs-spec", missing: missing}
    end
  end

  defp status_to_string(status) do
    status
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp maybe_missing(missing, field, true), do: [field | missing]
  defp maybe_missing(missing, _field, false), do: missing

  defp blank?(value), do: is_nil(value) or value == ""
  defp empty_list?(value), do: not is_list(value) or value == []
end
