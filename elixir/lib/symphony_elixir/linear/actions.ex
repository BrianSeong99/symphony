defmodule SymphonyElixir.Linear.Actions do
  @moduledoc """
  Local Linear custom action contracts for Symphony runtime and approval flows.

  This module validates and authenticates action payloads, maps safe runtime
  commands to a caller-provided runner, gates approvals through projection
  policy, and returns Linear-safe summaries plus audit events.
  """

  alias SymphonyElixir.ProjectionTemplates

  @runtime_actions [:start_run, :pause_run, :resume_run]
  @approval_actions [
    :approve_public_comment,
    :approve_spec_amendment,
    :approve_merge_handoff,
    :request_simulation
  ]
  @supported_actions @runtime_actions ++ @approval_actions

  @type action_result :: {:ok, map()} | {:error, map()}

  @spec handle(map()) :: action_result()
  def handle(payload), do: handle(payload, [])

  @spec handle(map(), keyword()) :: action_result()
  def handle(payload, opts) when is_map(payload) and is_list(opts) do
    with :ok <- authenticate(payload, opts),
         {:ok, action} <- parse_action(payload),
         {:ok, context} <- validate_context(action, payload),
         {:ok, result} <- execute_action(action, context, opts) do
      {:ok, accepted_result(action, context, result)}
    else
      {:error, reason, http_status} ->
        {:error, rejected_result(payload, reason, http_status)}

      {:error, reason, http_status, details} ->
        {:error, payload |> rejected_result(reason, http_status) |> Map.merge(details)}
    end
  end

  defp authenticate(payload, opts) do
    expected_token = Keyword.get(opts, :token)
    provided_token = provided_token(payload, Keyword.get(opts, :headers, []))

    cond do
      not present?(expected_token) ->
        {:error, :missing_local_action_token, 401}

      provided_token == expected_token ->
        :ok

      true ->
        {:error, :invalid_action_token, 401}
    end
  end

  defp parse_action(payload) do
    action = payload |> map_get(:action) |> normalize_key()

    if action in @supported_actions do
      {:ok, action}
    else
      {:error, :unsupported_action, 400}
    end
  end

  defp validate_context(action, payload) when action in @runtime_actions do
    required_context(payload, [:issue_id])
  end

  defp validate_context(:approve_public_comment, payload) do
    required_context(payload, [:issue_id, :project_id, :value])
  end

  defp validate_context(:approve_spec_amendment, payload) do
    required_context(payload, [:issue_id, :project_id, :amendment])
  end

  defp validate_context(:approve_merge_handoff, payload) do
    with {:ok, context} <- required_context(payload, [:issue_id, :project_id]) do
      if present?(map_get(payload, :github_pr_url)) or present?(map_get(payload, :github_pr_number)) do
        {:ok, context}
      else
        {:error, {:missing_required_fields, [:github_pr_url]}, 400}
      end
    end
  end

  defp validate_context(:request_simulation, payload) do
    required_context(payload, [:issue_id, :project_id, :scenario])
  end

  defp execute_action(action, context, opts) when action in @runtime_actions do
    runner = Keyword.get(opts, :runner, fn _command, _context -> {:ok, %{queued: true}} end)

    case runner.(to_string(action), context) do
      {:ok, response} -> {:ok, %{runtime: response}}
      {:error, reason} -> {:error, {:runtime_rejected, reason}, 409}
    end
  end

  defp execute_action(:approve_public_comment, context, opts) do
    field = context |> map_get(:target_field, :public_comments) |> normalize_key()
    surface = context |> map_get(:surface, :github_comment) |> normalize_key()
    template = context |> map_get(:template, Keyword.get(opts, :template, :symphony)) |> normalize_key()

    preview_opts =
      opts
      |> projection_preview_opts(context)
      |> Keyword.put(:approvals, [field])
      |> Keyword.put(:capabilities, Keyword.get(opts, :capabilities, %{}))

    preview = ProjectionTemplates.preview_surface(template, surface, %{field => map_get(context, :value)}, preview_opts)

    if Map.has_key?(preview.allowed, field) do
      {:ok, %{policy: preview}}
    else
      {:error, projection_rejection(preview, field), 400, %{policy: preview}}
    end
  end

  defp execute_action(:approve_spec_amendment, context, _opts) do
    {:ok, %{amendment: %{status: "approved", issue_id: context.issue_id}}}
  end

  defp execute_action(:approve_merge_handoff, context, _opts) do
    {:ok, %{merge_handoff: %{status: "approved", issue_id: context.issue_id}}}
  end

  defp execute_action(:request_simulation, context, _opts) do
    {:ok, %{simulation: %{status: "requested", issue_id: context.issue_id}}}
  end

  defp accepted_result(action, context, result) do
    base_result("accepted", action, context, nil, 202)
    |> Map.merge(result)
  end

  defp rejected_result(payload, reason, http_status) do
    action = payload |> map_get(:action, "unknown") |> normalize_key()
    context = normalize_context(payload)

    base_result("rejected", action, context, reason, http_status)
  end

  defp base_result(status, action, context, reason, http_status) do
    result = %{
      status: status,
      action: to_string(action),
      reason: reason,
      http_status: http_status,
      summary: summary(status, action, context),
      audit_event: audit_event(status, action, context, reason)
    }

    if reason, do: Map.put(result, :reason, reason), else: Map.delete(result, :reason)
  end

  defp audit_event(status, action, context, reason) do
    %{
      project_id: numeric_id(map_get(context, :project_id)),
      symphony_issue_id: numeric_id(map_get(context, :symphony_issue_id)),
      actor: "linear",
      action: "linear_action.#{status}",
      target_type: "linear_action",
      target_id: to_string(map_get(context, :issue_id, "unknown")),
      payload: %{
        action: action,
        issue_id: map_get(context, :issue_id),
        project_id: map_get(context, :project_id),
        reason: reason
      }
    }
  end

  defp summary("accepted", action, context), do: "#{action} accepted for issue #{map_get(context, :issue_id, "unknown")}"
  defp summary("rejected", action, context), do: "#{action} rejected for issue #{map_get(context, :issue_id, "unknown")}"

  defp required_context(payload, required_fields) do
    missing_fields = Enum.reject(required_fields, &present?(map_get(payload, &1)))

    if missing_fields == [] do
      {:ok, normalize_context(payload)}
    else
      {:error, {:missing_required_fields, missing_fields}, 400}
    end
  end

  defp normalize_context(payload) do
    payload
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
  end

  defp projection_rejection(preview, field) do
    if Map.has_key?(preview.rejected, field) do
      Map.fetch!(preview.rejected, field)
    else
      :projection_surface_excludes_field
    end
  end

  defp projection_preview_opts(opts, context) do
    mode = map_get(context, :mode, Keyword.get(opts, :mode))

    if present?(mode), do: [mode: mode], else: []
  end

  defp provided_token(payload, headers) do
    header_token =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(to_string(key)) == "x-symphony-linear-action-token", do: value
      end)

    header_token || map_get(payload, :token)
  end

  defp numeric_id(value) when is_integer(value), do: value
  defp numeric_id(_value), do: nil

  defp present?(value), do: (is_binary(value) and value != "") or (not is_nil(value) and value != "")

  defp normalize_key(nil), do: nil
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(_map, _key, default), do: default
end
