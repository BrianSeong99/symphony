defmodule SymphonyElixir.LinearRelayTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Relay

  test "normalizes Linear teams, projects, issues, comments, labels, relations, statuses, and attachments" do
    payload = %{
      "team" => %{"id" => "team-1", "key" => "HML", "name" => "Homelab"},
      "project" => %{"id" => "project-1", "name" => "Homelab", "slugId" => "homelab-02e0c66d1cb8"},
      "issue" => %{
        "id" => "issue-1",
        "identifier" => "HML-12",
        "title" => "Wire runtime console",
        "description" => "Runtime work",
        "url" => "https://linear.app/brian/issue/HML-12",
        "state" => %{"id" => "state-1", "name" => "In Progress"},
        "team" => %{"id" => "team-1", "key" => "HML", "name" => "Homelab"},
        "project" => %{"id" => "project-1", "name" => "Homelab", "slugId" => "homelab-02e0c66d1cb8"},
        "labels" => %{"nodes" => [%{"id" => "label-1", "name" => "symphony"}]},
        "comments" => %{"nodes" => [%{"id" => "comment-1", "body" => "Checkpoint?", "url" => "https://linear.comment"}]},
        "relations" => %{
          "nodes" => [
            %{"type" => "blocks", "issue" => %{"id" => "blocked-1", "identifier" => "HML-13"}}
          ]
        },
        "attachments" => %{
          "nodes" => [
            %{"id" => "attachment-1", "title" => "PR #42", "url" => "https://github.com/pr/42"}
          ]
        }
      }
    }

    context = Relay.normalize_read_models(payload)

    assert context.team.key == "HML"
    assert context.project.slug == "homelab-02e0c66d1cb8"
    assert context.issue.identifier == "HML-12"
    assert context.issue.status.name == "In Progress"
    assert context.issue.labels == [%{id: "label-1", name: "symphony"}]
    assert context.issue.comments == [%{id: "comment-1", body: "Checkpoint?", url: "https://linear.comment"}]
    assert context.issue.relations == [%{type: "blocks", issue_id: "blocked-1", issue_identifier: "HML-13"}]
    assert context.issue.attachments == [%{id: "attachment-1", title: "PR #42", url: "https://github.com/pr/42"}]
  end

  test "normalizes issue, comment, project, and status webhook events" do
    assert %{
             source: "linear",
             event_type: "issue.update",
             action: "update",
             entity_type: "issue",
             entity_id: "issue-1",
             project_id: "project-1",
             team_id: "team-1"
           } =
             Relay.normalize_webhook(%{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "issue-1",
                 "team" => %{"id" => "team-1"},
                 "project" => %{"id" => "project-1"}
               }
             })

    assert %{event_type: "comment.create", entity_type: "comment", issue_id: "issue-1"} =
             Relay.normalize_webhook(%{
               "type" => "Comment",
               "action" => "create",
               "data" => %{"id" => "comment-1", "issue" => %{"id" => "issue-1"}}
             })

    assert %{event_type: "project.update", entity_type: "project"} =
             Relay.normalize_webhook(%{"type" => "Project", "action" => "update", "data" => %{"id" => "project-1"}})

    assert %{event_type: "status.update", entity_type: "status"} =
             Relay.normalize_webhook(%{"type" => "WorkflowState", "action" => "update", "data" => %{"id" => "state-1"}})
  end

  test "capability probe records available and missing permissions" do
    probe =
      Relay.probe_capabilities(fn capability ->
        case capability do
          :read_issues -> :ok
          :write_comments -> {:error, :forbidden}
          :update_status -> :ok
          :read_projects -> :ok
          :read_teams -> :ok
          :write_attachments -> {:error, :forbidden}
        end
      end)

    assert probe.capabilities.read_issues == true
    assert probe.capabilities.update_status == true
    assert probe.capabilities.write_comments == false
    assert probe.missing_capabilities == [:write_comments, :write_attachments]
  end

  test "safe Linear writes execute and emit sync events" do
    result =
      Relay.execute_write(:run_summary, %{issue_id: "issue-1", body: "Run passed"}, performer: fn operation -> {:ok, %{linear_id: "comment-1", action: operation.action}} end)

    assert result.status == "success"
    assert result.operation.action == "run_summary"
    assert result.operation.mutation == "commentCreate"
    assert result.sync_event.provider == "linear"
    assert result.sync_event.status == "success"
  end

  test "public projection writes are refused unless policy allows them" do
    denied =
      Relay.execute_write(:public_projection, %{issue_id: "issue-1", body: "Public text"},
        policy: fn _operation -> {:block, :approval_required} end,
        performer: fn _operation -> flunk("performer should not run") end
      )

    assert denied.status == "skipped"
    assert denied.reason == :approval_required
    assert denied.sync_event.status == "skipped"

    allowed =
      Relay.execute_write(:public_projection, %{issue_id: "issue-1", body: "Public text"},
        policy: fn _operation -> {:allow, :approved} end,
        performer: fn _operation -> {:ok, %{linear_id: "comment-2"}} end
      )

    assert allowed.status == "success"
  end

  test "unsupported writes are skipped with an auditable reason" do
    result = Relay.execute_write(:delete_everything, %{issue_id: "issue-1"})

    assert result.status == "skipped"
    assert result.reason == {:unsupported_action, :delete_everything}
    assert result.sync_event.status == "skipped"
  end
end
