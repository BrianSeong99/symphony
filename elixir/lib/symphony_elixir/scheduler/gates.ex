defmodule SymphonyElixir.Scheduler.Gates do
  @moduledoc """
  Dependency-aware scheduler gates for local Symphony issues.

  This module is a pure planner. It builds the issue DAG, applies dispatch
  limits and safety holds, attaches persistent builder session intent, and
  previews dependency summary projection without starting agents itself.
  """

  alias SymphonyElixir.AgentSessions
  alias SymphonyElixir.IssueDependencies
  alias SymphonyElixir.Issues.{IssueDependency, SymphonyIssue}
  alias SymphonyElixir.LoopBreaker
  alias SymphonyElixir.ProjectionTemplates

  @type plan :: %{
          required(:dispatch) => [map()],
          required(:blocked) => [map()],
          required(:held) => [map()],
          required(:waiting) => [map()],
          required(:capacity) => map()
        }

  @spec plan([SymphonyIssue.t()], [IssueDependency.t()]) :: {:ok, plan()} | {:error, map()}
  def plan(issues, edges), do: plan(issues, edges, [])

  @spec plan([SymphonyIssue.t()], [IssueDependency.t()], keyword()) :: {:ok, plan()} | {:error, map()}
  def plan(issues, edges, opts) when is_list(issues) and is_list(edges) and is_list(opts) do
    with {:ok, _graph} <- IssueDependencies.build_graph(issues, edges),
         {:ok, dependency_ready} <- IssueDependencies.ready_issues(issues, edges),
         {:ok, dependency_blocked} <- IssueDependencies.blocked_issues(issues, edges) do
      {held, eligible} = split_held(dependency_ready, opts)
      {dispatch, waiting} = select_dispatch(eligible, opts)

      {:ok,
       %{
         dispatch: Enum.map(dispatch, &dispatch_entry(&1, opts)),
         blocked: dependency_blocked,
         held: held,
         waiting: waiting,
         capacity: capacity_summary(opts)
       }}
    else
      {:error, {:cycle_detected, cycle}} ->
        {:error, %{reason: :dependency_cycle, cycle: cycle}}
    end
  end

  @spec dependency_projection(SymphonyIssue.t(), [SymphonyIssue.t()], [IssueDependency.t()], atom()) :: map()
  def dependency_projection(issue, issues, edges, template), do: dependency_projection(issue, issues, edges, template, [])

  @spec dependency_projection(SymphonyIssue.t(), [SymphonyIssue.t()], [IssueDependency.t()], atom(), keyword()) :: map()
  def dependency_projection(%SymphonyIssue{} = issue, issues, edges, template, opts)
      when is_list(issues) and is_list(edges) and is_list(opts) do
    summary = IssueDependencies.github_dependency_summary(issue, issues, edges)
    preview_opts = projection_opts(opts)

    %{
      summary: summary,
      linear: ProjectionTemplates.preview_surface(template, :linear, %{dependencies: summary}, preview_opts),
      github_issue: ProjectionTemplates.preview_surface(template, :github_issue, %{dependencies: summary}, preview_opts)
    }
  end

  defp split_held(issues, opts) do
    issues
    |> Enum.map(&{&1, hold_reasons(&1, opts)})
    |> Enum.split_with(fn {_issue, reasons} -> reasons != [] end)
    |> then(fn {held, eligible} ->
      {
        Enum.map(held, fn {issue, reasons} -> %{issue: issue, reasons: reasons} end),
        Enum.map(eligible, &elem(&1, 0))
      }
    end)
  end

  defp hold_reasons(%SymphonyIssue{} = issue, opts) do
    []
    |> maybe_add_checkpoint_hold(issue)
    |> maybe_add_loop_breaker_hold(issue, opts)
    |> add_configured_holds(issue, opts, :project_policy_holds)
    |> add_configured_holds(issue, opts, :relay_safety_holds)
    |> Enum.reverse()
  end

  defp maybe_add_checkpoint_hold(reasons, %SymphonyIssue{status: "human-checkpoint"}), do: [:human_checkpoint_required | reasons]

  defp maybe_add_checkpoint_hold(reasons, %SymphonyIssue{} = issue) do
    metadata = issue.metadata || %{}

    if truthy?(map_get(metadata, :human_checkpoint_required)) and map_get(metadata, :checkpoint_status) != "approved" do
      [:human_checkpoint_required | reasons]
    else
      reasons
    end
  end

  defp maybe_add_loop_breaker_hold(reasons, %SymphonyIssue{} = issue, opts) do
    loop_events = opts |> Keyword.get(:loop_events_by_issue, %{}) |> map_get(issue.id, [])

    case LoopBreaker.evaluate(loop_events, issue_identifier: issue.title) do
      {:break, _decision} -> [:loop_breaker_hold | reasons]
      {:continue, _summary} -> reasons
    end
  end

  defp add_configured_holds(reasons, %SymphonyIssue{} = issue, opts, hold_key) do
    opts
    |> Keyword.get(hold_key, %{})
    |> map_get(issue.id)
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(reasons)
  end

  defp select_dispatch(eligible, opts) do
    capacity = max(0, Keyword.get(opts, :max_concurrency, length(eligible)) - Keyword.get(opts, :running_count, 0))
    initial_counts = initial_counts(opts)

    eligible
    |> Enum.sort_by(&{&1.priority || 999, &1.id})
    |> Enum.reduce({[], [], capacity, initial_counts}, &select_issue/2)
    |> then(fn {dispatch, waiting, _capacity, _counts} ->
      {Enum.reverse(dispatch), Enum.reverse(waiting)}
    end)
  end

  defp select_issue(issue, {dispatch, waiting, capacity, counts}) do
    reasons = capacity_reasons(issue, capacity, counts)

    if reasons == [] do
      {[issue | dispatch], waiting, capacity - 1, increment_counts(counts, issue)}
    else
      {dispatch, [%{issue: issue, reasons: reasons} | waiting], capacity, counts}
    end
  end

  defp capacity_reasons(_issue, capacity, _counts) when capacity <= 0, do: [:global_concurrency_limit]

  defp capacity_reasons(%SymphonyIssue{} = issue, _capacity, counts) do
    []
    |> maybe_add_capacity_reason(:project_concurrency_limit, limit_reached?(counts.project, issue.project_id))
    |> maybe_add_capacity_reason(:repository_concurrency_limit, limit_reached?(counts.repository, issue.repository_id))
    |> Enum.reverse()
  end

  defp maybe_add_capacity_reason(reasons, _reason, false), do: reasons
  defp maybe_add_capacity_reason(reasons, reason, true), do: [reason | reasons]

  defp limit_reached?(_counter, nil), do: false

  defp limit_reached?(%{limits: limits, used: used}, key) do
    case map_get(limits, key) do
      nil -> false
      limit -> map_get(used, key, 0) >= limit
    end
  end

  defp increment_counts(counts, %SymphonyIssue{} = issue) do
    counts
    |> update_in([:project, :used], &increment_counter(&1, issue.project_id))
    |> update_in([:repository, :used], &increment_counter(&1, issue.repository_id))
  end

  defp increment_counter(counter, nil), do: counter
  defp increment_counter(counter, key), do: Map.update(counter, key, 1, &(&1 + 1))

  defp initial_counts(opts) do
    %{
      project: %{
        limits: Keyword.get(opts, :project_concurrency, %{}),
        used: Keyword.get(opts, :running_by_project, %{})
      },
      repository: %{
        limits: Keyword.get(opts, :repository_concurrency, %{}),
        used: Keyword.get(opts, :running_by_repository, %{})
      }
    }
  end

  defp dispatch_entry(%SymphonyIssue{} = issue, opts) do
    {session_action, session} =
      AgentSessions.ensure_builder_session(issue, Keyword.get(opts, :sessions, []), %{
        metadata: %{"scheduler_gate" => "ready"}
      })

    %{
      issue: issue,
      session_action: session_action,
      session: session,
      dispatch_policy: :ready
    }
  end

  defp capacity_summary(opts) do
    %{
      max_concurrency: Keyword.get(opts, :max_concurrency),
      running_count: Keyword.get(opts, :running_count, 0),
      project_concurrency: Keyword.get(opts, :project_concurrency, %{}),
      repository_concurrency: Keyword.get(opts, :repository_concurrency, %{})
    }
  end

  defp projection_opts(opts) do
    []
    |> maybe_put_opt(:mode, Keyword.get(opts, :mode))
    |> Keyword.put(:approvals, Keyword.get(opts, :approvals, []))
    |> Keyword.put(:capabilities, Keyword.get(opts, :capabilities, %{}))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp truthy?(value), do: value in [true, "true", 1, "1", true]

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
