defmodule SymphonyElixir.Learning.SelfImprovementTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Learning.SelfImprovement

  test "creates issue proposals with evidence, validation, dependency edges, and sync policy" do
    review =
      SelfImprovement.review(
        [
          %{
            source: "failed_validation",
            title: "Coverage gate drifted from handoff reality",
            risk_area: "tests",
            evidence: ["make all failed at coverage threshold"],
            depends_on: ["#63"],
            public_sync_policy: "linear_safe_summary_only"
          }
        ],
        runner_proven?: true
      )

    assert review.mode == :dry_run
    assert review.digest =~ "1 proposal"
    assert [proposal] = review.proposals
    assert proposal.title == "Learning: Coverage gate drifted from handoff reality [tests]"
    assert proposal.issue_type == "test-validation"
    assert proposal.risk == "low"
    assert proposal.auto_work_allowed
    assert proposal.source_signal.source == "failed_validation"
    assert proposal.source_signal.evidence == ["make all failed at coverage threshold"]
    assert [%{depends_on: "#63", dependency_policy: "all_done"}] = proposal.dependency_edges
    assert proposal.public_sync_policy == "linear_safe_summary_only"
    assert Enum.any?(proposal.acceptance_criteria, &String.contains?(&1, "Validation commands"))
    assert "mix test" in proposal.validation_commands
  end

  test "deduplicates proposals against existing open or closed issues" do
    review =
      SelfImprovement.review(
        [
          %{
            title: "Coverage gate drifted from handoff reality",
            risk_area: "tests"
          }
        ],
        existing_issues: [
          %{"title" => "Learning: Coverage gate drifted from handoff reality [tests]"}
        ]
      )

    assert review.proposals == []
    assert length(review.duplicates) == 1
  end

  test "hard safety policy proposals cannot auto-weaken gates" do
    review =
      SelfImprovement.review(
        [
          %{
            source: "user_instruction",
            title: "Disable public sync approvals",
            risk_area: "public_sync_policy",
            evidence: ["operator correction touched public sync policy"]
          }
        ],
        runner_proven?: true
      )

    assert [proposal] = review.proposals
    refute proposal.auto_work_allowed
    assert proposal.risk == "critical"
    assert proposal.public_sync_policy == "private_only_until_human_approval"
    assert "manual approval checkpoint" in proposal.validation_commands
    assert Enum.any?(proposal.checkpoint_requirements, &String.contains?(&1, "Human approval required"))
  end

  test "dry run renders JSON without writing issues" do
    json =
      SelfImprovement.dry_run_json([
        %{title: "Repeated runner retry loop", risk_area: "observability", evidence: ["attempt=14"]}
      ])

    assert {:ok, decoded} = Jason.decode(json)
    assert get_in(decoded, ["mode"]) == "dry_run"

    assert get_in(decoded, ["proposals", Access.at(0), "title"]) ==
             "Learning: Repeated runner retry loop [observability]"
  end

  test "write mode delegates proposal persistence without mutating policy directly" do
    review =
      SelfImprovement.review(
        [%{title: "Morning digest needs stale-state signal", risk_area: "observability"}],
        write?: true,
        issue_writer: fn proposal -> {:ok, %{id: "local:1", title: proposal.title}} end
      )

    assert [proposal] = review.proposals
    assert proposal.written == %{id: "local:1", title: "Learning: Morning digest needs stale-state signal [observability]"}
  end
end
