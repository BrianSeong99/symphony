defmodule SymphonyElixir.AgentSessionsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentSessions
  alias SymphonyElixir.AgentSessions.{AgentSession, BuilderRunner, ReviewerRunner}
  alias SymphonyElixir.Reviews.{ReviewFinding, ReviewFindings}

  test "agent session changeset validates durable builder and reviewer sessions" do
    builder_changeset =
      AgentSession.changeset(%AgentSession{}, %{
        symphony_issue_id: 123,
        role: "builder",
        backend: "claude_code",
        session_id: "builder:123",
        workspace_path: "/tmp/symphony-123",
        branch: "brian/add-feature"
      })

    reviewer_changeset =
      AgentSession.changeset(%AgentSession{}, %{
        symphony_issue_id: 123,
        role: "reviewer",
        backend: "codex",
        session_id: "reviewer:BrianSeong99/symphony#31",
        metadata: %{"pr_key" => "BrianSeong99/symphony#31"}
      })

    assert builder_changeset.valid?
    assert reviewer_changeset.valid?
  end

  test "builder runner creates one durable session per active Symphony issue" do
    parent = self()

    assert {:ok, result} =
             BuilderRunner.run(%{id: 123, title: "Build it"}, [],
               runner: fake_runner(parent),
               workspace_path: "/tmp/symphony-123",
               branch: "brian/build-it"
             )

    assert result.mode == :create
    assert result.session.role == "builder"
    assert result.session.backend == "claude_code"
    assert result.session.session_id == "builder:123"
    assert result.session.metadata["public_output_rules"] == AgentSessions.public_output_rules()

    assert_receive {:ran, %{mode: :create, backend: "claude_code", base_branch: "origin/main"}}
  end

  test "builder runner resumes existing session for retries, CI failures, and review feedback" do
    existing = %AgentSession{
      symphony_issue_id: 123,
      role: "builder",
      backend: "claude_code",
      session_id: "builder:123",
      status: "active",
      metadata: %{"attempts" => 1}
    }

    assert {:ok, result} =
             BuilderRunner.run(%{id: 123, title: "Retry it"}, [existing],
               runner: fake_runner(self()),
               reason: :ci_failure
             )

    assert result.mode == :resume
    assert result.session.session_id == existing.session_id
    assert result.session.metadata["resume_reason"] == "ci_failure"
  end

  test "builder runner rejects non-main branch bases" do
    assert {:error, {:invalid_base_branch, "brian/previous-feature"}} =
             BuilderRunner.run(%{id: 123}, [], base_branch: "brian/previous-feature")
  end

  test "active sessions rehydrate after restart and terminal issues destroy sessions" do
    active = %AgentSession{symphony_issue_id: 123, role: "builder", session_id: "builder:123", status: "active"}
    destroyed = %AgentSession{symphony_issue_id: 124, role: "builder", session_id: "builder:124", status: "destroyed"}

    assert AgentSessions.rehydrate_active_sessions([destroyed, active]) == [active]

    assert [%AgentSession{status: "destroyed", destroy_reason: "issue done"}] =
             AgentSessions.destroy_issue_sessions([active], "done")
  end

  test "reviewer runner keeps one PR-scoped Codex reviewer context and resumes after updates" do
    parent = self()
    pr = %{symphony_issue_id: 123, owner: "BrianSeong99", repo: "symphony", number: 31, state: "open"}

    assert {:ok, first} = ReviewerRunner.run(pr, [], runner: fake_runner(parent))
    assert first.mode == :create
    assert first.session.role == "reviewer"
    assert first.session.backend == "codex"
    assert first.session.metadata["pr_key"] == "BrianSeong99/symphony#31"

    assert {:ok, second} = ReviewerRunner.run(pr, [first.session], runner: fake_runner(parent))
    assert second.mode == :resume
    assert second.session.session_id == first.session.session_id
  end

  test "review findings track open, resolved, accepted, and false-positive states" do
    finding = %ReviewFinding{
      symphony_issue_id: 123,
      state: "open",
      severity: "high",
      title: "Missing validation"
    }

    assert {:ok, resolved} = ReviewFindings.transition(finding, "resolved", evidence: "test added")
    assert resolved.state == "resolved"
    assert resolved.metadata["evidence"] == "test added"

    assert {:ok, accepted} = ReviewFindings.transition(resolved, "accepted", reason: "intentional")
    assert accepted.state == "accepted"

    assert {:ok, false_positive} = ReviewFindings.transition(accepted, "false_positive", reason: "not applicable")
    assert false_positive.state == "false_positive"
  end

  test "reviewer contexts are destroyed after PR merge or close" do
    reviewer = %AgentSession{
      symphony_issue_id: 123,
      role: "reviewer",
      session_id: "reviewer:BrianSeong99/symphony#31",
      status: "active",
      metadata: %{"pr_key" => "BrianSeong99/symphony#31"}
    }

    assert [%AgentSession{status: "destroyed", destroy_reason: "pr merged"}] =
             AgentSessions.destroy_pr_sessions([reviewer], "merged")

    assert [%AgentSession{status: "destroyed", destroy_reason: "pr closed"}] =
             AgentSessions.destroy_pr_sessions([reviewer], "closed")
  end

  defp fake_runner(parent) do
    fn command ->
      send(parent, {:ran, command})
      {:ok, %{exit_status: 0}}
    end
  end
end
