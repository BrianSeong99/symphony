defmodule SymphonyElixir.Linear.Intake do
  @moduledoc """
  Normalizes Linear Intelligence and Agent outputs into Symphony suggestions.

  The intake layer does not execute work. It turns external suggestions into
  proposed, accepted, or rejected records that policy-aware callers can persist
  to workpads, spec amendments, dependency graphs, checkpoint queues, and audit
  logs.
  """

  alias SymphonyElixir.{FieldPolicy, Linear.OperatingModel}

  @operating_model_path Path.expand("../../../../config/symphony/linear-operating-model.yml", __DIR__)

  @validation_relaxation_markers [
    "skip tests",
    "no tests",
    "remove validation",
    "manual review only",
    "manual only",
    "validation not required",
    "without tests"
  ]

  @type suggestion_status :: :proposed | :accepted | :rejected
  @type suggestion :: %{
          required(:id) => String.t(),
          required(:kind) => atom(),
          required(:field) => atom(),
          required(:value) => term(),
          required(:status) => suggestion_status(),
          required(:reason) => term(),
          required(:target) => atom(),
          required(:profile) => atom(),
          required(:source) => String.t(),
          required(:metadata) => map()
        }
  @type result :: %{
          required(:status) => atom(),
          required(:profile) => atom(),
          required(:source) => String.t(),
          required(:suggestions) => [suggestion()],
          required(:proposed) => [suggestion()],
          required(:accepted) => [suggestion()],
          required(:rejected) => [suggestion()],
          required(:triage) => map(),
          required(:workpad_amendments) => [suggestion()],
          required(:spec_amendments) => [suggestion()],
          required(:dependencies) => [suggestion()],
          required(:checkpoint_requests) => [suggestion()],
          required(:project_metadata) => [suggestion()],
          required(:audit_events) => [map()]
        }

  @spec normalize(map()) :: result()
  def normalize(payload), do: normalize(payload, [])

  @spec normalize(map(), keyword()) :: result()
  def normalize(payload, opts) when is_map(payload) and is_list(opts) do
    context = intake_context(payload, opts)

    suggestions =
      payload
      |> build_suggestions(context)
      |> Enum.map(&evaluate_suggestion(&1, opts))

    %{
      status: aggregate_status(suggestions),
      profile: context.profile,
      source: context.source,
      suggestions: suggestions,
      proposed: suggestions_by_status(suggestions, :proposed),
      accepted: suggestions_by_status(suggestions, :accepted),
      rejected: suggestions_by_status(suggestions, :rejected),
      triage: triage_summary(suggestions),
      workpad_amendments: suggestions_by_kind(suggestions, :workpad_amendment),
      spec_amendments: suggestions_by_kind(suggestions, :spec_amendment),
      dependencies: suggestions_by_kind(suggestions, :dependency),
      checkpoint_requests: suggestions_by_kind(suggestions, :checkpoint_request),
      project_metadata: suggestions_by_kind(suggestions, :project_metadata),
      audit_events: Enum.map(suggestions, &audit_event(&1, context))
    }
  end

  @spec apply_accepted_workpad_amendments(String.t(), result() | [suggestion()]) :: String.t()
  def apply_accepted_workpad_amendments(body, result_or_suggestions) when is_binary(body) do
    result_or_suggestions
    |> accepted_amendments()
    |> Enum.reduce(body, &apply_amendment/2)
  end

  defp intake_context(payload, opts) do
    profile = opts |> Keyword.get(:profile, map_get(payload, :profile, :symphony)) |> normalize_key()

    %{
      source: payload |> map_get(:source, "linear") |> to_string(),
      project_id: map_get(payload, :project_id),
      symphony_issue_id: map_get(payload, :symphony_issue_id),
      linear_issue_id: map_get(payload, :linear_issue_id),
      profile: profile
    }
  end

  defp build_suggestions(payload, context) do
    triage = map_get(payload, :triage, %{})
    agent = map_get(payload, :agent, %{})

    build_triage_suggestions(triage, context) ++
      build_workpad_amendment_suggestions(agent, context) ++
      build_spec_amendment_suggestions(agent, context) ++
      build_dependency_suggestions(agent, context) ++
      build_checkpoint_suggestions(agent, context) ++
      build_project_metadata_suggestions(agent, context)
  end

  defp build_triage_suggestions(triage, context) when is_map(triage) do
    [
      triage_suggestion(triage, context, :labels, &normalize_labels/1),
      triage_suggestion(triage, context, :owner, &normalize_owner/1),
      triage_suggestion(triage, context, :project, &normalize_project/1),
      triage_suggestion(triage, context, :priority, &normalize_priority/1)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp build_triage_suggestions(_triage, _context), do: []

  defp triage_suggestion(triage, context, field, normalizer) do
    case map_fetch(triage, field) do
      {:ok, value} ->
        new_suggestion(context, :triage, field, normalizer.(value), %{target: :linear})

      :error ->
        nil
    end
  end

  defp build_workpad_amendment_suggestions(agent, context) when is_map(agent) do
    agent
    |> collect_list(:workpad_amendments, :workpad_amendment)
    |> Enum.map(fn amendment ->
      value = %{
        section: amendment |> map_get(:section, "Scope Interpretation") |> to_string(),
        title: map_get(amendment, :title),
        text: amendment |> map_get(:text, map_get(amendment, :body, "")) |> to_string()
      }

      new_suggestion(context, :workpad_amendment, normalize_key(map_get(amendment, :field, :workpad)), value, %{
        target: normalize_key(map_get(amendment, :target, :symphony)),
        metadata: normalize_map(map_get(amendment, :metadata, %{}))
      })
    end)
  end

  defp build_workpad_amendment_suggestions(_agent, _context), do: []

  defp build_spec_amendment_suggestions(agent, context) when is_map(agent) do
    agent
    |> collect_list(:spec_amendments, :spec_amendment)
    |> Enum.map(fn amendment ->
      field = normalize_key(map_get(amendment, :field, :planning_notes))

      value = %{
        section: amendment |> map_get(:section, "Proposed Spec Amendments") |> to_string(),
        title: map_get(amendment, :title),
        text: amendment |> map_get(:text, map_get(amendment, :body, "")) |> to_string()
      }

      new_suggestion(context, :spec_amendment, field, value, %{
        target: normalize_key(map_get(amendment, :target, :symphony)),
        metadata: normalize_map(map_get(amendment, :metadata, %{}))
      })
    end)
  end

  defp build_spec_amendment_suggestions(_agent, _context), do: []

  defp build_dependency_suggestions(agent, context) when is_map(agent) do
    dependencies = agent |> map_get(:dependencies, []) |> List.wrap() |> Enum.map(&normalize_dependency/1)

    if dependencies == [] do
      []
    else
      [new_suggestion(context, :dependency, :dependencies, dependencies, %{target: :symphony})]
    end
  end

  defp build_dependency_suggestions(_agent, _context), do: []

  defp build_checkpoint_suggestions(agent, context) when is_map(agent) do
    agent
    |> collect_list(:checkpoint_requests, :checkpoint_request)
    |> Enum.map(fn checkpoint ->
      value =
        checkpoint
        |> normalize_map()
        |> Map.take([:reason, :cadence, :requested_by, :due_at])

      new_suggestion(context, :checkpoint_request, :private_comments, value, %{target: :linear})
    end)
  end

  defp build_checkpoint_suggestions(_agent, _context), do: []

  defp build_project_metadata_suggestions(agent, context) when is_map(agent) do
    case map_fetch(agent, :project_metadata) do
      {:ok, metadata} ->
        [new_suggestion(context, :project_metadata, :project_metadata, normalize_map(metadata), %{target: :symphony})]

      :error ->
        []
    end
  end

  defp build_project_metadata_suggestions(_agent, _context), do: []

  defp new_suggestion(context, kind, field, value, attrs) do
    target = attrs |> map_get(:target, :symphony) |> normalize_key()
    metadata = attrs |> map_get(:metadata, %{}) |> normalize_map()

    suggestion = %{
      id: suggestion_id(kind, field, target, value),
      kind: kind,
      field: field,
      value: value,
      status: :proposed,
      reason: :awaiting_policy_or_approval,
      target: target,
      profile: context.profile,
      source: context.source,
      metadata: metadata
    }

    Map.merge(suggestion, Map.take(attrs, [:surface]))
  end

  defp evaluate_suggestion(suggestion, opts) do
    with {:ok, suggestion} <- validation_allows(suggestion, opts),
         {:ok, suggestion} <- project_policy_allows(suggestion, opts),
         {:ok, suggestion} <- field_policy_allows(suggestion, opts) do
      apply_acceptance(suggestion, opts)
    else
      {:reject, reason} -> reject_suggestion(suggestion, reason)
    end
  end

  defp validation_allows(%{field: :validation} = suggestion, opts) do
    requirements = Keyword.get(opts, :validation_requirements, [])

    if requirements != [] and relaxes_validation?(suggestion) do
      {:reject, :validation_requirement_conflict}
    else
      {:ok, suggestion}
    end
  end

  defp validation_allows(suggestion, _opts), do: {:ok, suggestion}

  defp project_policy_allows(%{field: :project_metadata, value: value} = suggestion, opts) do
    operating_model = Keyword.get_lazy(opts, :operating_model, &load_operating_model!/0)
    project_key = value[:outcome_project] || value[:project]
    sync_profile = value[:sync_profile]

    if is_nil(project_key) or is_nil(sync_profile) do
      {:ok, suggestion}
    else
      validate_suggested_sync_profile(suggestion, operating_model, project_key, sync_profile)
    end
  end

  defp project_policy_allows(suggestion, _opts), do: {:ok, suggestion}

  defp validate_suggested_sync_profile(suggestion, operating_model, project_key, sync_profile) do
    case Map.fetch(Map.get(operating_model, "outcome_projects", %{}), project_key) do
      {:ok, project} ->
        validate_project_domain_and_sync(suggestion, operating_model, project_key, project, sync_profile)

      :error ->
        {:reject, {:unknown_outcome_project, project_key}}
    end
  end

  defp validate_project_domain_and_sync(suggestion, operating_model, project_key, project, sync_profile) do
    suggested_domain = suggestion.value[:operating_domain]
    project_domain = Map.fetch!(project, "operating_domain")

    cond do
      is_binary(suggested_domain) and suggested_domain != project_domain ->
        {:reject, {:outcome_project_domain_mismatch, project_key, suggested_domain, project_domain}}

      OperatingModel.validate_project_sync_profile(operating_model, project_key, sync_profile) == :ok ->
        {:ok, suggestion}

      true ->
        {:reject, {:sync_profile_not_allowed_for_domain, sync_profile, project_domain}}
    end
  end

  defp field_policy_allows(suggestion, opts) do
    field_policy = Keyword.get_lazy(opts, :field_policy, &FieldPolicy.load!/0)

    if FieldPolicy.field(field_policy, suggestion.field) do
      preview =
        FieldPolicy.preview(suggestion.target, suggestion.profile, %{suggestion.field => suggestion.value},
          policy: field_policy,
          approvals: Keyword.get(opts, :approvals, []),
          capabilities: Keyword.get(opts, :capabilities, %{})
        )

      case Map.fetch(preview.rejected, suggestion.field) do
        {:ok, reason} -> {:reject, reason}
        :error -> {:ok, suggestion}
      end
    else
      {:ok, suggestion}
    end
  end

  defp apply_acceptance(suggestion, opts) do
    if explicitly_approved?(suggestion, opts) do
      accept_suggestion(suggestion, :explicit_approval)
    else
      apply_acceptance_policy(suggestion, Keyword.get(opts, :acceptance_policy, &default_acceptance_policy/1))
    end
  end

  defp apply_acceptance_policy(suggestion, policy) when is_function(policy, 1) do
    case policy.(suggestion) do
      {:accept, reason} -> accept_suggestion(suggestion, reason)
      :accept -> accept_suggestion(suggestion, :accepted_by_policy)
      {:reject, reason} -> reject_suggestion(suggestion, reason)
      {:propose, reason} -> propose_suggestion(suggestion, reason)
      :propose -> propose_suggestion(suggestion, :awaiting_policy_or_approval)
      _other -> propose_suggestion(suggestion, :awaiting_policy_or_approval)
    end
  end

  defp default_acceptance_policy(_suggestion), do: :propose

  defp explicitly_approved?(suggestion, opts) do
    suggestion.id in Keyword.get(opts, :approved_suggestion_ids, []) or
      suggestion.kind in Keyword.get(opts, :approved_kinds, []) or
      suggestion.field in Keyword.get(opts, :approved_fields, [])
  end

  defp propose_suggestion(suggestion, reason), do: %{suggestion | status: :proposed, reason: reason}

  defp accept_suggestion(suggestion, reason), do: %{suggestion | status: :accepted, reason: reason}

  defp reject_suggestion(suggestion, reason), do: %{suggestion | status: :rejected, reason: reason}

  defp relaxes_validation?(suggestion) do
    Map.get(suggestion.metadata, :relaxes_validation) == true or
      suggestion.value
      |> amendment_text()
      |> String.downcase()
      |> contains_any?(@validation_relaxation_markers)
  end

  defp amendment_text(%{text: text}) when is_binary(text), do: text
  defp amendment_text(value) when is_binary(value), do: value
  defp amendment_text(value), do: inspect(value)

  defp contains_any?(value, markers), do: Enum.any?(markers, &String.contains?(value, &1))

  defp aggregate_status([]), do: :empty

  defp aggregate_status(suggestions) do
    statuses = suggestions |> Enum.map(& &1.status) |> Enum.uniq()

    case statuses do
      [:proposed] -> :proposed
      [:accepted] -> :accepted
      [:rejected] -> :rejected
      _statuses -> :mixed
    end
  end

  defp suggestions_by_status(suggestions, status), do: Enum.filter(suggestions, &(&1.status == status))

  defp suggestions_by_kind(suggestions, kind), do: Enum.filter(suggestions, &(&1.kind == kind))

  defp triage_summary(suggestions) do
    suggestions
    |> suggestions_by_kind(:triage)
    |> Map.new(fn suggestion -> {suggestion.field, suggestion.value} end)
  end

  defp audit_event(suggestion, context) do
    %{
      project_id: context.project_id,
      symphony_issue_id: context.symphony_issue_id,
      actor: "linear_intake",
      action: "linear_intake.suggestion_#{suggestion.status}",
      target_type: "symphony_issue",
      target_id: audit_target_id(suggestion, context),
      payload: %{source: context.source, suggestion: suggestion}
    }
  end

  defp audit_target_id(_suggestion, %{symphony_issue_id: id}) when not is_nil(id), do: to_string(id)
  defp audit_target_id(_suggestion, %{linear_issue_id: id}) when not is_nil(id), do: to_string(id)
  defp audit_target_id(suggestion, _context), do: suggestion.id

  defp accepted_amendments(%{suggestions: suggestions}), do: accepted_amendments(suggestions)

  defp accepted_amendments(suggestions) when is_list(suggestions) do
    Enum.filter(suggestions, fn suggestion ->
      suggestion.status == :accepted and suggestion.kind in [:workpad_amendment, :spec_amendment]
    end)
  end

  defp apply_amendment(%{kind: :workpad_amendment} = suggestion, body) do
    append_to_section(body, suggestion.value.section, amendment_entry(suggestion))
  end

  defp apply_amendment(%{kind: :spec_amendment} = suggestion, body) do
    append_to_section(body, "Proposed Spec Amendments", amendment_entry(suggestion))
  end

  defp amendment_entry(suggestion) do
    title = map_get(suggestion.value, :title)
    text = suggestion.value |> map_get(:text, "") |> multiline_list_text()

    case title do
      nil -> "- [#{suggestion.id}] #{text}"
      "" -> "- [#{suggestion.id}] #{text}"
      title -> "- [#{suggestion.id}] #{title}: #{text}"
    end
  end

  defp append_to_section(body, section, entry) do
    header = "### #{section}"

    case String.split(body, header, parts: 2) do
      [before_section, rest] ->
        {section_body, after_section} = split_next_section(rest)
        before_section <> header <> append_section_entry(section_body, entry) <> after_section

      [_body] ->
        String.trim_trailing(body) <> "\n\n#{header}\n\n#{entry}\n"
    end
  end

  defp split_next_section(rest) do
    case :binary.match(rest, "\n\n### ") do
      {index, _length} -> :erlang.split_binary(rest, index)
      :nomatch -> {rest, ""}
    end
  end

  defp append_section_entry(section_body, entry) do
    base = String.trim_trailing(section_body)
    separator = if String.trim(base) == "", do: "\n\n", else: "\n"

    base <> separator <> entry <> "\n"
  end

  defp multiline_list_text(text) when is_binary(text), do: String.replace(text, "\n", "\n  ")
  defp multiline_list_text(value), do: value |> to_string() |> multiline_list_text()

  defp normalize_labels(labels) when is_list(labels), do: Enum.map(labels, &normalize_label/1)
  defp normalize_labels(label), do: [normalize_label(label)]

  defp normalize_label(label) when is_binary(label), do: label
  defp normalize_label(label) when is_atom(label), do: Atom.to_string(label)

  defp normalize_label(label) when is_map(label) do
    label
    |> map_get(:name, map_get(label, :key, map_get(label, :id, "")))
    |> to_string()
  end

  defp normalize_label(label), do: to_string(label)

  defp normalize_owner(owner) when is_map(owner) do
    owner
    |> map_get(:name, map_get(owner, :email, map_get(owner, :id, "")))
    |> to_string()
  end

  defp normalize_owner(owner), do: to_string(owner)

  defp normalize_project(project) when is_map(project) do
    project
    |> map_get(:key, map_get(project, :slug, map_get(project, :name, "")))
    |> to_string()
  end

  defp normalize_project(project), do: to_string(project)

  defp normalize_priority(priority), do: priority

  defp normalize_dependency(dependency) when is_map(dependency) do
    dependency
    |> map_get(:identifier, map_get(dependency, :issue_id, map_get(dependency, :id, "")))
    |> to_string()
  end

  defp normalize_dependency(dependency), do: to_string(dependency)

  defp collect_list(map, plural_key, singular_key) do
    case map_fetch(map, plural_key) do
      {:ok, values} -> List.wrap(values)
      :error -> map |> map_get(singular_key, []) |> List.wrap()
    end
    |> Enum.reject(&is_nil/1)
  end

  defp load_operating_model! do
    case OperatingModel.load_file(@operating_model_path) do
      {:ok, model} -> model
      {:error, errors} -> raise ArgumentError, "invalid Linear operating model: #{Enum.join(errors, "; ")}"
    end
  end

  defp suggestion_id(kind, field, target, value) do
    hash =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({kind, field, target, value}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "linear-intake:#{kind}:#{field}:#{hash}"
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp map_fetch(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp map_fetch(_map, _key), do: :error

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
end
