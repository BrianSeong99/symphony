defmodule SymphonyElixir.IssueDependencies do
  @moduledoc """
  Dependency graph helpers for local Symphony issues.
  """

  alias SymphonyElixir.Issues.{IssueDependency, SymphonyIssue}

  @ready_statuses ~w(ready)
  @satisfied_statuses ~w(done)

  @type graph :: %{
          issues: %{required(integer()) => SymphonyIssue.t()},
          dependencies_by_issue: %{required(integer()) => [IssueDependency.t()]},
          blocks_by_issue: %{required(integer()) => [IssueDependency.t()]}
        }

  @spec build_graph([SymphonyIssue.t()], [IssueDependency.t()]) ::
          {:ok, graph()} | {:error, {:cycle_detected, [integer()]}}
  def build_graph(issues, edges) when is_list(issues) and is_list(edges) do
    issue_ids = issues |> Enum.map(& &1.id) |> MapSet.new()
    scoped_edges = Enum.filter(edges, &(MapSet.member?(issue_ids, &1.dependent_issue_id) and MapSet.member?(issue_ids, &1.dependency_issue_id)))

    case find_cycle(issue_ids, scoped_edges) do
      nil ->
        {:ok,
         %{
           issues: Map.new(issues, &{&1.id, &1}),
           dependencies_by_issue: Enum.group_by(scoped_edges, & &1.dependent_issue_id),
           blocks_by_issue: Enum.group_by(scoped_edges, & &1.dependency_issue_id)
         }}

      cycle ->
        {:error, {:cycle_detected, cycle}}
    end
  end

  @spec ready_issues([SymphonyIssue.t()], [IssueDependency.t()]) ::
          {:ok, [SymphonyIssue.t()]} | {:error, {:cycle_detected, [integer()]}}
  def ready_issues(issues, edges) when is_list(issues) and is_list(edges) do
    with {:ok, graph} <- build_graph(issues, edges) do
      ready =
        issues
        |> Enum.filter(&(&1.status in @ready_statuses and dependencies_satisfied?(&1, graph)))
        |> Enum.sort_by(& &1.id)

      {:ok, ready}
    end
  end

  @spec blocked_issues([SymphonyIssue.t()], [IssueDependency.t()]) ::
          {:ok, [map()]} | {:error, {:cycle_detected, [integer()]}}
  def blocked_issues(issues, edges) when is_list(issues) and is_list(edges) do
    with {:ok, graph} <- build_graph(issues, edges) do
      blocked =
        issues
        |> Enum.map(&blocked_entry(&1, graph))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.issue.id)

      {:ok, blocked}
    end
  end

  @spec github_dependency_summary(SymphonyIssue.t(), [SymphonyIssue.t()], [IssueDependency.t()]) :: String.t()
  def github_dependency_summary(%SymphonyIssue{} = issue, issues, edges)
      when is_list(issues) and is_list(edges) do
    issues_by_id = Map.new(issues, &{&1.id, &1})

    lines =
      edges
      |> Enum.filter(&(&1.dependent_issue_id == issue.id))
      |> Enum.sort_by(& &1.dependency_issue_id)
      |> Enum.map(fn edge ->
        dependency = Map.fetch!(issues_by_id, edge.dependency_issue_id)
        condition = if present?(edge.unblock_condition), do: " — #{edge.unblock_condition}", else: ""
        "- ##{dependency.id} #{dependency.title} (#{dependency.status})#{condition}"
      end)

    if lines == [] do
      "## Symphony Dependencies\n\nNo dependencies."
    else
      "## Symphony Dependencies\n\nDepends on:\n" <> Enum.join(lines, "\n")
    end
  end

  defp dependencies_satisfied?(%SymphonyIssue{} = issue, graph) do
    graph.dependencies_by_issue
    |> Map.get(issue.id, [])
    |> Enum.all?(fn edge ->
      graph.issues
      |> Map.fetch!(edge.dependency_issue_id)
      |> dependency_satisfied?(edge)
    end)
  end

  defp dependency_satisfied?(%SymphonyIssue{status: status}, %IssueDependency{dependency_policy: "all_done"}) do
    status in @satisfied_statuses
  end

  defp blocked_entry(%SymphonyIssue{} = issue, graph) do
    blockers =
      graph.dependencies_by_issue
      |> Map.get(issue.id, [])
      |> Enum.reject(fn edge ->
        dependency = Map.fetch!(graph.issues, edge.dependency_issue_id)
        dependency_satisfied?(dependency, edge)
      end)
      |> Enum.map(fn edge ->
        dependency = Map.fetch!(graph.issues, edge.dependency_issue_id)

        %{
          dependency_issue_id: dependency.id,
          dependency_title: dependency.title,
          dependency_status: dependency.status,
          unblock_condition: edge.unblock_condition
        }
      end)

    if blockers == [] do
      nil
    else
      %{issue: issue, blocked_by: blockers}
    end
  end

  defp find_cycle(issue_ids, edges) do
    adjacency =
      edges
      |> Enum.group_by(& &1.dependent_issue_id, & &1.dependency_issue_id)
      |> Map.new(fn {issue_id, dependencies} -> {issue_id, Enum.sort(dependencies)} end)

    issue_ids
    |> Enum.sort()
    |> Enum.reduce_while(nil, fn issue_id, _acc ->
      case visit(issue_id, adjacency, MapSet.new(), MapSet.new(), []) do
        {:cycle, cycle} -> {:halt, cycle}
        :ok -> {:cont, nil}
      end
    end)
  end

  defp visit(issue_id, adjacency, visiting, visited, path) do
    cond do
      MapSet.member?(visiting, issue_id) ->
        {:cycle, cycle_from_path(issue_id, path)}

      MapSet.member?(visited, issue_id) ->
        :ok

      true ->
        visiting = MapSet.put(visiting, issue_id)
        path = [issue_id | path]

        visit_dependencies(Map.get(adjacency, issue_id, []), adjacency, visiting, visited, path)
    end
  end

  defp visit_dependencies(dependency_ids, adjacency, visiting, visited, path) do
    Enum.reduce_while(dependency_ids, :ok, fn dependency_id, _acc ->
      case visit(dependency_id, adjacency, visiting, visited, path) do
        {:cycle, cycle} -> {:halt, {:cycle, cycle}}
        :ok -> {:cont, :ok}
      end
    end)
  end

  defp cycle_from_path(issue_id, path) do
    path
    |> Enum.take_while(&(&1 != issue_id))
    |> Kernel.++([issue_id])
    |> Enum.reverse()
  end

  defp present?(value), do: is_binary(value) and value != ""
end
