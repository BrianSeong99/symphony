defmodule SymphonyElixir.Reviews.ReviewLoopTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentSessions.AgentSession
  alias SymphonyElixir.Reviews.{ReviewFinding, ReviewLoop}

  test "ingests PR comments, inline comments, review summaries, and failed checks" do
    findings =
      ReviewLoop.ingest_feedback(123, [
        %{type: :comment, body: "Please add a migration test", url: "https://github.test/comment/1"},
        %{type: :inline_comment, body: "This branch can be nil", path: "lib/app.ex", line: 42},
        %{type: :review_summary, body: "Blocking until validation is documented"},
        %{type: :check_failure, name: "mix test", body: "1 failure", conclusion: "failure"}
      ])

    assert Enum.map(findings, & &1.title) == [
             "PR comment requires follow-up",
             "Inline review comment requires follow-up",
             "Review summary requires follow-up",
             "Check failed: mix test"
           ]

    assert Enum.all?(findings, &(&1.state == "open"))
    assert Enum.at(findings, 1).metadata["path"] == "lib/app.ex"
    assert Enum.at(findings, 3).severity == "high"
  end

  test "builder receives actionable repair work from reviewer findings" do
    findings = [
      finding("Add validation test", "test missing"),
      finding("Document tradeoff", "explain why")
    ]

    repair_issue = ReviewLoop.repair_issue(%{id: 123, title: "Original issue"}, findings)

    assert repair_issue.metadata["repair_items"] == [
             %{"title" => "Add validation test", "body" => "test missing", "source_url" => nil},
             %{"title" => "Document tradeoff", "body" => "explain why", "source_url" => nil}
           ]
  end

  test "feedback to fix to validation to handoff loop resolves findings after validation passes" do
    parent = self()
    builder_session = %AgentSession{symphony_issue_id: 123, role: "builder", session_id: "builder:123", status: "active"}

    result =
      ReviewLoop.run_cycle(
        %{id: 123, title: "Review loop"},
        [%{type: :check_failure, name: "mix test", body: "test failed"}],
        [builder_session],
        builder_runner: fn repair_issue, sessions ->
          send(parent, {:builder_received, repair_issue.metadata["repair_items"], sessions})
          {:ok, %{commit: "abc123"}}
        end,
        validation_runner: fn repair_issue, builder_result ->
          send(parent, {:validation_reran, repair_issue.id, builder_result.commit})
          {:ok, %{status: "passed", evidence: "mix test passed"}}
        end
      )

    assert result.status == "human_review_ready"
    assert Enum.map(result.findings, & &1.state) == ["resolved"]
    assert result.validation.evidence == "mix test passed"

    assert_receive {:builder_received, [%{"title" => "Check failed: mix test"}], [^builder_session]}
    assert_receive {:validation_reran, 123, "abc123"}
  end

  test "issue cannot move to human review while actionable findings remain open" do
    findings = [
      finding("Open bug", "needs fix"),
      %ReviewFinding{symphony_issue_id: 123, state: "accepted", severity: "medium", title: "Accepted tradeoff"}
    ]

    assert %{status: "repair_required", open_findings: [open]} =
             ReviewLoop.handoff_decision(findings, %{status: "passed"})

    assert open.title == "Open bug"
  end

  test "failed validation keeps the issue in repair after builder work" do
    result =
      ReviewLoop.run_cycle(
        %{id: 123, title: "Review loop"},
        [%{type: :comment, body: "Fix this"}],
        [],
        builder_runner: fn _repair_issue, _sessions -> {:ok, %{commit: "abc123"}} end,
        validation_runner: fn _repair_issue, _builder_result ->
          {:ok, %{status: "failed", evidence: "mix test failed"}}
        end
      )

    assert result.status == "repair_required"
    assert [%ReviewFinding{state: "open"}] = result.findings
    assert result.validation.evidence == "mix test failed"
  end

  test "loop breaker sends repeated validation failures to human checkpoint" do
    result =
      ReviewLoop.run_cycle(
        %{id: 123, title: "Review loop"},
        [%{type: :comment, body: "Fix this"}],
        [],
        loop_events: [
          validation_failure(attempt: 1, command: "mix test", output: "same failure"),
          validation_failure(attempt: 2, command: "mix test", output: "same failure")
        ],
        builder_runner: fn _repair_issue, _sessions -> {:ok, %{commit: "abc123"}} end,
        validation_runner: fn _repair_issue, _builder_result ->
          {:ok, %{status: "failed", evidence: "same failure"}}
        end
      )

    assert result.status == "human-checkpoint"
    assert result.loop_breaker.trigger == :repeated_failure_signature
    assert result.issue_transition.status == "human-checkpoint"
  end

  test "validation/spec contradiction stops before builder repair work" do
    result =
      ReviewLoop.run_cycle(
        %{id: 123, title: "Review loop"},
        [%{type: :comment, body: "Fix this"}],
        [],
        loop_events: [
          %{
            kind: :validation_spec_contradiction,
            phase: "validation",
            validation: "mix test --exclude live_e2e",
            spec: "Run live worker test",
            reason: "Validation excludes required live worker test"
          }
        ],
        builder_runner: fn _repair_issue, _sessions -> flunk("builder should not run") end
      )

    assert result.status == "human-checkpoint"
    assert result.loop_breaker.root_cause == :spec_validation_contradiction
    assert result.issue_transition.proposed_amendment =~ "Resolve the contradiction"
  end

  defp finding(title, body) do
    %ReviewFinding{
      symphony_issue_id: 123,
      state: "open",
      severity: "medium",
      title: title,
      body: body
    }
  end

  defp validation_failure(attrs) do
    attrs
    |> Keyword.put_new(:kind, :validation_failure)
    |> Keyword.put_new(:phase, "validation")
    |> Map.new()
  end
end
