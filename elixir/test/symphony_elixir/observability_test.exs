defmodule SymphonyElixir.ObservabilityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AuditEvent
  alias SymphonyElixir.Observability.{AuditLog, MorningBrief, RunMetrics}

  test "audit log emits required runtime, policy, relay, validation, and loop breaker events" do
    events =
      AuditLog.runtime_events(%{
        project_id: 1,
        symphony_issue_id: 20,
        actor: "symphony",
        linear_issue_id: "HOM-20",
        github_url: "https://github.com/BrianSeong99/homelab/pull/51",
        policy_id: "homelab",
        run_id: "run-20",
        status: "success",
        decision: "allow",
        evidence: %{checks: "green"},
        occurred_at: "2026-05-24T00:00:00Z"
      })

    assert Enum.map(events, & &1.action) |> Enum.sort() ==
             AuditLog.required_action_names() |> Enum.sort()

    for event <- events do
      assert AuditEvent.changeset(%AuditEvent{}, event).valid?
    end
  end

  test "run metrics aggregate planning, PR, retries, CI, review, loop breaker, cost, and human counts" do
    metrics = RunMetrics.aggregate(runs())

    assert metrics.run_count == 2
    assert metrics.time_to_plan_seconds == 210.0
    assert metrics.time_to_pr_seconds == 420.0
    assert metrics.retry_count == 3
    assert metrics.ci_pass_rate == 0.5
    assert metrics.review_finding_rate == 1.5
    assert metrics.loop_breaker_rate == 0.5
    assert metrics.runtime_cost_proxy == 6.0
    assert metrics.human_intervention_count == 3
  end

  test "morning brief groups work and projects only Linear-safe summaries" do
    brief =
      MorningBrief.build(%{
        date: "2026-05-24",
        ready_work: [%{identifier: "HOM-1", title: "Run smoke test"}],
        blocked_work: [%{identifier: "HOM-2", title: "Deploy route", reason: "waiting for checkpoint"}],
        overnight_outcomes: [%{identifier: "HOM-3", title: "PR validated"}],
        checkpoint_requests: [%{identifier: "HOM-4", title: "Approve unattended run"}],
        recommended_next_actions: ["Merge green Homelab PR"],
        runs: runs(),
        workpad: "Private workpad content",
        agent_memory: "Persistent builder session memory"
      })

    assert brief.source_of_truth == "symphony"
    assert brief.checkpoint_count == 1
    assert brief.sections.ready_work == [%{identifier: "HOM-1", title: "Run smoke test"}]
    assert brief.linear_update.private_fields_included == false

    body = brief.linear_update.body
    assert body =~ "Ready work: HOM-1 - Run smoke test"
    assert body =~ "Blocked work: HOM-2 - Deploy route - waiting for checkpoint"
    assert body =~ "Recommended next actions: Merge green Homelab PR"
    refute body =~ "Private workpad content"
    refute body =~ "Persistent builder session memory"

    assert brief.linear_update.projection.allowed.public_comments == body
    assert brief.linear_update.projection.allowed.run_metrics == "[summary available]"
    refute Map.has_key?(brief.linear_update.projection.allowed, :agent_memory)
  end

  defp runs do
    [
      %{
        plan_started_at: "2026-05-24T00:00:00Z",
        plan_completed_at: "2026-05-24T00:02:00Z",
        pr_opened_at: "2026-05-24T00:07:00Z",
        retry_count: 1,
        ci_status: "passed",
        review_findings: 2,
        loop_breaker_triggered?: false,
        input_tokens: 1000,
        output_tokens: 500,
        human_intervention_count: 1
      },
      %{
        plan_started_at: "2026-05-24T01:00:00Z",
        plan_completed_at: "2026-05-24T01:05:00Z",
        pr_opened_at: "2026-05-24T01:14:00Z",
        retries: 2,
        ci_status: "failed",
        review_findings: 1,
        loop_breaker_triggered?: true,
        input_tokens: 2000,
        output_tokens: 250,
        human_interventions: 2
      }
    ]
  end
end
