defmodule SymphonyElixir.ConflictResolver do
  @moduledoc """
  Conflict detection and resolution planning across Linear, GitHub, and Symphony.

  The resolver is intentionally deterministic. It does not perform writes; it
  emits proposed resolutions, checkpoint payloads, and audit events that callers
  can persist or hand to the Linear relay.
  """

  alias SymphonyElixir.{FieldPolicy, ProjectionTemplates}

  @field_drift_specs [
    %{
      type: :linear_title_changed,
      field: :title,
      path: [:linear, :title],
      source: :linear,
      public_surface: :github_issue
    },
    %{
      type: :linear_description_changed,
      field: :planning_notes,
      path: [:linear, :description],
      source: :linear,
      public_surface: nil
    },
    %{
      type: :github_issue_body_changed,
      field: :public_comments,
      path: [:github_issue, :body],
      source: :github,
      public_surface: :github_issue
    },
    %{
      type: :github_pr_state_changed,
      field: :pr_state,
      path: [:github_pr, :state],
      source: :github,
      public_surface: nil
    },
    %{
      type: :dependency_drift,
      field: :dependencies,
      path: [:dependencies],
      source: :symphony,
      public_surface: :github_issue
    }
  ]

  @ambiguous_owners ["relay_gated", "linear_or_symphony_private"]

  @type conflict :: map()
  @type resolution :: map()
  @type result :: %{
          required(:status) => :ok | :needs_checkpoint,
          required(:conflicts) => [conflict()],
          required(:resolutions) => [resolution()],
          required(:audit_events) => [map()],
          required(:checkpoint) => map() | nil
        }

  @spec resolve(map()) :: result()
  def resolve(snapshot), do: resolve(snapshot, [])

  @spec resolve(map(), keyword()) :: result()
  def resolve(snapshot, opts) when is_map(snapshot) and is_list(opts) do
    conflicts = detect(snapshot)
    resolutions = Enum.map(conflicts, &resolution_for(&1, snapshot, opts))
    checkpoint = checkpoint_payload(snapshot, conflicts, resolutions)

    %{
      status: if(checkpoint, do: :needs_checkpoint, else: :ok),
      conflicts: conflicts,
      resolutions: resolutions,
      audit_events: audit_events(snapshot, conflicts, resolutions),
      checkpoint: checkpoint
    }
  end

  @spec detect(map()) :: [conflict()]
  def detect(snapshot) when is_map(snapshot) do
    []
    |> add_stale_webhook(snapshot)
    |> add_missing_links(snapshot)
    |> add_field_drifts(snapshot)
    |> Enum.reverse()
  end

  defp add_stale_webhook(conflicts, snapshot) do
    webhook = map_get(snapshot, :webhook, %{})

    if stale_webhook?(webhook) do
      [
        %{
          type: :stale_webhook,
          source: normalize_source(map_get(webhook, :provider, :unknown)),
          field: nil,
          expected: map_get(webhook, :last_seen_at),
          observed: map_get(webhook, :occurred_at),
          evidence: %{webhook: webhook}
        }
        | conflicts
      ]
    else
      conflicts
    end
  end

  defp add_missing_links(conflicts, snapshot) do
    links = map_get(snapshot, :links, %{})

    snapshot
    |> map_get(:required_links, [])
    |> Enum.reduce(conflicts, fn link_key, acc ->
      normalized_link = normalize_key(link_key)

      if present?(map_get(links, normalized_link)) do
        acc
      else
        [
          %{
            type: :missing_github_link,
            source: :symphony,
            field: normalized_link,
            expected: :present,
            observed: nil,
            evidence: %{required_link: normalized_link, links: links}
          }
          | acc
        ]
      end
    end)
  end

  defp add_field_drifts(conflicts, snapshot) do
    expected = map_get(snapshot, :expected, %{})
    observed = map_get(snapshot, :observed, %{})

    Enum.reduce(@field_drift_specs, conflicts, fn spec, acc ->
      expected_value = get_path(expected, spec.path)
      observed_value = get_path(observed, spec.path)

      if comparable?(expected_value, observed_value) and expected_value != observed_value do
        [field_conflict(spec, expected_value, observed_value) | acc]
      else
        acc
      end
    end)
  end

  defp field_conflict(spec, expected_value, observed_value) do
    %{
      type: spec.type,
      field: spec.field,
      source: spec.source,
      public_surface: spec.public_surface,
      expected: expected_value,
      observed: observed_value,
      evidence: %{path: spec.path, expected: expected_value, observed: observed_value}
    }
  end

  defp resolution_for(%{type: :stale_webhook} = conflict, _snapshot, _opts) do
    base_resolution(conflict, :auto, :ignore_event, :stale_webhook)
  end

  defp resolution_for(%{type: :missing_github_link} = conflict, _snapshot, _opts) do
    base_resolution(conflict, :checkpoint, :attach_or_create_link, :missing_required_link)
  end

  defp resolution_for(%{field: field} = conflict, snapshot, opts) do
    field_owner =
      opts
      |> Keyword.get(:field_policy, FieldPolicy.load!())
      |> FieldPolicy.field(field)
      |> owner_source()

    resolve_by_owner(conflict, snapshot, opts, field_owner)
  end

  defp resolve_by_owner(conflict, _snapshot, _opts, :ambiguous) do
    base_resolution(conflict, :checkpoint, :request_human_checkpoint, :ambiguous_field_owner)
  end

  defp resolve_by_owner(%{source: source} = conflict, snapshot, opts, source) do
    case public_projection_decision(conflict, snapshot, opts) do
      {:allow, projection} ->
        conflict
        |> base_resolution(:auto, action_for_source(source), owner_reason(source))
        |> Map.put(:projection, projection)

      {:block, reason, projection} ->
        conflict
        |> base_resolution(:checkpoint, :request_human_checkpoint, reason)
        |> Map.put(:projection, projection)
    end
  end

  defp resolve_by_owner(conflict, _snapshot, _opts, owner) do
    conflict
    |> base_resolution(:auto, :restore_owner_value, owner_reason(owner))
    |> Map.put(:owner, owner)
  end

  defp public_projection_decision(%{public_surface: nil}, _snapshot, _opts), do: {:allow, %{}}

  defp public_projection_decision(conflict, snapshot, opts) do
    template = opts |> Keyword.get(:template, map_get(snapshot, :template, :symphony)) |> normalize_key()
    mode = Keyword.get(opts, :mode, map_get(snapshot, :mode))
    preview_opts = projection_preview_opts(opts, mode)

    projection = ProjectionTemplates.preview_surface(template, conflict.public_surface, %{conflict.field => conflict.observed}, preview_opts)

    cond do
      Map.has_key?(projection.allowed, conflict.field) ->
        {:allow, projection}

      Map.has_key?(projection.rejected, conflict.field) ->
        {:block, Map.fetch!(projection.rejected, conflict.field), projection}

      true ->
        {:block, :projection_surface_excludes_field, projection}
    end
  end

  defp projection_preview_opts(opts, nil) do
    [
      approvals: Keyword.get(opts, :approvals, []),
      capabilities: Keyword.get(opts, :capabilities, %{})
    ]
  end

  defp projection_preview_opts(opts, mode) do
    opts
    |> projection_preview_opts(nil)
    |> Keyword.put(:mode, mode)
  end

  defp base_resolution(conflict, status, action, reason) do
    %{
      conflict_type: conflict.type,
      field: conflict.field,
      status: status,
      action: action,
      source: Map.get(conflict, :source),
      reason: reason,
      value: Map.get(conflict, :observed),
      evidence: Map.get(conflict, :evidence, %{}),
      projection: %{}
    }
  end

  defp checkpoint_payload(_snapshot, _conflicts, resolutions) do
    checkpoint_resolutions = Enum.filter(resolutions, &(&1.status == :checkpoint))

    if checkpoint_resolutions == [] do
      nil
    else
      %{
        required?: true,
        reason: :unresolved_sync_conflicts,
        conflicts: Enum.map(checkpoint_resolutions, &checkpoint_conflict/1),
        proposed_resolutions: checkpoint_resolutions
      }
    end
  end

  defp checkpoint_conflict(resolution) do
    %{
      type: resolution.conflict_type,
      field: resolution.field,
      reason: resolution.reason
    }
  end

  defp audit_events(snapshot, conflicts, resolutions) do
    drift_events = Enum.map(conflicts, &audit_event(snapshot, "drift.detected", %{conflict: &1}))
    resolution_events = Enum.map(resolutions, &audit_event(snapshot, "drift.resolution_proposed", %{resolution: &1}))

    drift_events ++ resolution_events
  end

  defp audit_event(snapshot, action, payload) do
    %{
      project_id: map_get(snapshot, :project_id),
      symphony_issue_id: map_get(snapshot, :symphony_issue_id),
      actor: "symphony",
      action: action,
      target_type: "symphony_issue",
      target_id: snapshot |> map_get(:symphony_issue_id) |> to_string(),
      payload: payload
    }
  end

  defp stale_webhook?(webhook) do
    with {:ok, occurred_at} <- coerce_datetime(map_get(webhook, :occurred_at)),
         {:ok, last_seen_at} <- coerce_datetime(map_get(webhook, :last_seen_at)) do
      DateTime.compare(occurred_at, last_seen_at) == :lt
    else
      _ -> false
    end
  end

  defp coerce_datetime(%DateTime{} = value), do: {:ok, value}

  defp coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, reason}
    end
  end

  defp coerce_datetime(_value), do: {:error, :invalid_datetime}

  defp owner_source(nil), do: :ambiguous

  defp owner_source(%{owner: owner}) when owner in @ambiguous_owners, do: :ambiguous
  defp owner_source(%{owner: "linear"}), do: :linear
  defp owner_source(%{owner: "github"}), do: :github
  defp owner_source(%{owner: "symphony"}), do: :symphony
  defp owner_source(_field), do: :ambiguous

  defp action_for_source(:github), do: :ingest_field
  defp action_for_source(_source), do: :project_field

  defp owner_reason(owner), do: :"field_owner_#{owner}"

  defp comparable?(left, right), do: not is_nil(left) and not is_nil(right)

  defp get_path(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      case map_get(acc, key, :__missing__) do
        :__missing__ -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp present?(value), do: (is_binary(value) and value != "") or (not is_nil(value) and value != "")

  defp normalize_source(source), do: normalize_key(source)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp map_get(map, key, default \\ nil)
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(_map, _key, default), do: default
end
