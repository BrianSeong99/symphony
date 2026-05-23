defmodule SymphonyElixir.Homelab.FullSync do
  @moduledoc """
  Homelab native Linear/GitHub full-sync handoff contract.

  Homelab is Brian's owned validation project, so it can use native GitHub issue
  sync while Symphony still owns private runtime memory, validation state,
  dependency DAGs, and audit trails.
  """

  alias SymphonyElixir.GitHubSync
  alias SymphonyElixir.Linear.{OperatingModel, Relay}
  alias SymphonyElixir.ProjectionTemplates
  alias SymphonyElixir.Projects.{Project, ProjectConnection}

  @operating_model_path Path.expand("../../../../config/symphony/linear-operating-model.yml", __DIR__)
  @project_key "homelab-runtime"
  @full_sync_capabilities %{
    "create_issues" => true,
    "edit_issues" => true,
    "create_labels" => true,
    "edit_milestones" => true,
    "comment" => true,
    "create_prs" => true,
    "read_prs" => true,
    "read_checks" => true,
    "read_reviews" => true
  }
  @canonical_symphony_fields ~w(agent_memory validation dependencies audit_events)

  @type config :: %{
          required(:project_key) => String.t(),
          required(:project_name) => String.t(),
          required(:operating_domain) => String.t(),
          required(:linear_team_key) => String.t(),
          required(:linear_project_key) => String.t(),
          required(:sync_profile) => String.t(),
          required(:github_repository) => String.t(),
          required(:github_owner) => String.t(),
          required(:github_repo) => String.t(),
          required(:full_sync_allowed) => boolean(),
          required(:checkpoint_cadence) => String.t() | nil
        }

  @type handoff_plan :: %{
          required(:source_of_truth) => String.t(),
          required(:project) => config(),
          required(:associations) => [map()],
          required(:github) => map(),
          required(:linear) => map(),
          required(:symphony) => map(),
          required(:projection) => map()
        }

  @spec config!() :: config()
  def config!, do: config!([])

  @spec config!(keyword()) :: config()
  def config!(opts) when is_list(opts) do
    model = Keyword.get_lazy(opts, :operating_model, &load_operating_model!/0)
    project = OperatingModel.outcome_project!(model, @project_key)
    domain = get_in(model, ["operating_domains", Map.fetch!(project, "operating_domain")])
    repo = project |> get_in(["repo_metadata", "custom_fields", "github_repository"]) |> split_repo!()

    %{
      project_key: @project_key,
      project_name: Map.fetch!(project, "name"),
      operating_domain: Map.fetch!(project, "operating_domain"),
      linear_team_key: Map.fetch!(domain, "linear_team_key"),
      linear_project_key: Map.fetch!(project, "linear_project_key"),
      sync_profile: Map.fetch!(project, "sync_profile"),
      github_repository: Enum.join(repo, "/"),
      github_owner: Enum.at(repo, 0),
      github_repo: Enum.at(repo, 1),
      full_sync_allowed: get_in(project, ["repo_metadata", "full_sync_allowed"]) == true,
      checkpoint_cadence: OperatingModel.checkpoint_cadence(model, @project_key)
    }
  end

  @spec connection!(config()) :: ProjectConnection.t()
  def connection!(config) when is_map(config) do
    true = Map.fetch!(config, :full_sync_allowed)

    %ProjectConnection{
      provider: "github",
      connection_mode: "full_sync",
      owner: Map.fetch!(config, :github_owner),
      repo: Map.fetch!(config, :github_repo),
      status: "active",
      capabilities: @full_sync_capabilities,
      settings: %{linear_native_sync: true, source_of_truth: "symphony"}
    }
  end

  @spec project!(config()) :: Project.t()
  def project!(config) when is_map(config) do
    %Project{
      name: Map.fetch!(config, :project_name),
      slug: Map.fetch!(config, :project_key),
      workspace: "labs",
      status: "active",
      risk_policy: "medium",
      settings: %{
        operating_domain: Map.fetch!(config, :operating_domain),
        linear_team_key: Map.fetch!(config, :linear_team_key),
        linear_project_key: Map.fetch!(config, :linear_project_key)
      }
    }
  end

  @spec plan_handoff(map()) :: handoff_plan()
  def plan_handoff(attrs), do: plan_handoff(attrs, [])

  @spec plan_handoff(map(), keyword()) :: handoff_plan()
  def plan_handoff(attrs, opts) when is_map(attrs) and is_list(opts) do
    config = config!(opts)
    project = project!(config)
    connection = connection!(config)
    performer = Keyword.get(opts, :performer, fn _operation -> {:ok, %{}} end)
    projection = projection(attrs)

    github =
      connection
      |> GitHubSync.execute(github_context(attrs, config), project: project, performer: performer)
      |> github_summary()

    linear = linear_summary(attrs)

    %{
      source_of_truth: "symphony",
      project: config,
      associations: associations(attrs, config),
      github: github,
      linear: linear,
      symphony: symphony_truth(attrs),
      projection: projection_summary(projection)
    }
  end

  @spec full_sync_allowed?(keyword()) :: boolean()
  def full_sync_allowed?(opts \\ []), do: config!(opts).full_sync_allowed

  defp load_operating_model! do
    case OperatingModel.load_file(@operating_model_path) do
      {:ok, model} -> model
      {:error, errors} -> raise ArgumentError, "invalid Linear operating model: #{Enum.join(errors, "; ")}"
    end
  end

  defp projection(attrs) do
    ProjectionTemplates.preview(:homelab, projection_values(attrs),
      mode: :native,
      approvals: [:public_comments],
      capabilities: %{comment: true}
    )
  end

  defp projection_values(attrs) do
    %{
      title: map_get(attrs, :title),
      dependencies: map_get(attrs, :dependencies, []),
      validation: map_get(attrs, :validation_summary),
      pr_state: map_get(attrs, :pr_state),
      checks: map_get(attrs, :checks),
      public_comments: map_get(attrs, :public_comments),
      private_comments: map_get(attrs, :private_comments),
      run_metrics: map_get(attrs, :run_metrics),
      workpad: map_get(attrs, :workpad),
      agent_memory: map_get(attrs, :agent_memory)
    }
  end

  defp github_context(attrs, config) do
    %{
      project_id: map_get(attrs, :project_id),
      symphony_issue_id: map_get(attrs, :symphony_issue_id),
      title: map_get(attrs, :title),
      body: map_get(attrs, :github_issue_body),
      dependency_summary: map_get(attrs, :dependency_summary),
      labels: ["homelab", "native-full-sync" | map_get(attrs, :labels, [])],
      milestone_title: map_get(attrs, :milestone_title),
      github_issue_url: map_get(attrs, :github_issue_url),
      github_pr_url: map_get(attrs, :github_pr_url),
      github_pr_number: map_get(attrs, :github_pr_number),
      review_state: map_get(attrs, :review_state, "pending"),
      review_body: map_get(attrs, :review_body),
      workpad_body: map_get(attrs, :workpad_public_summary),
      explicit_pr_association: true,
      explicit_public_comment: true,
      project: Map.fetch!(config, :project_key)
    }
  end

  defp github_summary(result) do
    %{
      mode: result.plan.mode,
      associations: result.plan.associations,
      performed: Enum.map(result.performed, & &1.action),
      skipped: Enum.map(result.capability_issues, & &1.action),
      sync_events: result.sync_events
    }
  end

  defp linear_summary(attrs) do
    dependency =
      Relay.execute_write(:dependency_summary, %{
        linear_issue_id: map_get(attrs, :linear_issue_id),
        body: map_get(attrs, :dependency_summary)
      })

    run =
      Relay.execute_write(:run_summary, %{
        linear_issue_id: map_get(attrs, :linear_issue_id),
        body: map_get(attrs, :run_summary)
      })

    %{
      mirrored: Enum.map([dependency, run], & &1.operation.action),
      sync_events: Enum.map([dependency, run], & &1.sync_event)
    }
  end

  defp associations(attrs, config) do
    [
      association("linear_project", Map.fetch!(config, :linear_project_key), nil, "canonical"),
      association("linear_issue", map_get(attrs, :linear_issue_id), map_get(attrs, :linear_issue_url), "canonical"),
      association("symphony_issue", map_get(attrs, :symphony_issue_id), nil, "canonical"),
      association("github_repo", Map.fetch!(config, :github_repository), "https://github.com/#{config.github_repository}", "native"),
      association("github_issue", map_get(attrs, :github_issue_id), map_get(attrs, :github_issue_url), "native"),
      association("github_pr", map_get(attrs, :github_pr_number), map_get(attrs, :github_pr_url), "native")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp association(_type, nil, _url, _strength), do: nil
  defp association(_type, "", _url, _strength), do: nil

  defp association(type, external_id, url, strength) do
    %{
      link_type: type,
      association_strength: strength,
      external_id: to_string(external_id),
      url: url,
      metadata: %{}
    }
  end

  defp symphony_truth(attrs) do
    %{
      canonical_fields: @canonical_symphony_fields,
      private_state: %{
        agent_memory: map_get(attrs, :agent_memory),
        validation: map_get(attrs, :validation_summary),
        dependencies: map_get(attrs, :dependencies, []),
        audit_events: map_get(attrs, :audit_events, [])
      }
    }
  end

  defp projection_summary(projection) do
    %{
      sync_strategy: projection.sync_strategy,
      github_issue_allowed: projection.surfaces.github_issue.allowed |> Map.keys() |> Enum.map(&Atom.to_string/1),
      linear_allowed: projection.surfaces.linear.allowed |> Map.keys() |> Enum.map(&Atom.to_string/1),
      symphony_allowed: projection.surfaces.symphony.allowed |> Map.keys() |> Enum.map(&Atom.to_string/1)
    }
  end

  defp split_repo!(repo) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" -> [owner, name]
      _other -> raise ArgumentError, "invalid Homelab GitHub repository #{inspect(repo)}"
    end
  end

  defp split_repo!(repo), do: raise(ArgumentError, "invalid Homelab GitHub repository #{inspect(repo)}")

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
