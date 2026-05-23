defmodule SymphonyElixir.Simulation.Engine do
  @moduledoc """
  Deterministic simulations for Linear/Symphony/GitHub orchestration.

  The simulator is a pure composition layer over the production planners. It
  loads fixture scenarios, runs the same intake/projection/sync/scheduler/review
  contracts Symphony uses at runtime, and returns stable summaries for golden
  tests and safety review.
  """

  alias SymphonyElixir.{
    ConflictResolver,
    GitHubSync,
    ProjectionTemplates
  }

  alias SymphonyElixir.Issues.{IssueDependency, SymphonyIssue}
  alias SymphonyElixir.Linear.Intake
  alias SymphonyElixir.Projects.{Project, ProjectConnection}
  alias SymphonyElixir.Reviews.ReviewLoop
  alias SymphonyElixir.Scheduler.Gates

  @config_path Path.expand("../../../../config/symphony/simulation-scenarios.yml", __DIR__)
  @private_fields [:planning_notes, :workpad, :agent_memory, :private_comments, :run_metrics]
  @github_surfaces [:github_issue, :github_pr, :github_comment]

  @empty_linear %{
    intake_status: "empty",
    accepted: [],
    rejected: [],
    allowed_private_fields: []
  }

  @empty_github %{
    sync_mode: "none",
    performed: [],
    skipped: [],
    private_leak_fields: [],
    projection: %{
      github_issue_allowed: [],
      github_issue_rejected: [],
      github_issue_redacted: [],
      metadata: %{}
    }
  }

  @empty_scheduler %{
    dispatch: [],
    blocked: [],
    held: [],
    waiting: [],
    blocked_by: %{}
  }

  @empty_review %{status: "not_run", validation: "not_run"}
  @empty_conflict %{status: "ok", conflicts: [], checkpoint_required: false}
  @empty_symphony %{allowed_private_fields: []}

  @spec load!() :: map()
  def load! do
    @config_path
    |> YamlElixir.read_from_file!()
    |> validate!()
  end

  @spec run_all() :: map()
  def run_all, do: run_all([])

  @spec run_all(keyword()) :: map()
  def run_all(opts) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &load!/0)

    scenarios =
      config
      |> map_get("scenario_order", [])
      |> Enum.map(&run!(&1, Keyword.put(opts, :config, config)))

    %{version: map_get(config, "version"), scenarios: scenarios}
  end

  @spec run!(atom() | String.t()) :: map()
  def run!(scenario_key), do: run!(scenario_key, [])

  @spec run!(atom() | String.t(), keyword()) :: map()
  def run!(scenario_key, opts) when is_list(opts) do
    case run(scenario_key, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "invalid simulation scenario #{inspect(scenario_key)}: #{inspect(reason)}"
    end
  end

  @spec run(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def run(scenario_key), do: run(scenario_key, [])

  @spec run(atom() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(scenario_key, opts) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &load!/0)
    scenario_name = scenario_name(scenario_key)

    case get_in(config, ["scenarios", scenario_name]) do
      nil -> {:error, :unknown_scenario}
      scenario -> {:ok, run_scenario(scenario_name, scenario)}
    end
  end

  @spec golden(map()) :: map()
  def golden(result) when is_map(result) do
    result
    |> Map.drop([:scenario])
    |> stringify_for_snapshot()
  end

  defp run_scenario(scenario_name, %{"kind" => "loop_breaker"} = scenario) do
    loop_breaker_result(scenario_name, scenario)
  end

  defp run_scenario(scenario_name, %{"kind" => "scheduler"} = scenario) do
    scheduler = scheduler_summary(scenario)

    scenario_name
    |> base_result(scenario)
    |> Map.put(:scheduler, scheduler)
    |> finalize_status()
  end

  defp run_scenario(scenario_name, scenario) do
    projection = projection_preview(scenario)
    conflict = conflict_summary(scenario)
    review = review_summary(scenario)

    scenario_name
    |> base_result(scenario)
    |> Map.put(:linear, linear_summary(scenario, projection))
    |> Map.put(:github, github_summary(scenario, projection))
    |> Map.put(:symphony, symphony_summary(projection))
    |> Map.put(:scheduler, scheduler_summary(scenario))
    |> Map.put(:review, review)
    |> Map.put(:conflict, conflict)
    |> Map.put(:checkpoints, checkpoints_from(review, conflict))
    |> finalize_status()
  end

  defp base_result(scenario_name, scenario) do
    %{
      scenario: String.to_atom(scenario_name),
      workspace: map_get(scenario, "workspace"),
      status: "passed",
      linear: @empty_linear,
      github: @empty_github,
      symphony: @empty_symphony,
      scheduler: @empty_scheduler,
      review: @empty_review,
      conflict: @empty_conflict,
      checkpoints: []
    }
  end

  defp projection_preview(scenario) do
    case map_get(scenario, "template") do
      nil ->
        nil

      template ->
        projection_config = map_get(scenario, "projection", %{})

        ProjectionTemplates.preview(
          normalize_key(template),
          map_get(scenario, "values", %{}),
          mode: normalize_key(map_get(scenario, "mode")),
          approvals: atom_list(map_get(projection_config, "approvals", [])),
          capabilities: string_keyed_map(map_get(projection_config, "capabilities", %{}))
        )
    end
  end

  defp linear_summary(scenario, projection) do
    intake =
      case map_get(scenario, "linear_intake") do
        nil ->
          nil

        payload ->
          accept_config = map_get(scenario, "linear_accept", %{})

          Intake.normalize(payload,
            approved_kinds: atom_list(map_get(accept_config, "approved_kinds", [])),
            approved_fields: atom_list(map_get(accept_config, "approved_fields", []))
          )
      end

    @empty_linear
    |> Map.merge(intake_summary(intake))
    |> Map.put(:allowed_private_fields, allowed_private_fields(projection, :linear))
  end

  defp intake_summary(nil), do: %{}

  defp intake_summary(intake) do
    %{
      intake_status: to_string(intake.status),
      accepted: suggestion_keys(intake.accepted),
      rejected: suggestion_keys(intake.rejected)
    }
  end

  defp github_summary(scenario, projection) do
    github = map_get(scenario, "github")
    projection_summary = projection_summary(projection)

    if github do
      connection = connection_struct(github)
      context = github_context(scenario, github)
      project = project_struct(scenario)
      result = GitHubSync.execute(connection, context, project: project)

      %{
        sync_mode: map_get(github, "connection_mode"),
        performed: Enum.map(result.performed, & &1.action),
        skipped: Enum.map(result.capability_issues, & &1.action),
        private_leak_fields: github_private_leak_fields(projection),
        projection: projection_summary
      }
    else
      @empty_github
      |> Map.put(:private_leak_fields, github_private_leak_fields(projection))
      |> Map.put(:projection, projection_summary)
    end
  end

  defp symphony_summary(projection) do
    %{allowed_private_fields: allowed_private_fields(projection, :symphony)}
  end

  defp projection_summary(nil), do: @empty_github.projection

  defp projection_summary(projection) do
    github_issue = surface(projection, :github_issue)

    %{
      github_issue_allowed: field_keys(github_issue.allowed),
      github_issue_rejected: field_keys(github_issue.rejected),
      github_issue_redacted: field_keys(github_issue.redacted),
      metadata: stringify_for_snapshot(github_issue.metadata)
    }
  end

  defp scheduler_summary(scenario) do
    case map_get(scenario, "scheduler") do
      nil ->
        @empty_scheduler

      scheduler ->
        issues = scheduler |> map_get("issues", []) |> Enum.map(&issue_struct/1)
        edges = scheduler |> map_get("edges", []) |> Enum.map(&edge_struct/1)

        {:ok, plan} =
          Gates.plan(issues, edges, max_concurrency: map_get(scheduler, "max_concurrency", length(issues)))

        %{
          dispatch: Enum.map(plan.dispatch, & &1.issue.id),
          blocked: Enum.map(plan.blocked, & &1.issue.id),
          held: Enum.map(plan.held, & &1.issue.id),
          waiting: Enum.map(plan.waiting, & &1.issue.id),
          blocked_by: blocked_by_summary(plan.blocked)
        }
    end
  end

  defp review_summary(scenario) do
    case map_get(scenario, "review") do
      nil ->
        @empty_review

      review ->
        issue = map_get(review, "issue", %{})
        validation = map_get(review, "validation", %{"status" => "passed"})

        result =
          ReviewLoop.run_cycle(
            %{
              id: map_get(issue, "id"),
              title: map_get(issue, "title")
            },
            review |> map_get("feedback", []) |> Enum.map(&normalize_review_event/1),
            [],
            builder_runner: fn repair_issue, _sessions ->
              {:ok, %{commit: "simulation", repair_items: get_in(repair_issue, [:metadata, "repair_items"]) || []}}
            end,
            validation_runner: fn _repair_issue, _builder_result ->
              {:ok, validation}
            end
          )

        %{status: result.status, validation: validation_status(result.validation)}
    end
  end

  defp conflict_summary(scenario) do
    case map_get(scenario, "conflict") do
      nil ->
        @empty_conflict

      snapshot ->
        projection_config = map_get(scenario, "projection", %{})

        result =
          ConflictResolver.resolve(snapshot,
            template: normalize_key(map_get(scenario, "template", "symphony")),
            mode: normalize_key(map_get(scenario, "mode")),
            approvals: atom_list(map_get(projection_config, "approvals", [])),
            capabilities: string_keyed_map(map_get(projection_config, "capabilities", %{}))
          )

        %{
          status: to_string(result.status),
          conflicts: result.conflicts |> Enum.map(&(&1.type |> to_string())) |> Enum.sort(),
          checkpoint_required: not is_nil(result.checkpoint)
        }
    end
  end

  defp loop_breaker_result(scenario_name, scenario) do
    variants =
      scenario
      |> map_get("loop_breaker", %{})
      |> Enum.sort_by(fn {variant, _config} -> variant end)
      |> Enum.map(fn {variant, config} -> {variant, run_loop_breaker_variant(config)} end)

    checkpoints =
      variants
      |> Enum.map(fn {_variant, result} -> checkpoint_from_loop_result(result) end)
      |> Enum.reject(&is_nil/1)

    triggers = Enum.map(checkpoints, & &1.trigger)

    scenario_name
    |> base_result(scenario)
    |> Map.put(:review, %{
      status: "human-checkpoint",
      validation: "failed",
      loop_breaker_triggers: triggers
    })
    |> Map.put(:checkpoints, checkpoints)
    |> finalize_status()
  end

  defp run_loop_breaker_variant(config) do
    issue = map_get(config, "issue", %{})
    events = config |> map_get("events", []) |> Enum.map(&normalize_review_event/1)
    validation = map_get(config, "validation", %{"status" => "failed"})

    ReviewLoop.run_cycle(
      %{
        id: map_get(issue, "id"),
        title: map_get(issue, "title")
      },
      config |> map_get("feedback", []) |> Enum.map(&normalize_review_event/1),
      [],
      loop_events: events,
      builder_runner: fn _repair_issue, _sessions -> {:ok, %{commit: "simulation"}} end,
      validation_runner: fn _repair_issue, _builder_result -> {:ok, validation} end
    )
  end

  defp checkpoint_from_loop_result(%{status: "human-checkpoint", loop_breaker: loop_breaker}) do
    %{
      source: "review_loop",
      status: "human-checkpoint",
      trigger: to_string(loop_breaker.trigger),
      evidence_count: length(loop_breaker.evidence)
    }
  end

  defp checkpoint_from_loop_result(_result), do: nil

  defp checkpoints_from(review, conflict) do
    []
    |> maybe_add_review_checkpoint(review)
    |> maybe_add_conflict_checkpoint(conflict)
    |> Enum.reverse()
  end

  defp maybe_add_review_checkpoint(checkpoints, %{status: "human-checkpoint", loop_breaker_triggers: triggers}) do
    trigger = triggers |> List.wrap() |> List.first()

    [
      %{
        source: "review_loop",
        status: "human-checkpoint",
        trigger: trigger || "unknown",
        evidence_count: 0
      }
      | checkpoints
    ]
  end

  defp maybe_add_review_checkpoint(checkpoints, _review), do: checkpoints

  defp maybe_add_conflict_checkpoint(checkpoints, %{checkpoint_required: true, conflicts: conflicts}) do
    [
      %{
        source: "conflict_resolver",
        status: "human-checkpoint",
        trigger: "unresolved_sync_conflicts",
        evidence_count: length(conflicts)
      }
      | checkpoints
    ]
  end

  defp maybe_add_conflict_checkpoint(checkpoints, _conflict), do: checkpoints

  defp finalize_status(result) do
    if result.checkpoints == [] do
      result
    else
      %{result | status: "checkpoint_required"}
    end
  end

  defp suggestion_keys(suggestions) do
    suggestions
    |> Enum.map(fn suggestion -> "#{suggestion.kind}:#{suggestion.field}" end)
    |> Enum.sort()
  end

  defp allowed_private_fields(nil, _surface), do: []

  defp allowed_private_fields(projection, surface_key) do
    projection
    |> surface(surface_key)
    |> Map.get(:allowed, %{})
    |> Map.keys()
    |> Enum.filter(&(&1 in @private_fields))
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp github_private_leak_fields(nil), do: []

  defp github_private_leak_fields(projection) do
    projection.surfaces
    |> Enum.filter(fn {surface_key, surface} ->
      surface_key in @github_surfaces and surface.status == :ready and surface.target == :github
    end)
    |> Enum.flat_map(fn {_surface_key, surface} -> Map.keys(surface.allowed) end)
    |> Enum.filter(&(&1 in @private_fields))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp surface(projection, surface_key) do
    get_in(projection, [:surfaces, surface_key]) ||
      %{
        allowed: %{},
        rejected: %{},
        redacted: %{},
        metadata: %{},
        status: :disabled,
        target: nil
      }
  end

  defp field_keys(map) do
    map
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp project_struct(scenario) do
    project = map_get(scenario, "project", %{})

    %Project{
      name: map_get(project, "name"),
      slug: map_get(project, "slug"),
      workspace: map_get(project, "workspace"),
      status: "active",
      risk_policy: "medium"
    }
  end

  defp connection_struct(github) do
    %ProjectConnection{
      provider: "github",
      connection_mode: map_get(github, "connection_mode"),
      owner: map_get(github, "owner"),
      repo: map_get(github, "repo"),
      status: "active",
      capabilities: string_keyed_map(map_get(github, "capabilities", %{}))
    }
  end

  defp github_context(scenario, github) do
    github
    |> map_get("context", %{})
    |> Map.put_new("project", project_struct(scenario))
  end

  defp issue_struct(attrs) do
    %SymphonyIssue{
      id: map_get(attrs, "id"),
      project_id: map_get(attrs, "project_id", 1),
      repository_id: map_get(attrs, "repository_id"),
      title: map_get(attrs, "title"),
      status: map_get(attrs, "status"),
      priority: map_get(attrs, "priority"),
      risk_level: map_get(attrs, "risk_level", "medium"),
      metadata: map_get(attrs, "metadata", %{})
    }
  end

  defp edge_struct(attrs) do
    %IssueDependency{
      dependent_issue_id: map_get(attrs, "dependent_issue_id"),
      dependency_issue_id: map_get(attrs, "dependency_issue_id"),
      dependency_policy: map_get(attrs, "dependency_policy", "all_done"),
      unblock_condition: map_get(attrs, "unblock_condition")
    }
  end

  defp blocked_by_summary(blocked_entries) do
    Map.new(blocked_entries, fn entry ->
      {to_string(entry.issue.id), entry.blocked_by}
    end)
  end

  defp validation_status(nil), do: "not_run"
  defp validation_status(validation), do: validation |> map_get("status", "not_run") |> to_string()

  defp normalize_review_event(event) when is_map(event) do
    event
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> atomize_known_event_values([:type, :kind])
  end

  defp atomize_known_event_values(event, keys) do
    Enum.reduce(keys, event, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, value} when is_binary(value) -> Map.put(acc, key, normalize_key(value))
        _other -> acc
      end
    end)
  end

  defp validate!(%{"version" => _version, "scenario_order" => order, "scenarios" => scenarios} = config)
       when is_list(order) and is_map(scenarios) do
    missing = Enum.reject(order, &Map.has_key?(scenarios, &1))

    if missing == [] do
      config
    else
      raise ArgumentError, "simulation scenarios missing definitions: #{Enum.join(missing, ", ")}"
    end
  end

  defp validate!(_config), do: raise(ArgumentError, "simulation config requires version, scenario_order, and scenarios")

  defp scenario_name(key) when is_atom(key), do: Atom.to_string(key)
  defp scenario_name(key) when is_binary(key), do: key

  defp atom_list(values) do
    values
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_key/1)
  end

  defp string_keyed_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_for_snapshot(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, nested} -> {to_string(key), stringify_for_snapshot(nested)} end)
  end

  defp stringify_for_snapshot(value) when is_list(value), do: Enum.map(value, &stringify_for_snapshot/1)
  defp stringify_for_snapshot(value) when is_boolean(value), do: value
  defp stringify_for_snapshot(value) when is_atom(value), do: to_string(value)
  defp stringify_for_snapshot(value), do: value

  defp normalize_key(nil), do: nil
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, default)
  end

  defp map_get(_map, _key, default), do: default
end
