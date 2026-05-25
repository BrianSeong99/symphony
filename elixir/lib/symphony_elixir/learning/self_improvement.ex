defmodule SymphonyElixir.Learning.SelfImprovement do
  @moduledoc """
  Converts Symphony runtime learnings into safe issue proposals.

  The learning loop is intentionally proposal-only by default. It can summarize
  real usage signals and hand proposed work to a caller, but hard policy changes
  stay human-gated and config/pattern updates are represented as PR-backed work
  instead of direct mutation.
  """

  @hard_policy_areas ~w(hard_safety_policy credential_policy merge_authority public_sync_policy repo_access)
  @low_risk_areas ~w(docs tests config observability)

  @type signal :: map()
  @type proposal :: map()
  @type review :: %{
          required(:mode) => :dry_run | :write,
          required(:proposals) => [proposal()],
          required(:duplicates) => [map()],
          required(:digest) => String.t()
        }

  @spec review([signal()]) :: review()
  def review(signals), do: review(signals, [])

  @spec review([signal()], keyword()) :: review()
  def review(signals, opts) when is_list(signals) and is_list(opts) do
    existing_issues = Keyword.get(opts, :existing_issues, [])
    runner_proven? = Keyword.get(opts, :runner_proven?, false)
    mode = if Keyword.get(opts, :write?, false), do: :write, else: :dry_run

    {duplicates, proposals} =
      signals
      |> Enum.map(&proposal_from_signal(&1, runner_proven?))
      |> Enum.split_with(&duplicate?(&1, existing_issues))

    %{
      mode: mode,
      proposals: maybe_write(proposals, opts),
      duplicates: duplicates,
      digest: digest(proposals, duplicates)
    }
  end

  @spec dry_run_json([signal()], keyword()) :: String.t()
  def dry_run_json(signals, opts \\ []) when is_list(signals) and is_list(opts) do
    signals
    |> review(Keyword.put(opts, :write?, false))
    |> Jason.encode!(pretty: true)
  end

  @spec hard_policy_area?(String.t() | atom() | nil) :: boolean()
  def hard_policy_area?(area) do
    area
    |> normalize_area()
    |> then(&(&1 in @hard_policy_areas))
  end

  defp proposal_from_signal(signal, runner_proven?) do
    area = signal |> map_get(:risk_area, map_get(signal, :area, "observability")) |> normalize_area()
    hard_policy? = area in @hard_policy_areas
    title = proposal_title(signal, area)

    %{
      title: title,
      description: proposal_description(signal, area, hard_policy?),
      issue_type: issue_type(area),
      risk: if(hard_policy?, do: "critical", else: risk_for_area(area)),
      source_signal: source_signal(signal),
      acceptance_criteria: acceptance_criteria(signal, area, hard_policy?),
      validation_commands: validation_commands(area, hard_policy?),
      dependency_edges: dependency_edges(signal),
      checkpoint_requirements: checkpoint_requirements(area, hard_policy?),
      public_sync_policy: public_sync_policy(signal, hard_policy?),
      auto_work_allowed: auto_work_allowed?(area, hard_policy?, runner_proven?),
      duplicate_key: duplicate_key(title)
    }
  end

  defp maybe_write(proposals, opts) do
    case {Keyword.get(opts, :write?, false), Keyword.get(opts, :issue_writer)} do
      {true, writer} when is_function(writer, 1) ->
        Enum.map(proposals, &write_proposal(&1, writer))

      _other ->
        proposals
    end
  end

  defp write_proposal(proposal, writer) do
    case writer.(proposal) do
      {:ok, written} -> Map.put(proposal, :written, written)
      {:error, reason} -> Map.put(proposal, :write_error, inspect(reason))
    end
  end

  defp duplicate?(proposal, existing_issues) do
    proposal.duplicate_key in Enum.map(existing_issues, &existing_duplicate_key/1)
  end

  defp existing_duplicate_key(issue), do: issue |> map_get(:title, "") |> duplicate_key()

  defp proposal_title(signal, area) do
    base =
      signal
      |> map_get(:title, map_get(signal, :summary, "Review Symphony improvement signal"))
      |> to_string()
      |> String.trim()

    "Learning: #{base} [#{area}]"
  end

  defp proposal_description(signal, area, hard_policy?) do
    [
      "## Problem",
      map_get(signal, :problem, map_get(signal, :summary, "Symphony observed an improvement opportunity.")),
      "",
      "## Evidence",
      evidence_text(signal),
      "",
      "## Learning classification",
      "- Source: #{map_get(signal, :source, "unknown")}",
      "- Risk area: #{area}",
      "- Hard policy gated: #{hard_policy?}",
      "",
      "## Required handling",
      required_handling(hard_policy?)
    ]
    |> Enum.join("\n")
  end

  defp source_signal(signal) do
    %{
      source: map_get(signal, :source, "unknown"),
      kind: map_get(signal, :kind, "runtime_signal"),
      fingerprint: map_get(signal, :fingerprint, duplicate_key(inspect(signal))),
      evidence: List.wrap(map_get(signal, :evidence, []))
    }
  end

  defp acceptance_criteria(signal, area, hard_policy?) do
    base = [
      "Issue includes the source signal and concrete evidence.",
      "Implementation updates tests, docs, config, or observability according to the proposal risk area.",
      "Validation commands are recorded before handoff.",
      "Duplicate open or closed issues are checked before creating new work.",
      "Any dynamic requirement change updates the issue/workpad before implementation continues."
    ]

    policy =
      if hard_policy? do
        ["Human approval is recorded before changing #{area}."]
      else
        ["If the change creates a reusable pattern, it is proposed through a PR-backed config update."]
      end

    extra = signal |> map_get(:acceptance_criteria, []) |> List.wrap() |> Enum.map(&to_string/1)
    base ++ policy ++ extra
  end

  defp validation_commands(area, hard_policy?) do
    commands =
      case area do
        "docs" -> ["mix test test/symphony_elixir/research_registry_test.exs"]
        "tests" -> ["mix test"]
        "config" -> ["mix test test/symphony_elixir/research_registry_test.exs test/symphony_elixir/linear_operating_model_test.exs"]
        "observability" -> ["mix test test/symphony_elixir/observability_test.exs"]
        _other -> ["make all"]
      end

    if hard_policy?, do: commands ++ ["manual approval checkpoint"], else: commands
  end

  defp dependency_edges(signal) do
    signal
    |> map_get(:depends_on, [])
    |> List.wrap()
    |> Enum.map(fn dependency ->
      %{
        depends_on: to_string(dependency),
        dependency_policy: "all_done",
        unblock_condition: "Dependency is merged and validation evidence is attached."
      }
    end)
  end

  defp checkpoint_requirements(_area, true) do
    [
      "Human approval required before changing hard safety, credentials, merge authority, public sync, or repo access policy.",
      "Approval must be recorded in Linear/Symphony before work starts."
    ]
  end

  defp checkpoint_requirements(_area, false) do
    [
      "No human review required for low-risk implementation when runner reliability gates are proven.",
      "Escalate to a checkpoint if validation and issue requirements conflict."
    ]
  end

  defp public_sync_policy(signal, hard_policy?) do
    if hard_policy? do
      "private_only_until_human_approval"
    else
      map_get(signal, :public_sync_policy, "linear_safe_summary_only")
    end
  end

  defp auto_work_allowed?(area, hard_policy?, runner_proven?) do
    not hard_policy? and runner_proven? and area in @low_risk_areas
  end

  defp digest(proposals, duplicates) do
    "Self-improvement review: #{length(proposals)} proposal(s), #{length(duplicates)} duplicate(s), #{Enum.count(proposals, & &1.auto_work_allowed)} auto-work eligible."
  end

  defp evidence_text(signal) do
    signal
    |> map_get(:evidence, [])
    |> List.wrap()
    |> case do
      [] -> "- No structured evidence supplied."
      evidence -> Enum.map_join(evidence, "\n", &"- #{format_evidence(&1)}")
    end
  end

  defp format_evidence(value) when is_binary(value), do: value
  defp format_evidence(value), do: inspect(value)

  defp required_handling(true) do
    "Create a proposal issue and require human approval before any policy mutation. Do not auto-weaken hard gates."
  end

  defp required_handling(false) do
    "Create a proposal issue. Auto-work is allowed only when the runner has passed reliability gates and local validation is explicit."
  end

  defp issue_type("docs"), do: "docs"
  defp issue_type("tests"), do: "test-validation"
  defp issue_type("config"), do: "infra-homelab"
  defp issue_type("observability"), do: "backend-api"
  defp issue_type(_area), do: "follow-up-tech-debt"

  defp risk_for_area(area) when area in @low_risk_areas, do: "low"
  defp risk_for_area(_area), do: "medium"

  defp normalize_area(nil), do: "observability"

  defp normalize_area(area) do
    area
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp duplicate_key(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp map_get(map, key, default)
  defp map_get(map, key, default) when is_map(map) and is_atom(key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
