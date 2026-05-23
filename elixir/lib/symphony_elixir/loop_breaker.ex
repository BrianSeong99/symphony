defmodule SymphonyElixir.LoopBreaker do
  @moduledoc """
  Pure loop-breaker decisions for repeated or impossible validation cycles.
  """

  alias SymphonyElixir.LoopBreaker.FailureSignature
  alias SymphonyElixir.LoopBreaker.RootCause

  @type decision :: %{
          required(:trigger) => atom(),
          required(:root_cause) => atom(),
          required(:evidence) => [map()],
          required(:proposed_amendment) => String.t(),
          required(:issue_transition) => map()
        }

  @type summary :: %{
          required(:failure_count) => non_neg_integer(),
          required(:phase_attempts) => map(),
          required(:signatures) => [String.t()]
        }

  @spec evaluate([map()]) :: {:continue, summary()} | {:break, decision()}
  def evaluate(events), do: evaluate(events, [])

  @spec evaluate([map()], keyword()) :: {:continue, summary()} | {:break, decision()}
  def evaluate(events, opts) when is_list(events) and is_list(opts) do
    validation_failures = Enum.filter(events, &validation_failure?/1)
    summary = failure_summary(events)

    case contradiction_decision(events, opts, summary) do
      {:continue, summary} ->
        case repeated_signature_decision(validation_failures, opts, summary) do
          {:continue, summary} -> phase_attempts_decision(validation_failures, opts, summary)
          {:break, decision} -> {:break, decision}
        end

      {:break, decision} ->
        {:break, decision}
    end
  end

  @spec failure_summary([map()]) :: summary()
  def failure_summary(events) when is_list(events) do
    validation_failures = Enum.filter(events, &validation_failure?/1)

    %{
      failure_count: length(validation_failures),
      phase_attempts: phase_attempts(validation_failures),
      signatures: Enum.map(validation_failures, &FailureSignature.from_event/1)
    }
  end

  defp contradiction_decision(events, opts, summary) do
    case Enum.find(events, &contradiction?/1) do
      nil ->
        {:continue, summary}

      event ->
        evidence = [contradiction_evidence(event)]
        {:break, decision(:validation_spec_contradiction, evidence, opts)}
    end
  end

  defp repeated_signature_decision(validation_failures, opts, summary) do
    evidence =
      validation_failures
      |> Enum.group_by(&FailureSignature.from_event/1)
      |> Enum.find_value(fn {_signature, failures} ->
        if length(failures) >= 2 do
          failures
          |> Enum.take(2)
          |> Enum.map(&FailureSignature.describe/1)
        end
      end)

    if evidence do
      {:break, decision(:repeated_failure_signature, evidence, opts)}
    else
      {:continue, summary}
    end
  end

  defp phase_attempts_decision(validation_failures, opts, summary) do
    evidence =
      validation_failures
      |> Enum.group_by(&field(&1, :phase, "unknown"))
      |> Enum.find_value(fn {_phase, failures} ->
        if length(failures) >= 3 do
          failures
          |> Enum.take(3)
          |> Enum.map(&FailureSignature.describe/1)
        end
      end)

    if evidence do
      {:break, decision(:phase_validation_attempts_exhausted, evidence, opts)}
    else
      {:continue, summary}
    end
  end

  defp decision(trigger, evidence, opts) do
    root_cause = RootCause.classify(trigger, evidence)
    amendment = proposed_amendment(trigger, root_cause)
    transition = issue_transition(trigger, root_cause, evidence, amendment, opts)

    %{
      trigger: trigger,
      root_cause: root_cause,
      evidence: evidence,
      proposed_amendment: amendment,
      issue_transition: transition
    }
  end

  defp issue_transition(trigger, root_cause, evidence, amendment, opts) do
    %{
      issue_identifier: Keyword.get(opts, :issue_identifier),
      status: "human-checkpoint",
      trigger: trigger,
      root_cause: root_cause,
      evidence: evidence,
      proposed_amendment: amendment,
      checkpoint_reason: "Loop breaker requires human approval before work continues."
    }
  end

  defp proposed_amendment(:validation_spec_contradiction, _root_cause) do
    "Resolve the contradiction between the validation command and the issue spec before resuming."
  end

  defp proposed_amendment(:repeated_failure_signature, _root_cause) do
    "Clarify or amend the validation requirement after reviewing the repeated failure signature."
  end

  defp proposed_amendment(:phase_validation_attempts_exhausted, _root_cause) do
    "Clarify or amend the phase validation plan after three failed attempts in the same phase."
  end

  defp proposed_amendment(_trigger, _root_cause) do
    "Clarify or amend the issue before resuming automation."
  end

  defp phase_attempts(validation_failures) do
    validation_failures
    |> Enum.group_by(&field(&1, :phase, "unknown"))
    |> Map.new(fn {phase, failures} -> {phase, length(failures)} end)
  end

  defp contradiction_evidence(event) do
    %{
      phase: field(event, :phase),
      validation: field(event, :validation),
      spec: field(event, :spec),
      reason: field(event, :reason)
    }
  end

  defp validation_failure?(event), do: field(event, :kind) == :validation_failure
  defp contradiction?(event), do: field(event, :kind) == :validation_spec_contradiction

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
