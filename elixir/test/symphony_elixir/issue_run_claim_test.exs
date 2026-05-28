defmodule SymphonyElixir.IssueRunClaimTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueRunClaim

  test "reacquiring a stale issue claim preserves the existing Codex and Claude session identities" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-run-claim-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      issue = %Issue{id: "115", identifier: "GH-115", title: "Fix process page", state: "Todo"}
      path = IssueRunClaim.claim_path(issue.id)
      File.mkdir_p!(path)

      File.write!(
        Path.join(path, "claim.json"),
        Jason.encode!(%{
          "issue_id" => "115",
          "identifier" => "GH-115",
          "host" => current_host(),
          "os_pid" => "999999",
          "beam_pid" => "<0.999.0>",
          "codex_thread_id" => "thread-existing",
          "codex_thread_name" => "GH-115 Symphony Reviewer",
          "claude_session_id" => "builder:115",
          "claude_session_name" => "GH-115 Symphony Builder",
          "session_id" => "thread-existing-turn-old"
        })
      )

      assert {:ok, claim} =
               IssueRunClaim.acquire(issue, %{
                 codex_thread_name: "GH-115 Symphony Reviewer",
                 claude_session_id: "builder:115",
                 claude_session_name: "GH-115 Symphony Builder"
               })

      assert claim["resume_thread_id"] == "thread-existing"
      assert claim["previous_session_id"] == "thread-existing-turn-old"
      assert claim["codex_thread_name"] == "GH-115 Symphony Reviewer"
      assert claim["claude_session_id"] == "builder:115"
      assert claim["claude_session_name"] == "GH-115 Symphony Builder"
      assert IssueRunClaim.active_claim?(issue.id)

      IssueRunClaim.release(issue.id, "pr merged")

      refute File.exists?(Path.join(path, "claim.json"))
      assert [_archive] = Path.wildcard(Path.join(workspace_root, ".symphony/issue-runs/archive/*.json"))
    after
      File.rm_rf(workspace_root)
    end
  end

  defp current_host do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "unknown"
    end
  end
end
