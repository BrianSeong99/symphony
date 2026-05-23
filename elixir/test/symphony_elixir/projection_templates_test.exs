defmodule SymphonyElixir.ProjectionTemplatesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProjectionTemplates

  test "loads and validates workspace projection templates" do
    config = ProjectionTemplates.load!()

    assert :ok = ProjectionTemplates.validate(config)

    assert ProjectionTemplates.template(config, :miden).profile == :miden
    assert ProjectionTemplates.template(config, :wprc).modes.controlled.sync_strategy == "native-full-sync"

    for template <- [:homelab, :personal, :miden, :chainless, :wprc, :symphony] do
      surfaces = ProjectionTemplates.template(config, template).surfaces

      assert Map.has_key?(surfaces, :linear)
      assert Map.has_key?(surfaces, :github_issue)
      assert Map.has_key?(surfaces, :github_pr)
      assert Map.has_key?(surfaces, :linear_comment)
      assert Map.has_key?(surfaces, :github_comment)
      assert Map.has_key?(surfaces, :run_summary)
      assert Map.has_key?(surfaces, :checkpoint_request)
      assert Map.has_key?(surfaces, :symphony)
    end
  end

  test "Homelab projects can use full Linear and GitHub sync while keeping runtime details private" do
    preview =
      ProjectionTemplates.preview(
        :homelab,
        %{
          "title" => "Homelab runtime",
          planning_notes: "private plan",
          workpad: "private workpad",
          dependencies: ["SYM-2"],
          agent_memory: "persistent builder context",
          private_comments: "private checkpoint",
          validation: "mix test passed",
          run_metrics: %{retry_count: 0},
          public_comments: "Ready for public issue update"
        },
        approvals: [:public_comments],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    assert preview.sync_strategy == "native-full-sync"
    assert preview.surfaces.linear.allowed.workpad == "[summary available]"
    assert preview.surfaces.linear.allowed.run_metrics == "[summary available]"
    assert preview.surfaces.linear.allowed.private_comments == "private checkpoint"
    assert preview.surfaces.symphony.allowed.agent_memory == "persistent builder context"

    assert preview.surfaces.github_issue.allowed == %{
             title: "Homelab runtime",
             dependencies: ["SYM-2"],
             validation: "mix test passed",
             public_comments: "Ready for public issue update"
           }

    refute Map.has_key?(preview.surfaces.github_issue.allowed, :workpad)
    refute Map.has_key?(preview.surfaces.github_issue.allowed, :agent_memory)
  end

  test "Miden keeps Linear private and allows GitHub comments only with explicit approval" do
    values = %{
      title: "Guardian launch",
      planning_notes: "private product strategy",
      workpad: "private workpad",
      pr_state: "open",
      checks: "green",
      validation: "manual smoke test passed",
      public_comments: "Public-safe PR note"
    }

    preview = ProjectionTemplates.preview(:miden, values)

    assert preview.sync_strategy == "relay-context-only"
    assert preview.surfaces.linear.allowed.planning_notes == "private product strategy"
    assert preview.surfaces.linear.allowed.workpad == "[summary available]"
    assert preview.surfaces.github_issue.allowed == %{}
    assert preview.surfaces.github_issue.rejected == %{public_comments: :explicit_approval_required}

    approved = ProjectionTemplates.preview(:miden, values, approvals: [:public_comments])

    assert approved.surfaces.github_issue.allowed == %{public_comments: "Public-safe PR note"}
    assert approved.surfaces.github_pr.allowed.pr_state == "open"
    assert approved.surfaces.github_pr.allowed.checks == "green"
    refute Map.has_key?(approved.surfaces.github_issue.allowed, :title)
  end

  test "Chainless relay avoids overwriting company-owned workflow state" do
    preview =
      ProjectionTemplates.preview(
        :chainless,
        %{
          title: "Alpha execution",
          status: "In Progress",
          dependencies: ["CHN-1"],
          validation: "integration test passed",
          public_comments: "Public relay update"
        },
        approvals: [:public_comments]
      )

    github_issue = preview.surfaces.github_issue

    assert github_issue.metadata.overwrite_company_workflow_state == false
    assert github_issue.allowed.dependencies == ["CHN-1"]
    assert github_issue.allowed.validation == "integration test passed"
    refute Map.has_key?(github_issue.allowed, :title)
    refute Map.has_key?(github_issue.allowed, :status)
  end

  test "WPRC can run context-only by default and controlled native sync when permissions allow it" do
    default_preview =
      ProjectionTemplates.preview(
        :wprc,
        %{title: "WPRC website", validation: "preview passed", public_comments: "Ready"},
        approvals: [:public_comments]
      )

    assert default_preview.sync_strategy == "relay-context-only"
    assert default_preview.surfaces.github_issue.status == :disabled
    assert default_preview.surfaces.github_issue.reason == {:mode_disables_surface, :context_only}

    controlled_preview =
      ProjectionTemplates.preview(
        :wprc,
        %{title: "WPRC website", validation: "preview passed", public_comments: "Ready"},
        mode: :controlled,
        approvals: [:public_comments],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    assert controlled_preview.sync_strategy == "native-full-sync"
    assert controlled_preview.surfaces.github_issue.allowed.title == "WPRC website"
    assert controlled_preview.surfaces.github_issue.allowed.validation == "preview passed"
  end

  test "public projections redact private notes, workpads, agent memory, and strategy fields before policy preview" do
    config =
      ProjectionTemplates.load!()
      |> put_in([:templates, :homelab, :surfaces, :github_issue, :fields], [
        :title,
        :planning_notes,
        :workpad,
        :agent_memory,
        :private_comments
      ])

    preview =
      ProjectionTemplates.preview(
        :homelab,
        %{
          title: "Accidental public template",
          planning_notes: "private strategy",
          workpad: "private workpad",
          agent_memory: "private reviewer memory",
          private_comments: "private comment"
        },
        config: config
      )

    github_issue = preview.surfaces.github_issue

    assert github_issue.allowed == %{title: "Accidental public template"}

    assert github_issue.redacted == %{
             planning_notes: %{action: :drop, reason: :private_strategy},
             workpad: %{action: :drop, reason: :private_runtime},
             agent_memory: %{action: :drop, reason: :private_runtime},
             private_comments: %{action: :drop, reason: :private_strategy}
           }
  end

  test "sensitive partner markers are replaced on public comment projections but kept private in Symphony" do
    preview =
      ProjectionTemplates.preview(
        :homelab,
        %{
          public_comments: "[partner-private] partner update",
          validation: "[sensitive-partner] validation details",
          agent_memory: "[partner-private] private runtime context"
        },
        approvals: [:public_comments],
        capabilities: %{"comment" => true, "edit_issues" => true}
      )

    assert preview.surfaces.github_comment.allowed.public_comments == "[redacted:sensitive_partner_context]"
    assert preview.surfaces.github_comment.allowed.validation == "[redacted:sensitive_partner_context]"

    assert preview.surfaces.github_comment.redacted == %{
             public_comments: %{action: :replace, reason: :sensitive_partner_context},
             validation: %{action: :replace, reason: :sensitive_partner_context}
           }

    assert preview.surfaces.symphony.allowed.agent_memory == "[partner-private] private runtime context"
  end
end
