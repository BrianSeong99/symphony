defmodule SymphonyElixir.HomelabFullSyncTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Homelab.FullSync

  test "loads Homelab as the owned native full-sync project" do
    config = FullSync.config!()

    assert config.project_key == "homelab"
    assert config.linear_team_key == "LAB"
    assert config.linear_project_key == "homelab-02e0c66d1cb8"
    assert config.linear_project_url == "https://linear.app/brianseong/project/homelab-02e0c66d1cb8"
    assert config.sync_profile == "native-full-sync"
    assert config.github_repository == "BrianSeong99/homelab"
    assert config.full_sync_allowed
  end

  test "plans Linear, Symphony, GitHub issue, and PR associations for Homelab handoff" do
    plan = FullSync.plan_handoff(handoff_attrs(), performer: performer(self()))

    assert plan.source_of_truth == "symphony"

    assert plan.associations |> Enum.map(& &1.link_type) |> Enum.sort() == [
             "github_issue",
             "github_pr",
             "github_repo",
             "linear_issue",
             "linear_project",
             "symphony_issue"
           ]

    assert plan.github.mode == "full_sync"

    assert plan.github.performed == [
             "sync_issue",
             "sync_labels",
             "sync_milestone",
             "sync_workpad_comment",
             "sync_pr_link",
             "sync_review_state",
             "ingest_checks",
             "ingest_reviews"
           ]

    assert plan.github.skipped == []
    assert plan.linear.mirrored == ["dependency_summary", "run_summary"]

    assert_receive {:performed, %{action: "sync_issue"}}
    assert_receive {:performed, %{action: "sync_pr_link"}}
  end

  test "keeps Symphony runtime memory canonical while mirroring safe summaries" do
    plan = FullSync.plan_handoff(handoff_attrs())

    assert plan.symphony.canonical_fields == ~w(agent_memory validation dependencies audit_events)
    assert plan.symphony.private_state.agent_memory == "Secret builder context"
    assert "agent_memory" in plan.projection.symphony_allowed
    refute "agent_memory" in plan.projection.github_issue_allowed

    linear_payload = inspect(plan.linear.sync_events)
    refute linear_payload =~ "Secret builder context"
    refute linear_payload =~ "Private workpad"

    assert linear_payload =~ "Ready after smoke test"
    assert linear_payload =~ "Depends on: none"
  end

  defp handoff_attrs do
    %{
      project_id: 1,
      symphony_issue_id: 9,
      linear_issue_id: "lin-homelab-9",
      linear_issue_url: "https://linear.app/brian/issue/HOM-9",
      github_issue_id: "18",
      github_issue_url: "https://github.com/BrianSeong99/homelab/issues/18",
      github_pr_number: 51,
      github_pr_url: "https://github.com/BrianSeong99/homelab/pull/51",
      title: "Homelab runtime validation",
      github_issue_body: "Public Homelab rollout checklist.",
      dependency_summary: "Depends on: none",
      dependencies: [],
      labels: ["runtime"],
      milestone_title: "Linear cockpit + Symphony kernel v1",
      workpad: "Private workpad",
      workpad_public_summary: "Public-safe workpad summary",
      agent_memory: "Secret builder context",
      validation_summary: "Ready after smoke test",
      run_summary: "Ready after smoke test",
      run_metrics: %{duration_seconds: 180, retries: 0},
      pr_state: "open",
      checks: "green",
      public_comments: "Ready for validation",
      private_comments: "Keep this private",
      review_state: "approved",
      review_body: "Review loop passed",
      audit_events: [%{action: "run.completed"}]
    }
  end

  defp performer(parent) do
    fn operation ->
      send(parent, {:performed, operation})
      {:ok, %{"ok" => true, "action" => operation.action}}
    end
  end
end
