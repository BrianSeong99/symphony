defmodule SymphonyElixir.LoopBreakerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.LoopBreaker
  alias SymphonyElixir.LoopBreaker.FailureSignature

  test "same failure signature twice triggers loop breaker" do
    first =
      validation_failure(
        attempt: 1,
        phase: "validation",
        command: "mix test",
        output: """
        1) test checkout totals (CartTest)
           Assertion with == failed
        """
      )

    second =
      validation_failure(
        attempt: 2,
        phase: "validation",
        command: "mix test",
        output: """
        1) test checkout totals (CartTest)
           Assertion with == failed
        """
      )

    assert FailureSignature.from_event(first) == FailureSignature.from_event(second)

    assert {:break, decision} = LoopBreaker.evaluate([first, second], issue_identifier: "SYM-14")
    assert decision.trigger == :repeated_failure_signature
    assert decision.root_cause == :deterministic_validation_failure
    assert decision.issue_transition.status == "human-checkpoint"
    assert decision.issue_transition.issue_identifier == "SYM-14"
    assert hd(decision.evidence).signature == FailureSignature.from_event(first)
    assert decision.proposed_amendment =~ "Clarify or amend the validation requirement"
  end

  test "three failed validation attempts in one phase triggers loop breaker" do
    events = [
      validation_failure(attempt: 1, phase: "review", command: "mix test", output: "first failure"),
      validation_failure(attempt: 2, phase: "review", command: "mix lint", output: "second failure"),
      validation_failure(attempt: 3, phase: "review", command: "mix format --check-formatted", output: "third failure")
    ]

    assert {:break, decision} = LoopBreaker.evaluate(events, issue_identifier: "SYM-14")
    assert decision.trigger == :phase_validation_attempts_exhausted
    assert decision.root_cause == :validation_phase_exhausted
    assert decision.evidence |> Enum.map(& &1.attempt) == [1, 2, 3]
    assert decision.issue_transition.evidence == decision.evidence
  end

  test "validation and spec contradictions trigger loop breaker with contradiction root cause" do
    contradiction = %{
      kind: :validation_spec_contradiction,
      phase: "validation",
      validation: "mix test --exclude live_e2e",
      spec: "Integration test confirms live worker stops until approved.",
      reason: "Requested validation excludes the only live worker integration test."
    }

    assert {:break, decision} = LoopBreaker.evaluate([contradiction], issue_identifier: "SYM-14")
    assert decision.trigger == :validation_spec_contradiction
    assert decision.root_cause == :spec_validation_contradiction
    assert [%{reason: "Requested validation excludes the only live worker integration test."}] = decision.evidence
    assert decision.proposed_amendment =~ "Resolve the contradiction"
  end

  test "non-threshold failures continue with signatures and phase attempt counts" do
    event = validation_failure(attempt: 1, phase: "validation", command: "mix test", output: "one failure")

    assert {:continue, summary} = LoopBreaker.evaluate([event])
    assert summary.failure_count == 1
    assert summary.phase_attempts == %{"validation" => 1}
    assert summary.signatures == [FailureSignature.from_event(event)]
  end

  defp validation_failure(attrs) do
    attrs
    |> Keyword.put_new(:kind, :validation_failure)
    |> Map.new()
  end
end
