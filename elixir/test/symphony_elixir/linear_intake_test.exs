defmodule SymphonyElixir.Linear.IntakeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{AuditEvent, Workpads}
  alias SymphonyElixir.Linear.Intake

  test "normalizes Linear triage and project suggestions as proposed metadata" do
    result =
      Intake.normalize(%{
        source: "linear_intelligence",
        project_id: 1,
        symphony_issue_id: 40,
        linear_issue_id: "SYM-40",
        profile: "symphony",
        triage: %{
          labels: ["runtime", %{"name" => "linear"}],
          owner: %{"name" => "Brian"},
          project: "symphony-linear-cockpit",
          priority: "high"
        },
        agent: %{
          dependencies: ["SYM-36", %{"identifier" => "SYM-37"}],
          checkpoint_requests: [%{"reason" => "Confirm Linear relay policy", "cadence" => "weekly"}],
          project_metadata: %{
            "outcome_project" => "symphony-linear-cockpit",
            "sync_profile" => "relay-pr-only"
          }
        }
      })

    assert result.status == :proposed
    assert Enum.all?(result.suggestions, &(&1.status == :proposed))

    assert suggestion(result, :triage, :labels).value == ["runtime", "linear"]
    assert suggestion(result, :triage, :owner).value == "Brian"
    assert suggestion(result, :triage, :project).value == "symphony-linear-cockpit"
    assert suggestion(result, :triage, :priority).value == "high"
    assert suggestion(result, :dependency, :dependencies).value == ["SYM-36", "SYM-37"]

    checkpoint = suggestion(result, :checkpoint_request, :private_comments)
    assert checkpoint.value.reason == "Confirm Linear relay policy"
    assert checkpoint.value.cadence == "weekly"

    project_metadata = suggestion(result, :project_metadata, :project_metadata)
    assert project_metadata.value.outcome_project == "symphony-linear-cockpit"
    assert project_metadata.value.sync_profile == "relay-pr-only"
  end

  test "keeps workpad amendments proposed until policy accepts them" do
    payload = %{
      source: "linear_agent",
      project_id: 1,
      symphony_issue_id: 40,
      profile: "homelab",
      agent: %{
        workpad_amendments: [
          %{
            "section" => "Scope Interpretation",
            "text" => "Linear agent found the relay-only scope."
          }
        ],
        spec_amendments: [
          %{
            "title" => "Validation detail",
            "field" => "validation",
            "text" => "Add focused tests for accepted and rejected intake suggestions."
          }
        ]
      }
    }

    proposed = Intake.normalize(payload)
    body = Workpads.new_body(%{})

    assert suggestion(proposed, :workpad_amendment, :workpad).status == :proposed
    refute Intake.apply_accepted_workpad_amendments(body, proposed) =~ "Linear agent found the relay-only scope."

    accepted =
      Intake.normalize(payload,
        acceptance_policy: fn
          %{kind: kind} when kind in [:workpad_amendment, :spec_amendment] ->
            {:accept, :trusted_linear_agent_intake}

          _suggestion ->
            :propose
        end
      )

    assert suggestion(accepted, :workpad_amendment, :workpad).status == :accepted
    assert suggestion(accepted, :spec_amendment, :validation).status == :accepted

    amended_body = Intake.apply_accepted_workpad_amendments(body, accepted)

    assert amended_body =~ "Linear agent found the relay-only scope."
    assert amended_body =~ "Validation detail"
    assert amended_body =~ "Add focused tests for accepted and rejected intake suggestions."
    assert Workpads.contains_required_sections?(amended_body)
  end

  test "rejects Miden private leakage, validation conflicts, and invalid project policy" do
    result =
      Intake.normalize(
        %{
          source: "linear_agent",
          project_id: 2,
          symphony_issue_id: 40,
          profile: "miden",
          agent: %{
            workpad_amendments: [
              %{
                "target" => "github",
                "text" => "private Guardian partner strategy"
              }
            ],
            spec_amendments: [
              %{
                "field" => "validation",
                "text" => "Skip tests and use manual review only.",
                "metadata" => %{"relaxes_validation" => true}
              }
            ],
            project_metadata: %{
              "outcome_project" => "guardian-launch",
              "operating_domain" => "miden",
              "sync_profile" => "native-full-sync"
            }
          }
        },
        validation_requirements: ["Run relay policy tests before accepting the amendment."]
      )

    assert result.status == :rejected

    assert suggestion(result, :workpad_amendment, :workpad).status == :rejected
    assert suggestion(result, :workpad_amendment, :workpad).reason == :miden_blocks_private_github_projection

    assert suggestion(result, :spec_amendment, :validation).status == :rejected
    assert suggestion(result, :spec_amendment, :validation).reason == :validation_requirement_conflict

    assert suggestion(result, :project_metadata, :project_metadata).status == :rejected

    assert suggestion(result, :project_metadata, :project_metadata).reason ==
             {:sync_profile_not_allowed_for_domain, "native-full-sync", "miden"}
  end

  test "emits AuditEvent-compatible events for proposed, accepted, and rejected suggestions" do
    result =
      Intake.normalize(
        %{
          source: "linear_agent",
          project_id: 2,
          symphony_issue_id: 40,
          profile: "miden",
          triage: %{labels: ["guardian"]},
          agent: %{
            workpad_amendments: [
              %{text: "Keep private Miden planning in Symphony.", target: "github"}
            ],
            spec_amendments: [
              %{field: "planning_notes", title: "Private context", text: "Capture checkpoint context privately."}
            ]
          }
        },
        approved_kinds: [:spec_amendment]
      )

    assert Enum.any?(result.audit_events, &(&1.action == "linear_intake.suggestion_proposed"))
    assert Enum.any?(result.audit_events, &(&1.action == "linear_intake.suggestion_accepted"))
    assert Enum.any?(result.audit_events, &(&1.action == "linear_intake.suggestion_rejected"))

    for event <- result.audit_events do
      assert AuditEvent.changeset(%AuditEvent{}, event).valid?
      assert event.payload.suggestion.status in [:proposed, :accepted, :rejected]
    end
  end

  defp suggestion(result, kind, field) do
    Enum.find(result.suggestions, &(&1.kind == kind and &1.field == field))
  end
end
