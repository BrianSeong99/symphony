defmodule SymphonyElixir.Reviews.ReviewLoop do
  @moduledoc """
  Coordinates PR feedback ingestion, repair work, validation, and handoff gating.
  """

  alias SymphonyElixir.AgentSessions.BuilderRunner
  alias SymphonyElixir.LoopBreaker
  alias SymphonyElixir.Reviews.{ReviewFinding, ReviewFindings}

  @type feedback_item :: map()
  @type cycle_result :: %{
          required(:status) => String.t(),
          required(:findings) => [ReviewFinding.t()],
          optional(:validation) => map() | nil,
          optional(:builder_result) => map(),
          optional(:builder_error) => term(),
          optional(:open_findings) => [ReviewFinding.t()]
        }

  @spec ingest_feedback(pos_integer(), [feedback_item()]) :: [ReviewFinding.t()]
  def ingest_feedback(symphony_issue_id, feedback_items)
      when is_integer(symphony_issue_id) and is_list(feedback_items) do
    Enum.map(feedback_items, &finding_from_feedback(symphony_issue_id, &1))
  end

  @spec repair_issue(map(), [ReviewFinding.t()]) :: map()
  def repair_issue(issue, findings) when is_map(issue) and is_list(findings) do
    repair_items = Enum.map(actionable_findings(findings), &repair_item/1)
    metadata = issue |> Map.get(:metadata, %{}) |> Map.put("repair_items", repair_items)

    Map.put(issue, :metadata, metadata)
  end

  @spec run_cycle(map(), [feedback_item()], list(), keyword()) :: cycle_result()
  def run_cycle(issue, feedback_items, sessions, opts \\ [])
      when is_map(issue) and is_list(feedback_items) and is_list(sessions) do
    loop_events = Keyword.get(opts, :loop_events, [])
    findings = Keyword.get(opts, :findings, []) ++ ingest_feedback(Map.fetch!(issue, :id), feedback_items)

    case loop_breaker_decision(loop_events, issue) do
      {:break, decision} ->
        human_checkpoint_result(findings, nil, decision)

      :continue ->
        case actionable_findings(findings) do
          [] ->
            handoff_decision(findings, %{status: "passed"})

          _open_findings ->
            run_repair_cycle(issue, findings, sessions, opts)
        end
    end
  end

  @spec handoff_decision([ReviewFinding.t()], map()) :: map()
  def handoff_decision(findings, validation) when is_list(findings) and is_map(validation) do
    open_findings = actionable_findings(findings)

    cond do
      open_findings != [] ->
        %{status: "repair_required", open_findings: open_findings}

      validation_passed?(validation) ->
        %{status: "human_review_ready", open_findings: []}

      true ->
        %{status: "repair_required", open_findings: []}
    end
  end

  defp run_repair_cycle(issue, findings, sessions, opts) do
    repair_issue = repair_issue(issue, findings)
    builder_runner = Keyword.get(opts, :builder_runner, &default_builder_runner/2)
    validation_runner = Keyword.get(opts, :validation_runner, &default_validation_runner/2)

    case builder_runner.(repair_issue, sessions) do
      {:ok, builder_result} ->
        {:ok, validation} = validation_runner.(repair_issue, builder_result)
        loop_events = Keyword.get(opts, :loop_events, []) ++ validation_events(validation)

        case loop_breaker_decision(loop_events, issue) do
          {:break, decision} ->
            human_checkpoint_result(findings, validation, decision)

          :continue ->
            updated_findings = maybe_resolve_findings(findings, validation)

            updated_findings
            |> handoff_decision(validation)
            |> Map.merge(%{
              findings: updated_findings,
              validation: validation,
              builder_result: builder_result
            })
        end

      {:error, reason} ->
        %{status: "repair_required", findings: findings, validation: nil, builder_error: reason}
    end
  end

  defp default_builder_runner(repair_issue, sessions) do
    BuilderRunner.run(repair_issue, sessions)
  end

  defp default_validation_runner(_repair_issue, _builder_result) do
    {:ok, %{status: "passed", evidence: "default validation runner"}}
  end

  defp loop_breaker_decision([], _issue), do: :continue

  defp loop_breaker_decision(events, issue) do
    case LoopBreaker.evaluate(events, issue_identifier: Map.get(issue, :identifier) || Map.get(issue, :id)) do
      {:continue, _summary} -> :continue
      {:break, decision} -> {:break, decision}
    end
  end

  defp human_checkpoint_result(findings, validation, decision) do
    %{
      status: "human-checkpoint",
      findings: findings,
      validation: validation,
      loop_breaker: decision,
      issue_transition: decision.issue_transition
    }
  end

  defp validation_events(%{status: "failed"} = validation), do: [validation_event(validation)]
  defp validation_events(%{"status" => "failed"} = validation), do: [validation_event(validation)]
  defp validation_events(_validation), do: []

  defp validation_event(validation) do
    %{
      kind: :validation_failure,
      phase: Map.get(validation, :phase) || Map.get(validation, "phase", "validation"),
      attempt: Map.get(validation, :attempt) || Map.get(validation, "attempt"),
      command: Map.get(validation, :command) || Map.get(validation, "command"),
      output: Map.get(validation, :evidence) || Map.get(validation, "evidence")
    }
  end

  defp maybe_resolve_findings(findings, validation) do
    if validation_passed?(validation) do
      Enum.map(findings, &resolve_if_actionable(&1, validation))
    else
      findings
    end
  end

  defp resolve_if_actionable(%ReviewFinding{} = finding, validation) do
    if actionable?(finding) do
      {:ok, resolved} =
        ReviewFindings.transition(finding, "resolved", evidence: Map.get(validation, :evidence) || Map.get(validation, "evidence"))

      resolved
    else
      finding
    end
  end

  defp actionable_findings(findings) do
    Enum.filter(findings, &actionable?/1)
  end

  defp actionable?(%ReviewFinding{state: "open", metadata: metadata}) do
    Map.get(metadata, "actionable", true) == true
  end

  defp actionable?(_finding), do: false

  defp validation_passed?(validation) do
    (Map.get(validation, :status) || Map.get(validation, "status")) in [:passed, "passed"]
  end

  defp finding_from_feedback(issue_id, %{type: :comment} = feedback) do
    new_finding(issue_id, "PR comment requires follow-up", feedback, "medium")
  end

  defp finding_from_feedback(issue_id, %{type: :inline_comment} = feedback) do
    new_finding(issue_id, "Inline review comment requires follow-up", feedback, "medium")
  end

  defp finding_from_feedback(issue_id, %{type: :review_summary} = feedback) do
    new_finding(issue_id, "Review summary requires follow-up", feedback, "medium")
  end

  defp finding_from_feedback(issue_id, %{type: :check_failure, name: name} = feedback) do
    new_finding(issue_id, "Check failed: #{name}", feedback, "high")
  end

  defp finding_from_feedback(issue_id, feedback) do
    new_finding(issue_id, "Review feedback requires follow-up", feedback, "medium")
  end

  defp new_finding(issue_id, title, feedback, severity) do
    %ReviewFinding{
      symphony_issue_id: issue_id,
      state: "open",
      severity: severity,
      title: title,
      body: Map.get(feedback, :body) || Map.get(feedback, "body"),
      source_url: Map.get(feedback, :url) || Map.get(feedback, "url"),
      metadata: feedback_metadata(feedback)
    }
  end

  defp feedback_metadata(feedback) do
    feedback
    |> Enum.reject(fn {key, _value} -> key in [:body, "body", :url, "url"] end)
    |> Map.new(fn {key, value} -> {to_string(key), stringify_value(value)} end)
    |> Map.put_new("actionable", true)
  end

  defp repair_item(%ReviewFinding{} = finding) do
    %{
      "title" => finding.title,
      "body" => finding.body,
      "source_url" => finding.source_url
    }
  end

  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value), do: value
end
