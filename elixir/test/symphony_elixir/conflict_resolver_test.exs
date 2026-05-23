defmodule SymphonyElixir.ConflictResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AuditEvent, ConflictResolver}

  test "detects stale webhooks, missing links, field drift, PR state changes, and dependency drift" do
    result =
      ConflictResolver.resolve(base_snapshot(),
        template: :homelab,
        approvals: [:public_comments],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    assert Enum.map(result.conflicts, & &1.type) == [
             :stale_webhook,
             :missing_github_link,
             :linear_title_changed,
             :linear_description_changed,
             :github_issue_body_changed,
             :github_pr_state_changed,
             :dependency_drift
           ]

    assert result.status == :needs_checkpoint
  end

  test "auto-resolves clear ownership and uses projection templates before public GitHub writes" do
    result =
      ConflictResolver.resolve(base_snapshot(),
        template: :homelab,
        approvals: [:public_comments],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    title_resolution = resolution(result, :linear_title_changed)
    pr_resolution = resolution(result, :github_pr_state_changed)
    dependency_resolution = resolution(result, :dependency_drift)

    assert title_resolution.status == :auto
    assert title_resolution.action == :project_field
    assert title_resolution.reason == :field_owner_linear
    assert title_resolution.projection.allowed.title == "New Linear title"

    assert pr_resolution.status == :auto
    assert pr_resolution.action == :ingest_field
    assert pr_resolution.reason == :field_owner_github
    assert pr_resolution.source == :github

    assert dependency_resolution.status == :auto
    assert dependency_resolution.action == :project_field
    assert dependency_resolution.projection.allowed.dependencies == ["SYM-1", "SYM-2"]
  end

  test "ambiguous ownership and unsafe public projection escalate to human checkpoint" do
    result =
      ConflictResolver.resolve(base_snapshot(),
        template: :miden,
        mode: :context_only,
        approvals: [],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    title_resolution = resolution(result, :linear_title_changed)
    body_resolution = resolution(result, :github_issue_body_changed)
    dependency_resolution = resolution(result, :dependency_drift)

    assert title_resolution.status == :checkpoint
    assert title_resolution.reason == :projection_surface_excludes_field
    assert title_resolution.projection.allowed == %{}

    assert body_resolution.status == :checkpoint
    assert body_resolution.reason == :ambiguous_field_owner

    assert dependency_resolution.status == :checkpoint
    assert dependency_resolution.reason == :projection_surface_excludes_field
    assert dependency_resolution.projection.allowed == %{}
    assert dependency_resolution.projection.rejected == %{}

    assert result.checkpoint.required?
    assert Enum.map(result.checkpoint.conflicts, & &1.type) |> Enum.member?(:dependency_drift)
  end

  test "records drift and resolution audit events with proposed resolution evidence" do
    result =
      ConflictResolver.resolve(base_snapshot(),
        template: :homelab,
        approvals: [:public_comments],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    assert Enum.any?(result.audit_events, &(&1.action == "drift.detected"))
    assert Enum.any?(result.audit_events, &(&1.action == "drift.resolution_proposed"))

    detected_event =
      Enum.find(result.audit_events, fn event ->
        event.action == "drift.detected" and event.payload.conflict.type == :linear_title_changed
      end)

    resolution_event =
      Enum.find(result.audit_events, fn event ->
        event.action == "drift.resolution_proposed" and
          event.payload.resolution.conflict_type == :linear_title_changed
      end)

    assert detected_event.payload.conflict.type == :linear_title_changed
    assert resolution_event.payload.resolution.action in [:project_field, :request_human_checkpoint]

    for event <- result.audit_events do
      assert AuditEvent.changeset(%AuditEvent{}, event).valid?
    end
  end

  defp resolution(result, conflict_type) do
    Enum.find(result.resolutions, &(&1.conflict_type == conflict_type))
  end

  defp base_snapshot do
    %{
      project_id: 1,
      symphony_issue_id: 38,
      required_links: [:github_issue],
      links: %{github_pr: "https://github.com/BrianSeong99/symphony/pull/46"},
      webhook: %{
        provider: "linear",
        event_id: "evt-old",
        occurred_at: ~U[2026-05-23 01:00:00Z],
        last_seen_at: ~U[2026-05-23 01:05:00Z]
      },
      expected: %{
        linear: %{title: "Old Linear title", description: "Old private description"},
        github_issue: %{body: "Old public issue body"},
        github_pr: %{state: "open"},
        dependencies: ["SYM-1"]
      },
      observed: %{
        linear: %{title: "New Linear title", description: "New private description"},
        github_issue: %{body: "Edited public issue body"},
        github_pr: %{state: "merged"},
        dependencies: ["SYM-1", "SYM-2"]
      }
    }
  end
end
