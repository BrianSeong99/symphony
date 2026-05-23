defmodule SymphonyElixir.Projects.PublicRepoPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Projects.{Project, ProjectConnection, PublicRepoPolicy}

  @mutating_actions [
    :create_label,
    :create_milestone,
    :sync_workpad_comment,
    :edit_issue_body,
    :public_comment
  ]

  test "Miden blocks public Symphony metadata mutations by default" do
    project = project("miden")

    connection =
      github_connection("pr_only",
        capabilities: all_github_capabilities(),
        settings: %{"public_repo" => true}
      )

    for action <- @mutating_actions do
      assert {:block, reason} = PublicRepoPolicy.evaluate(action, project, connection)
      assert reason in PublicRepoPolicy.miden_block_reasons()
    end
  end

  test "Miden allows PR association only when explicitly linked" do
    project = project("miden")
    connection = github_connection("pr_only", capabilities: all_github_capabilities())

    assert {:block, :explicit_pr_association_required} =
             PublicRepoPolicy.evaluate(:associate_pr, project, connection)

    assert {:allow, :explicit_pr_association} =
             PublicRepoPolicy.evaluate(:associate_pr, project, connection, explicit_pr_association: true)
  end

  test "Miden allows public comments only with explicit approval" do
    project = project("miden")
    connection = github_connection("pr_only", capabilities: all_github_capabilities())

    assert {:block, :miden_public_comments_require_approval} =
             PublicRepoPolicy.evaluate(:public_comment, project, connection)

    assert {:allow, :explicit_public_comment} =
             PublicRepoPolicy.evaluate(:public_comment, project, connection, explicit_public_comment: true)
  end

  test "Miden blocks PR association when connection mode does not support PRs" do
    project = project("miden")
    connection = github_connection("context_only", capabilities: all_github_capabilities())

    assert {:block, :connection_mode_does_not_support_prs} =
             PublicRepoPolicy.evaluate(:associate_pr, project, connection, explicit_pr_association: true)
  end

  test "full-sync Homelab allows GitHub mutations when capabilities exist" do
    project = project("labs")
    connection = github_connection("full_sync", capabilities: all_github_capabilities())

    for action <- @mutating_actions ++ [:associate_pr] do
      assert {:allow, :capability_present} = PublicRepoPolicy.evaluate(action, project, connection)
    end
  end

  test "full-sync personal project blocks GitHub mutations when capability is missing" do
    project = project("personal")
    connection = github_connection("full_sync", capabilities: %{"create_labels" => false})

    assert {:block, {:missing_capability, "create_labels"}} =
             PublicRepoPolicy.evaluate(:create_label, project, connection)
  end

  test "non-full-sync projects block issue metadata mutations outside Miden too" do
    project = project("chainless")
    connection = github_connection("pr_only", capabilities: all_github_capabilities())

    assert {:block, :connection_mode_does_not_support_issue_mutation} =
             PublicRepoPolicy.evaluate(:edit_issue_body, project, connection)
  end

  defp project(workspace) do
    %Project{name: "#{workspace} project", slug: "#{workspace}-project", workspace: workspace}
  end

  defp github_connection(mode, opts) do
    %ProjectConnection{
      provider: "github",
      connection_mode: mode,
      owner: "BrianSeong99",
      repo: "symphony",
      status: "active",
      capabilities: Keyword.fetch!(opts, :capabilities),
      settings: Keyword.get(opts, :settings, %{})
    }
  end

  defp all_github_capabilities do
    %{
      "create_labels" => true,
      "edit_milestones" => true,
      "comment" => true,
      "edit_issues" => true,
      "create_prs" => true,
      "read_prs" => true
    }
  end
end
