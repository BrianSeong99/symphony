defmodule SymphonyElixir.Linear.Relay do
  @moduledoc """
  Deterministic Linear relay primitives for the human cockpit boundary.

  This module intentionally sits above the existing `SymphonyElixir.Linear.Client`
  and `SymphonyElixir.Linear.Adapter` transport. The existing adapter still owns
  GraphQL polling and tracker compatibility; the relay owns Brian's private
  Linear/Symphony/GitHub boundary decisions.
  """

  @capabilities [
    :read_issues,
    :read_projects,
    :read_teams,
    :write_comments,
    :update_status,
    :write_attachments
  ]

  @safe_write_actions %{
    update_status: %{mutation: "issueUpdate", capability: :update_status},
    blocker_summary: %{mutation: "commentCreate", capability: :write_comments},
    dependency_summary: %{mutation: "commentCreate", capability: :write_comments},
    checkpoint_request: %{mutation: "commentCreate", capability: :write_comments},
    run_summary: %{mutation: "commentCreate", capability: :write_comments},
    private_link_attachment: %{mutation: "attachmentCreate", capability: :write_attachments}
  }

  @projection_write_actions %{
    public_projection: %{mutation: "commentCreate", capability: :write_comments}
  }

  @type relay_context :: %{
          required(:team) => map() | nil,
          required(:project) => map() | nil,
          required(:issue) => map() | nil
        }

  @type webhook_event :: %{
          required(:source) => String.t(),
          required(:event_type) => String.t(),
          required(:action) => String.t() | nil,
          required(:entity_type) => String.t(),
          required(:entity_id) => String.t() | nil,
          required(:payload) => map()
        }

  @type write_result :: %{
          required(:status) => String.t(),
          required(:operation) => map(),
          required(:sync_event) => map(),
          optional(:response) => map(),
          optional(:reason) => term()
        }

  @spec normalize_read_models(map()) :: relay_context()
  def normalize_read_models(payload) when is_map(payload) do
    %{
      team: normalize_team(map_get(payload, :team)),
      project: normalize_project(map_get(payload, :project)),
      issue: normalize_issue(map_get(payload, :issue))
    }
  end

  @spec normalize_webhook(map()) :: webhook_event()
  def normalize_webhook(payload) when is_map(payload) do
    data = map_get(payload, :data, %{})
    entity_type = payload |> map_get(:type, "unknown") |> normalize_entity_type()
    action = map_get(payload, :action)

    %{
      source: "linear",
      event_type: event_type(entity_type, action),
      action: action,
      entity_type: entity_type,
      entity_id: map_get(data, :id),
      issue_id: nested_id(data, :issue),
      project_id: nested_id(data, :project),
      team_id: nested_id(data, :team),
      payload: payload
    }
  end

  @spec probe_capabilities((atom() -> :ok | {:error, term()})) :: map()
  def probe_capabilities(probe_fun) when is_function(probe_fun, 1) do
    results =
      Map.new(@capabilities, fn capability ->
        {capability, probe_fun.(capability) == :ok}
      end)

    %{
      capabilities: results,
      missing_capabilities: results |> Enum.reject(fn {_key, enabled?} -> enabled? end) |> Enum.map(&elem(&1, 0))
    }
  end

  @spec execute_write(atom(), map()) :: write_result()
  def execute_write(action, context), do: execute_write(action, context, [])

  @spec execute_write(atom(), map(), keyword()) :: write_result()
  def execute_write(action, context, opts) when is_atom(action) and is_map(context) and is_list(opts) do
    operation = write_operation(action, context)
    policy = Keyword.get(opts, :policy, &default_policy/1)
    performer = Keyword.get(opts, :performer, fn _operation -> {:ok, %{}} end)

    with {:ok, operation} <- operation,
         {:allow, _reason} <- policy.(operation),
         {:ok, response} <- performer.(operation) do
      success_result(operation, response)
    else
      {:error, {:unsupported_action, _action} = reason} ->
        skipped_result(%{action: to_string(action), request: context}, reason)

      {:block, reason} ->
        skipped_result(elem(operation, 1), reason)

      {:error, reason} ->
        error_result(elem(operation, 1), reason)
    end
  end

  defp normalize_team(nil), do: nil

  defp normalize_team(team) when is_map(team) do
    %{
      id: map_get(team, :id),
      key: map_get(team, :key),
      name: map_get(team, :name)
    }
  end

  defp normalize_project(nil), do: nil

  defp normalize_project(project) when is_map(project) do
    %{
      id: map_get(project, :id),
      name: map_get(project, :name),
      slug: map_get(project, :slugId) || map_get(project, :slug)
    }
  end

  defp normalize_issue(nil), do: nil

  defp normalize_issue(issue) when is_map(issue) do
    %{
      id: map_get(issue, :id),
      identifier: map_get(issue, :identifier),
      title: map_get(issue, :title),
      description: map_get(issue, :description),
      url: map_get(issue, :url),
      status: normalize_status(map_get(issue, :state)),
      team: normalize_team(map_get(issue, :team)),
      project: normalize_project(map_get(issue, :project)),
      labels: issue |> map_get(:labels, %{}) |> nodes() |> Enum.map(&normalize_label/1),
      comments: issue |> map_get(:comments, %{}) |> nodes() |> Enum.map(&normalize_comment/1),
      relations: issue |> map_get(:relations, %{}) |> nodes() |> Enum.map(&normalize_relation/1),
      attachments: issue |> map_get(:attachments, %{}) |> nodes() |> Enum.map(&normalize_attachment/1)
    }
  end

  defp normalize_status(nil), do: nil

  defp normalize_status(status) when is_map(status) do
    %{
      id: map_get(status, :id),
      name: map_get(status, :name)
    }
  end

  defp normalize_label(label) do
    %{id: map_get(label, :id), name: map_get(label, :name)}
  end

  defp normalize_comment(comment) do
    %{id: map_get(comment, :id), body: map_get(comment, :body), url: map_get(comment, :url)}
  end

  defp normalize_relation(relation) do
    issue = map_get(relation, :issue, %{})

    %{
      type: map_get(relation, :type),
      issue_id: map_get(issue, :id),
      issue_identifier: map_get(issue, :identifier)
    }
  end

  defp normalize_attachment(attachment) do
    %{id: map_get(attachment, :id), title: map_get(attachment, :title), url: map_get(attachment, :url)}
  end

  defp normalize_entity_type("Issue"), do: "issue"
  defp normalize_entity_type("Comment"), do: "comment"
  defp normalize_entity_type("Project"), do: "project"
  defp normalize_entity_type("WorkflowState"), do: "status"
  defp normalize_entity_type(type) when is_binary(type), do: type |> Macro.underscore() |> String.replace("_", "-")
  defp normalize_entity_type(_type), do: "unknown"

  defp event_type(entity_type, action) when is_binary(action), do: "#{entity_type}.#{action}"
  defp event_type(entity_type, _action), do: entity_type

  defp write_operation(action, context) do
    operation_spec = Map.get(@safe_write_actions, action) || Map.get(@projection_write_actions, action)

    case operation_spec do
      nil ->
        {:error, {:unsupported_action, action}}

      spec ->
        {:ok,
         %{
           provider: "linear",
           action: to_string(action),
           mutation: spec.mutation,
           required_capability: spec.capability,
           projection?: Map.has_key?(@projection_write_actions, action),
           request: context
         }}
    end
  end

  defp default_policy(operation) do
    if operation.projection? do
      {:block, :policy_required_for_projection}
    else
      {:allow, :safe_linear_write}
    end
  end

  defp success_result(operation, response) do
    %{
      status: "success",
      operation: operation,
      response: response,
      sync_event: sync_event(operation, "success", response, nil)
    }
  end

  defp skipped_result(operation, reason) do
    %{
      status: "skipped",
      operation: operation,
      reason: reason,
      sync_event: sync_event(operation, "skipped", %{}, inspect(reason))
    }
  end

  defp error_result(operation, reason) do
    %{
      status: "error",
      operation: operation,
      reason: reason,
      sync_event: sync_event(operation, "error", %{}, inspect(reason))
    }
  end

  defp sync_event(operation, status, response, error) do
    %{
      provider: "linear",
      action: operation.action,
      status: status,
      request: Map.get(operation, :request, %{}),
      response: response,
      error: error
    }
  end

  defp nodes(%{"nodes" => nodes}) when is_list(nodes), do: nodes
  defp nodes(%{nodes: nodes}) when is_list(nodes), do: nodes
  defp nodes(_value), do: []

  defp nested_id(map, key) do
    case map_get(map, key) do
      nested when is_map(nested) -> map_get(nested, :id)
      _ -> nil
    end
  end

  defp map_get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
