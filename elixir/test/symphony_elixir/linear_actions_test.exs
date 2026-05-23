defmodule SymphonyElixir.LinearActionsTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.{AuditEvent, Linear.Actions}

  @endpoint SymphonyElixirWeb.Endpoint
  @headers [{"x-symphony-linear-action-token", "secret"}]

  test "runtime actions are authenticated, validated, mapped to runner commands, and audited" do
    for action <- ~w(start_run pause_run resume_run) do
      assert {:ok, result} =
               Actions.handle(
                 %{"action" => action, "issue_id" => "SYM-39"},
                 token: "secret",
                 headers: @headers,
                 runner: runner(self())
               )

      assert result.status == "accepted"
      assert result.action == action
      assert result.summary == "#{action} accepted for issue SYM-39"
      assert AuditEvent.changeset(%AuditEvent{}, result.audit_event).valid?
      assert_receive {:runner_called, ^action, %{issue_id: "SYM-39"}}
    end
  end

  test "rejects invalid tokens and invalid payloads with exact local reasons" do
    assert {:error, unauthorized} =
             Actions.handle(%{"action" => "start_run", "issue_id" => "SYM-39"},
               token: "secret",
               headers: [{"x-symphony-linear-action-token", "wrong"}]
             )

    assert unauthorized.status == "rejected"
    assert unauthorized.reason == :invalid_action_token
    assert unauthorized.http_status == 401
    assert AuditEvent.changeset(%AuditEvent{}, unauthorized.audit_event).valid?

    assert {:error, invalid} =
             Actions.handle(%{"action" => "approve_spec_amendment", "issue_id" => "SYM-39"},
               token: "secret",
               headers: @headers
             )

    assert invalid.reason == {:missing_required_fields, [:project_id, :amendment]}
    assert invalid.http_status == 400
  end

  test "public comment approvals require issue and project context plus policy preview" do
    assert {:ok, allowed} =
             Actions.handle(
               %{
                 "action" => "approve_public_comment",
                 "issue_id" => "SYM-39",
                 "project_id" => 1,
                 "template" => "miden",
                 "surface" => "github_comment",
                 "target_field" => "public_comments",
                 "value" => "Public-safe update"
               },
               token: "secret",
               headers: @headers,
               capabilities: %{"comment" => true}
             )

    assert allowed.status == "accepted"
    assert allowed.policy.allowed.public_comments == "Public-safe update"

    assert {:error, rejected} =
             Actions.handle(
               %{
                 "action" => "approve_public_comment",
                 "issue_id" => "SYM-39",
                 "project_id" => 1,
                 "template" => "miden",
                 "surface" => "github_comment",
                 "target_field" => "planning_notes",
                 "value" => "private plan"
               },
               token: "secret",
               headers: @headers,
               capabilities: %{"comment" => true}
             )

    assert rejected.status == "rejected"
    assert rejected.reason == :projection_surface_excludes_field
    assert rejected.policy.allowed == %{}
  end

  test "approval and simulation actions return Linear-safe response summaries" do
    for payload <- [
          %{"action" => "approve_spec_amendment", "issue_id" => "SYM-39", "project_id" => 1, "amendment" => "Add smoke test"},
          %{"action" => "approve_merge_handoff", "issue_id" => "SYM-39", "project_id" => 1, "github_pr_url" => "https://github.com/BrianSeong99/symphony/pull/47"},
          %{"action" => "request_simulation", "issue_id" => "SYM-39", "project_id" => 1, "scenario" => "homelab full sync"}
        ] do
      assert {:ok, result} = Actions.handle(payload, token: "secret", headers: @headers)

      assert result.status == "accepted"
      assert result.summary == "#{payload["action"]} accepted for issue SYM-39"
      if payload["amendment"], do: refute(result.summary =~ payload["amendment"])
      assert AuditEvent.changeset(%AuditEvent{}, result.audit_event).valid?
    end
  end

  test "Phoenix endpoint exposes Linear custom action route" do
    start_test_endpoint(linear_action_token: "secret", linear_action_runner: runner(self()))

    conn =
      build_conn()
      |> put_req_header("x-symphony-linear-action-token", "secret")
      |> post("/api/v1/linear/actions", %{"action" => "start_run", "issue_id" => "SYM-39"})

    assert %{"status" => "accepted", "summary" => "start_run accepted for issue SYM-39"} =
             json_response(conn, 202)

    assert_receive {:runner_called, "start_run", %{issue_id: "SYM-39"}}

    rejected =
      build_conn()
      |> put_req_header("x-symphony-linear-action-token", "secret")
      |> post("/api/v1/linear/actions", %{"action" => "delete_everything", "issue_id" => "SYM-39"})

    assert %{"status" => "rejected", "reason" => "unsupported_action"} = json_response(rejected, 400)
  end

  defp runner(parent) do
    fn command, context ->
      send(parent, {:runner_called, command, context})
      {:ok, %{queued: true}}
    end
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
