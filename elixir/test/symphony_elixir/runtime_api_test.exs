defmodule SymphonyElixir.RuntimeApiTest do
  use ExUnit.Case

  import Phoenix.ConnTest

  alias SymphonyElixir.{AuditEvent, RuntimeConsole.Api}

  @endpoint SymphonyElixirWeb.Endpoint

  test "runtime console API exposes local health, projects, policies, and runtime resources" do
    start_test_endpoint(
      runtime_console_state: %{
        issues: [%{id: 17, title: "Runtime API", linear_url: "https://linear.app/example"}],
        milestones: [%{id: 1, title: "Linear cockpit + Symphony kernel v1"}],
        dependencies: [%{issue_id: 17, depends_on: [34, 36]}],
        checkpoints: [%{issue_id: 17, status: "pending"}],
        runs: [%{issue_id: 17, status: "running"}],
        agents: [%{issue_id: 17, role: "builder", status: "active"}],
        reviews: [%{issue_id: 17, status: "repair_required"}],
        relay_events: [%{provider: "linear", action: "webhook", status: "received"}]
      }
    )

    assert %{"source_of_truth" => "symphony", "status" => "ok", "counts" => %{"issues" => 1}} =
             json_response(get(build_conn(), "/api/v1/runtime/health"), 200)

    projects = json_response(get(build_conn(), "/api/v1/runtime/projects"), 200)
    assert projects["source_of_truth"] == "symphony"
    assert Enum.any?(projects["projects"], &(&1["key"] == "homelab" and &1["sync_profile"] == "native-full-sync"))
    assert Enum.any?(projects["projects"], &(&1["key"] == "symphony" and &1["homelab_workspace_id"] == "labs"))
    assert Enum.any?(projects["projects"], &(&1["key"] == "homelab" and &1["github_issues_sync"] == "disabled"))

    policies = json_response(get(build_conn(), "/api/v1/runtime/policies"), 200)
    assert "miden" in policies["field_profiles"]
    assert "homelab" in policies["projection_templates"]

    for resource <- ~w(issues milestones dependencies checkpoints runs agents reviews) do
      payload = json_response(get(build_conn(), "/api/v1/runtime/#{resource}"), 200)

      assert payload["source_of_truth"] == "symphony"
      assert payload["resource"] == resource
      assert payload["count"] == 1
    end

    relay = json_response(get(build_conn(), "/api/v1/runtime/relay/events"), 200)
    assert relay["items"] == [%{"provider" => "linear", "action" => "webhook", "status" => "received"}]
  end

  test "runtime API normalizes Linear webhooks into Symphony relay events" do
    start_test_endpoint(runtime_console_state: %{})

    payload =
      post(build_conn(), "/api/v1/linear/webhooks", %{
        "type" => "Issue",
        "action" => "update",
        "data" => %{
          "id" => "issue-1",
          "team" => %{"id" => "team-1"},
          "project" => %{"id" => "project-1"}
        }
      })
      |> json_response(202)

    assert payload["source_of_truth"] == "symphony"
    assert payload["mutation_performed"] == false
    assert payload["event"]["event_type"] == "issue.update"
    assert payload["event"]["entity_id"] == "issue-1"
    assert payload["audit_event"]["action"] == "linear.webhook_received"
  end

  test "runtime API previews public projection policy without mutating GitHub or Linear" do
    start_test_endpoint(runtime_console_state: %{})

    allowed =
      post(build_conn(), "/api/v1/runtime/projection-preview", %{
        "template" => "miden",
        "surface" => "github_comment",
        "values" => %{"public_comments" => "Public-safe Miden update"},
        "approvals" => ["public_comments"],
        "capabilities" => %{"comment" => true}
      })
      |> json_response(200)

    assert allowed["mutation_performed"] == false
    assert allowed["preview"]["allowed"] == %{"public_comments" => "Public-safe Miden update"}

    rejected =
      post(build_conn(), "/api/v1/runtime/projection-preview", %{
        "template" => "miden",
        "surface" => "github_comment",
        "values" => %{"planning_notes" => "private strategy"},
        "approvals" => ["planning_notes"],
        "capabilities" => %{"comment" => true}
      })
      |> json_response(200)

    assert rejected["preview"]["allowed"] == %{}
    assert rejected["preview"]["redacted"] == %{}
    assert rejected["audit_event"]["action"] == "projection.preview"
  end

  test "runtime API module emits AuditEvent-compatible preview and webhook events" do
    preview = Api.projection_preview(%{template: :homelab, surface: :github_issue, values: %{title: "Runtime API"}})
    webhook = Api.linear_webhook(%{"type" => "Project", "action" => "update", "data" => %{"id" => "project-1"}})

    assert AuditEvent.changeset(%AuditEvent{}, preview.audit_event).valid?
    assert AuditEvent.changeset(%AuditEvent{}, webhook.audit_event).valid?
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
