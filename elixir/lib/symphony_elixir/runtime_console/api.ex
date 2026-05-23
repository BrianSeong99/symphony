defmodule SymphonyElixir.RuntimeConsole.Api do
  @moduledoc """
  Private runtime-console API payloads.

  The API treats local Symphony configuration and runtime state as canonical.
  Linear and GitHub appear as downstream associations, webhooks, projections, or
  relay events, never as required sources of truth.
  """

  alias SymphonyElixir.FieldPolicy
  alias SymphonyElixir.Linear.{OperatingModel, Relay}
  alias SymphonyElixir.ProjectionTemplates

  @operating_model_path Path.expand("../../../../config/symphony/linear-operating-model.yml", __DIR__)
  @runtime_resources [:issues, :milestones, :dependencies, :checkpoints, :runs, :agents, :reviews, :relay_events]

  @type payload :: map()

  @spec resource(atom(), keyword()) :: payload()
  def resource(:health, opts), do: health(opts)
  def resource(:projects, opts), do: projects(opts)
  def resource(:policies, opts), do: policies(opts)

  def resource(resource, opts) when resource in @runtime_resources do
    runtime_collection_payload(resource, opts)
  end

  @spec health(keyword()) :: payload()
  def health(opts \\ []) do
    %{
      status: "ok",
      service: "symphony",
      source_of_truth: "symphony",
      generated_at: generated_at(),
      counts: resource_counts(runtime_state(opts))
    }
  end

  @spec projects(keyword()) :: payload()
  def projects(opts \\ []) do
    model = Keyword.get_lazy(opts, :operating_model, &load_operating_model!/0)

    projects =
      model
      |> OperatingModel.outcome_project_keys()
      |> Enum.map(&project_payload(model, &1))

    %{
      source_of_truth: "symphony",
      generated_at: generated_at(),
      count: length(projects),
      projects: projects
    }
  end

  @spec policies(keyword()) :: payload()
  def policies(opts \\ []) do
    field_policy = Keyword.get_lazy(opts, :field_policy, &FieldPolicy.load!/0)
    projection_templates = Keyword.get_lazy(opts, :projection_templates, &ProjectionTemplates.load!/0)

    %{
      source_of_truth: "symphony",
      generated_at: generated_at(),
      field_profiles: field_policy |> Map.fetch!(:profiles) |> Map.keys(),
      fields: field_policy |> Map.fetch!(:fields) |> Map.keys(),
      projection_templates: projection_templates |> Map.fetch!(:templates) |> Map.keys()
    }
  end

  @spec projection_preview(map(), keyword()) :: payload()
  def projection_preview(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    template = payload |> map_get(:template, :symphony) |> normalize_key()
    surface = payload |> map_get(:surface, :linear) |> normalize_key()
    values = payload |> map_get(:values, %{}) |> normalize_value_map()

    preview =
      ProjectionTemplates.preview_surface(
        template,
        surface,
        values,
        projection_preview_opts(payload)
      )

    %{
      source_of_truth: "symphony",
      mutation_performed: false,
      template: template,
      surface: surface,
      preview: preview,
      audit_event: audit_event("projection.preview", payload, opts)
    }
  end

  @spec linear_webhook(map(), keyword()) :: payload()
  def linear_webhook(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    event = Relay.normalize_webhook(payload)

    %{
      source_of_truth: "symphony",
      mutation_performed: false,
      provider: "linear",
      event: event,
      audit_event: audit_event("linear.webhook_received", event, opts)
    }
  end

  defp runtime_collection_payload(resource, opts) do
    collection = opts |> runtime_state() |> map_get(resource, [])

    %{
      source_of_truth: "symphony",
      generated_at: generated_at(),
      resource: resource,
      count: length(List.wrap(collection)),
      items: List.wrap(collection)
    }
  end

  defp project_payload(model, project_key) do
    project = OperatingModel.outcome_project!(model, project_key)

    %{
      key: project_key,
      name: Map.fetch!(project, "name"),
      operating_domain: Map.fetch!(project, "operating_domain"),
      homelab_workspace_id: Map.get(project, "homelab_workspace_id"),
      homelab_project_id: Map.get(project, "homelab_project_id"),
      homelab_path: Map.get(project, "homelab_path"),
      linear_project_key: Map.fetch!(project, "linear_project_key"),
      linear_project_url: Map.get(project, "linear_project_url"),
      sync_profile: Map.fetch!(project, "sync_profile"),
      github_issues_sync: Map.get(project, "github_issues_sync", "disabled"),
      repo_metadata: Map.get(project, "repo_metadata", %{}),
      checkpoint_cadence: OperatingModel.checkpoint_cadence(model, project_key),
      policy_overrides: Map.get(project, "policy_overrides", %{})
    }
  end

  defp resource_counts(state) do
    Map.new(@runtime_resources, fn resource ->
      {resource, state |> map_get(resource, []) |> List.wrap() |> length()}
    end)
  end

  defp audit_event(action, payload, opts) do
    %{
      project_id: Keyword.get(opts, :project_id),
      symphony_issue_id: Keyword.get(opts, :symphony_issue_id),
      actor: "symphony-runtime-api",
      action: action,
      target_type: "runtime_console",
      target_id: "local",
      payload: %{request: payload}
    }
  end

  defp projection_preview_opts(payload) do
    []
    |> maybe_put_opt(:mode, map_get(payload, :mode))
    |> Keyword.put(:approvals, map_get(payload, :approvals, []))
    |> Keyword.put(:capabilities, map_get(payload, :capabilities, %{}))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp runtime_state(opts), do: Keyword.get(opts, :runtime_state, %{})

  defp load_operating_model! do
    case OperatingModel.load_file(@operating_model_path) do
      {:ok, model} -> model
      {:error, errors} -> raise ArgumentError, "invalid Linear operating model: #{Enum.join(errors, "; ")}"
    end
  end

  defp generated_at do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp normalize_value_map(values) when is_map(values) do
    Map.new(values, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_value_map(_values), do: %{}

  defp normalize_key(nil), do: nil
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
