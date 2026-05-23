defmodule SymphonyElixir.IssueDependenciesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueDependencies
  alias SymphonyElixir.Issues.{IssueDependency, SymphonyIssue}

  test "dependency schema validates dependent and dependency issue edges" do
    changeset =
      IssueDependency.changeset(%IssueDependency{}, %{
        dependent_issue_id: 4,
        dependency_issue_id: 2,
        dependency_policy: "all_done",
        parallel_group: "persistence-foundation",
        phase: 1,
        unblock_condition: "local DB migration merged and validated"
      })

    assert changeset.valid?

    edge = Ecto.Changeset.apply_action!(changeset, :insert)
    assert edge.dependent_issue_id == 4
    assert edge.dependency_issue_id == 2
    assert edge.dependency_policy == "all_done"
    assert edge.parallel_group == "persistence-foundation"
    assert edge.phase == 1
  end

  test "dependency schema rejects self edges and unsupported policies" do
    changeset =
      IssueDependency.changeset(%IssueDependency{}, %{
        dependent_issue_id: 2,
        dependency_issue_id: 2,
        dependency_policy: "magic"
      })

    refute changeset.valid?
    assert {"cannot depend on itself", _} = Keyword.fetch!(changeset.errors, :dependency_issue_id)
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :dependency_policy)
  end

  test "build_graph detects cycles before dispatch" do
    issues = [
      issue(1, "A", "ready"),
      issue(2, "B", "ready"),
      issue(3, "C", "ready")
    ]

    edges = [
      edge(1, 2),
      edge(2, 3),
      edge(3, 1)
    ]

    assert {:error, {:cycle_detected, cycle}} = IssueDependencies.build_graph(issues, edges)
    assert MapSet.new(cycle) == MapSet.new([1, 2, 3])
  end

  test "ready_issues returns every unblocked issue in parallel" do
    issues = [
      issue(2, "Persistence", "done"),
      issue(3, "Projects", "ready"),
      issue(4, "Issues", "ready"),
      issue(8, "GitHub sync", "ready")
    ]

    edges = [
      edge(3, 2),
      edge(4, 2),
      edge(8, 3, "project connection model merged"),
      edge(8, 4, "local issue model merged")
    ]

    assert {:ok, ready} = IssueDependencies.ready_issues(issues, edges)
    assert Enum.map(ready, & &1.id) == [3, 4]
  end

  test "blocked_issues exposes exact unblock reasons" do
    issues = [
      issue(2, "Persistence", "running"),
      issue(3, "Projects", "ready"),
      issue(4, "Issues", "ready")
    ]

    edges = [
      edge(3, 2, "local DB migration merged and validated"),
      edge(4, 2, "local DB migration merged and validated")
    ]

    assert {:ok, blocked} = IssueDependencies.blocked_issues(issues, edges)

    assert %{
             issue: %SymphonyIssue{id: 3, title: "Projects"},
             blocked_by: [
               %{
                 dependency_issue_id: 2,
                 dependency_title: "Persistence",
                 dependency_status: "running",
                 unblock_condition: "local DB migration merged and validated"
               }
             ]
           } = Enum.find(blocked, &(&1.issue.id == 3))
  end

  test "github_dependency_summary renders downstream dependency context" do
    issues = [
      issue(2, "Persistence", "done"),
      issue(8, "GitHub sync", "ready")
    ]

    edges = [
      edge(8, 2, "local DB migration merged and validated")
    ]

    assert IssueDependencies.github_dependency_summary(issue(8, "GitHub sync", "ready"), issues, edges) ==
             """
             ## Symphony Dependencies

             Depends on:
             - #2 Persistence (done) — local DB migration merged and validated
             """
             |> String.trim_trailing()
  end

  defp issue(id, title, status) do
    %SymphonyIssue{id: id, title: title, status: status}
  end

  defp edge(dependent_id, dependency_id, unblock_condition \\ nil) do
    %IssueDependency{
      dependent_issue_id: dependent_id,
      dependency_issue_id: dependency_id,
      dependency_policy: "all_done",
      unblock_condition: unblock_condition
    }
  end
end
