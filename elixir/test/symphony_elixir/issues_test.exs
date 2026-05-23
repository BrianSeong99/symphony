defmodule SymphonyElixir.IssuesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Issues
  alias SymphonyElixir.Issues.SymphonyIssue

  test "issue statuses cover the dashboard-first lifecycle" do
    assert Issues.statuses() == [
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
  end

  test "issue changeset validates local issue fields and defaults" do
    changeset =
      SymphonyIssue.changeset(%SymphonyIssue{}, %{
        project_id: 123,
        title: "Add homelab health endpoint",
        description: "Expose a durable health route for dashboard checks.",
        issue_type: "infra-homelab",
        acceptance_criteria: ["Health endpoint returns 200"],
        validation_plan: ["Run compose healthcheck"]
      })

    assert changeset.valid?

    issue = Ecto.Changeset.apply_action!(changeset, :insert)
    assert issue.status == "draft"
    assert issue.risk_level == "medium"
    assert issue.acceptance_criteria == ["Health endpoint returns 200"]
    assert issue.validation_plan == ["Run compose healthcheck"]
  end

  test "issue changeset rejects unsupported statuses, risk levels, and issue types" do
    changeset =
      SymphonyIssue.changeset(%SymphonyIssue{}, %{
        project_id: 123,
        title: "Bad issue",
        issue_type: "whatever",
        status: "mystery",
        risk_level: "reckless"
      })

    refute changeset.valid?
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :issue_type)
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :status)
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :risk_level)
  end

  test "readiness blocks issues without issue type, acceptance criteria, or validation" do
    issue = %SymphonyIssue{
      title: "Incomplete task",
      risk_level: "medium",
      acceptance_criteria: [],
      validation_plan: []
    }

    assert %{
             ready?: false,
             status: "needs-spec",
             missing: [:issue_type, :acceptance_criteria, :validation_plan]
           } = Issues.readiness(issue)
  end

  test "readiness marks issue ready when template and validation requirements are present" do
    issue = %SymphonyIssue{
      title: "Ready task",
      issue_type: "feature",
      risk_level: "medium",
      acceptance_criteria: ["User can create a project"],
      validation_plan: ["Run project creation test"]
    }

    assert %{ready?: true, status: "ready", missing: []} = Issues.readiness(issue)
  end
end
