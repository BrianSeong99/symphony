defmodule SymphonyElixir.SchedulerGatesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentSessions.AgentSession
  alias SymphonyElixir.Issues.{IssueDependency, SymphonyIssue}
  alias SymphonyElixir.Scheduler.Gates

  test "builds a dependency DAG and dispatches ready independent issues in parallel" do
    issues = [
      issue(1, "done", "Persistence"),
      issue(2, "ready", "Project connections"),
      issue(3, "ready", "Runtime actions"),
      issue(4, "ready", "Homelab deployment"),
      issue(5, "ready", "Scheduler")
    ]

    edges = [
      edge(2, 1, "persistence merged"),
      edge(4, 5, "scheduler gates merged")
    ]

    assert {:ok, plan} = Gates.plan(issues, edges, max_concurrency: 3)

    assert Enum.map(plan.dispatch, & &1.issue.id) == [2, 3, 5]
    assert Enum.map(plan.blocked, & &1.issue.id) == [4]

    assert hd(plan.blocked).blocked_by == [
             %{
               dependency_issue_id: 5,
               dependency_title: "Scheduler",
               dependency_status: "ready",
               unblock_condition: "scheduler gates merged"
             }
           ]

    assert plan.waiting == []
  end

  test "detects dependency cycles before dispatch" do
    issues = [issue(1, "ready", "A"), issue(2, "ready", "B")]
    edges = [edge(1, 2, "B done"), edge(2, 1, "A done")]

    assert {:error, %{reason: :dependency_cycle, cycle: [1, 2]}} = Gates.plan(issues, edges)
  end

  test "applies global, project, and repository concurrency bounds" do
    issues = [
      issue(1, "ready", "A", project_id: 10, repository_id: 100),
      issue(2, "ready", "B", project_id: 10, repository_id: 100),
      issue(3, "ready", "C", project_id: 11, repository_id: 101)
    ]

    assert {:ok, plan} =
             Gates.plan(issues, [],
               max_concurrency: 3,
               project_concurrency: %{10 => 1},
               repository_concurrency: %{100 => 1}
             )

    assert Enum.map(plan.dispatch, & &1.issue.id) == [1, 3]
    assert Enum.map(plan.waiting, & &1.issue.id) == [2]
    assert hd(plan.waiting).reasons == [:project_concurrency_limit, :repository_concurrency_limit]
  end

  test "holds issues for checkpoints, loop breaker decisions, project policy, and relay safety" do
    issues = [
      issue(1, "ready", "Needs checkpoint", metadata: %{"human_checkpoint_required" => true}),
      issue(2, "ready", "Looping"),
      issue(3, "ready", "Policy hold"),
      issue(4, "ready", "Relay hold")
    ]

    loop_events = [
      %{kind: :validation_failure, phase: "test", command: "mix test", error: "boom"},
      %{kind: :validation_failure, phase: "test", command: "mix test", error: "boom"}
    ]

    assert {:ok, plan} =
             Gates.plan(issues, [],
               loop_events_by_issue: %{2 => loop_events},
               project_policy_holds: %{3 => :miden_public_projection_blocked},
               relay_safety_holds: %{4 => :projection_conflict}
             )

    assert plan.dispatch == []
    assert Enum.map(plan.held, & &1.issue.id) == [1, 2, 3, 4]
    assert Enum.flat_map(plan.held, & &1.reasons) == [:human_checkpoint_required, :loop_breaker_hold, :miden_public_projection_blocked, :projection_conflict]
  end

  test "dispatch entries include persistent builder session create or resume intent" do
    active_session = %AgentSession{
      symphony_issue_id: 2,
      role: "builder",
      backend: "claude_code",
      session_id: "builder:2",
      status: "active",
      metadata: %{}
    }

    assert {:ok, plan} = Gates.plan([issue(1, "ready", "New"), issue(2, "ready", "Existing")], [], sessions: [active_session])

    assert Enum.map(plan.dispatch, &{&1.issue.id, &1.session_action, &1.session.session_id}) == [
             {1, :create, "builder:1"},
             {2, :resume, "builder:2"}
           ]
  end

  test "dependency summaries preview to Linear and GitHub only when policy allows" do
    issues = [issue(1, "done", "Foundation"), issue(2, "ready", "Public projection")]
    edges = [edge(2, 1, "foundation merged")]

    homelab = Gates.dependency_projection(issue(2, "ready", "Public projection"), issues, edges, :homelab)

    assert homelab.summary =~ "Depends on:"
    assert homelab.linear.allowed.dependencies =~ "Foundation"
    assert homelab.github_issue.allowed.dependencies =~ "Foundation"

    miden = Gates.dependency_projection(issue(2, "ready", "Public projection"), issues, edges, :miden)

    assert miden.linear.allowed.dependencies =~ "Foundation"
    assert miden.github_issue.allowed == %{}
    assert miden.github_issue.rejected == %{}
  end

  defp issue(id, status, title, attrs \\ []) do
    %SymphonyIssue{
      id: id,
      project_id: Keyword.get(attrs, :project_id, 1),
      repository_id: Keyword.get(attrs, :repository_id),
      title: title,
      status: status,
      risk_level: "medium",
      metadata: Keyword.get(attrs, :metadata, %{})
    }
  end

  defp edge(dependent_issue_id, dependency_issue_id, unblock_condition) do
    %IssueDependency{
      dependent_issue_id: dependent_issue_id,
      dependency_issue_id: dependency_issue_id,
      dependency_policy: "all_done",
      unblock_condition: unblock_condition
    }
  end
end
