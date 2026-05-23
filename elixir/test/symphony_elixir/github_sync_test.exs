defmodule SymphonyElixir.GitHubSyncTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubSync
  alias SymphonyElixir.GitHubSync.{IssueExternalLink, PullRequestExternalLink, SyncEvent}
  alias SymphonyElixir.Projects.{Project, ProjectConnection}
  alias SymphonyElixir.Repositories.Repository

  test "repository changeset validates GitHub repository identity" do
    changeset =
      Repository.changeset(%Repository{}, %{
        project_id: 123,
        provider: "github",
        owner: "BrianSeong99",
        name: "homelab",
        default_branch: "main",
        visibility: "private",
        url: "https://github.com/BrianSeong99/homelab"
      })

    assert changeset.valid?

    repository = Ecto.Changeset.apply_action!(changeset, :insert)
    assert repository.provider == "github"
    assert repository.default_branch == "main"
  end

  test "external link changesets cover GitHub issues, PRs, checks, comments, reviews, and milestones" do
    for link_type <- ~w(github_issue github_pr github_check github_comment github_review github_milestone) do
      changeset =
        IssueExternalLink.changeset(%IssueExternalLink{}, %{
          symphony_issue_id: 456,
          provider: "github",
          link_type: link_type,
          association_strength: "context",
          external_id: "#{link_type}-1",
          url: "https://github.com/BrianSeong99/symphony/#{link_type}/1"
        })

      assert changeset.valid?
    end
  end

  test "pull request link and sync event changesets validate downstream audit state" do
    pr_changeset =
      PullRequestExternalLink.changeset(%PullRequestExternalLink{}, %{
        symphony_issue_id: 456,
        repository_id: 789,
        provider: "github",
        external_id: "PR_kwDO",
        number: 29,
        url: "https://github.com/BrianSeong99/symphony/pull/29",
        branch: "brian/dependency-graph",
        status: "merged"
      })

    sync_event_changeset =
      SyncEvent.changeset(%SyncEvent{}, %{
        project_id: 123,
        symphony_issue_id: 456,
        provider: "github",
        action: "sync_issue",
        status: "success",
        request: %{"title" => "Issue"},
        response: %{"number" => 8}
      })

    assert pr_changeset.valid?
    assert sync_event_changeset.valid?
  end

  test "context-only mode stores associations and performs no GitHub mutations" do
    connection = connection("context_only", %{"read_repo" => true})

    plan =
      GitHubSync.plan(connection, %{
        github_issue_url: "https://github.com/BrianSeong99/symphony/issues/8",
        github_pr_url: "https://github.com/BrianSeong99/symphony/pull/29",
        github_milestone_url: "https://github.com/BrianSeong99/symphony/milestone/1"
      })

    assert Enum.map(plan.associations, & &1.link_type) == [
             "github_repo",
             "github_issue",
             "github_pr",
             "github_milestone"
           ]

    assert plan.operations == []

    result = GitHubSync.execute(connection, %{symphony_issue_id: 456}, performer: performer(self()))
    assert result.performed == []
    assert result.sync_events == []
    refute_received {:performed, _operation}
  end

  test "pr-only mode associates PRs and ingests checks and reviews without issue mutation" do
    connection = connection("pr_only", %{"read_checks" => true, "read_reviews" => true})

    result =
      GitHubSync.execute(connection, %{symphony_issue_id: 456, github_pr_number: 29}, performer: performer(self()))

    assert Enum.map(result.plan.associations, & &1.link_type) == ["github_repo", "github_pr"]
    assert Enum.map(result.plan.operations, & &1.action) == ["ingest_checks", "ingest_reviews"]
    assert Enum.all?(result.plan.operations, &(&1.kind == :ingestion))
    assert Enum.map(result.performed, & &1.action) == ["ingest_checks", "ingest_reviews"]
    assert Enum.map(result.sync_events, & &1.status) == ["success", "success"]
    assert_receive {:performed, %{action: "ingest_checks"}}
    assert_receive {:performed, %{action: "ingest_reviews"}}
  end

  test "issue-mirror mode mirrors selected local issues and includes dependency summary" do
    connection = connection("issue_mirror", %{"create_issues" => true})

    plan =
      GitHubSync.plan(connection, %{
        title: "Implement GitHub association and sync layer",
        body: "Local issue body",
        dependency_summary: "Blocks: none"
      })

    assert [%{action: "sync_issue", request: request}] = plan.operations
    assert request.body =~ "Local issue body"
    assert request.body =~ "Blocks: none"
  end

  test "full-sync mode plans issues, labels, milestones, workpad comments, PR links, checks, and reviews" do
    connection =
      connection("full_sync", %{
        "create_issues" => true,
        "create_labels" => true,
        "edit_milestones" => true,
        "comment" => true,
        "read_checks" => true,
        "read_reviews" => true
      })

    plan =
      GitHubSync.plan(connection, %{
        symphony_issue_id: 456,
        title: "Full sync issue",
        labels: ["symphony", "phase:integration"],
        milestone_title: "Dashboard-first orchestration v1",
        workpad_body: "Planning notes",
        github_pr_number: 29
      })

    assert Enum.map(plan.operations, & &1.action) == [
             "sync_issue",
             "sync_labels",
             "sync_milestone",
             "sync_workpad_comment",
             "sync_pr_link",
             "sync_review_state",
             "ingest_checks",
             "ingest_reviews"
           ]
  end

  test "permission-limited full sync skips forbidden mutations and surfaces capability issues" do
    connection =
      connection("full_sync", %{
        "create_issues" => true,
        "create_labels" => false,
        "edit_milestones" => false,
        "comment" => false,
        "read_checks" => true,
        "read_reviews" => true
      })

    result =
      GitHubSync.execute(connection, %{symphony_issue_id: 456, title: "Limited"}, performer: performer(self()))

    assert Enum.map(result.performed, & &1.action) == ["sync_issue", "ingest_checks", "ingest_reviews"]

    assert Enum.map(result.capability_issues, & &1.action) == [
             "sync_labels",
             "sync_milestone",
             "sync_workpad_comment",
             "sync_pr_link",
             "sync_review_state"
           ]

    skipped_events = Enum.filter(result.sync_events, &(&1.status == "skipped"))
    assert length(skipped_events) == 5
    refute_received {:performed, %{action: "sync_labels"}}
  end

  test "every attempted downstream mutation records a sync event" do
    connection =
      connection("full_sync", %{
        "create_issues" => true,
        "create_labels" => true,
        "edit_milestones" => true,
        "comment" => true,
        "read_checks" => true,
        "read_reviews" => true
      })

    result =
      GitHubSync.execute(connection, %{symphony_issue_id: 456, title: "Audit"}, performer: performer(self()))

    mutation_actions =
      result.plan.operations
      |> Enum.filter(&(&1.kind == :mutation))
      |> Enum.map(& &1.action)

    assert result.sync_events |> Enum.filter(&(&1.kind == :mutation)) |> Enum.map(& &1.action) ==
             mutation_actions
  end

  test "Miden project policy blocks public issue metadata sync while still allowing ingestion" do
    project = %Project{name: "Miden", slug: "miden", workspace: "miden"}

    connection =
      connection("full_sync", %{
        "create_issues" => true,
        "edit_issues" => true,
        "create_labels" => true,
        "edit_milestones" => true,
        "comment" => true,
        "read_checks" => true,
        "read_reviews" => true
      })

    result =
      GitHubSync.execute(
        connection,
        %{project: project, symphony_issue_id: 456, title: "Miden public issue", github_pr_number: 29},
        performer: performer(self())
      )

    assert Enum.map(result.performed, & &1.action) == ["ingest_checks", "ingest_reviews"]
    assert Enum.any?(result.capability_issues, &(&1.reason == :miden_issue_body_rewrites_disabled))
    assert Enum.any?(result.capability_issues, &(&1.reason == :miden_public_labels_disabled))
  end

  test "issue-mirror mode can sync issue bodies for owned projects when edit capability exists" do
    project = %Project{name: "Homelab", slug: "homelab", workspace: "labs"}

    connection =
      connection("issue_mirror", %{
        "create_issues" => true,
        "edit_issues" => true
      })

    result =
      GitHubSync.execute(
        connection,
        %{project: project, symphony_issue_id: 456, title: "Mirror issue"},
        performer: performer(self())
      )

    assert Enum.map(result.performed, & &1.action) == ["sync_issue"]
    assert result.capability_issues == []
  end

  defp connection(mode, capabilities) do
    %ProjectConnection{
      provider: "github",
      connection_mode: mode,
      owner: "BrianSeong99",
      repo: "symphony",
      status: "active",
      capabilities: capabilities
    }
  end

  defp performer(parent) do
    fn operation ->
      send(parent, {:performed, operation})
      {:ok, %{"ok" => true, "action" => operation.action}}
    end
  end
end
