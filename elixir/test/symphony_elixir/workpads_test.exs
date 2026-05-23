defmodule SymphonyElixir.WorkpadsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workpads
  alias SymphonyElixir.Workpads.Workpad

  test "workpad sections match the local-first planning contract" do
    assert Workpads.sections() == [
             "Environment",
             "Issue Type",
             "Milestone",
             "Scope Interpretation",
             "Non-Goals",
             "Acceptance Criteria",
             "Validation / Test Plan",
             "Risk And Checkpoints",
             "Implementation Plan",
             "Evidence",
             "Confusions",
             "Proposed Spec Amendments"
           ]
  end

  test "new_body/1 renders every required section" do
    body =
      Workpads.new_body(%{
        environment: "mac-studio:/workspaces/SYM-1@abc123",
        issue_type: "feature",
        milestone: "dashboard-first-v1"
      })

    assert body =~ "## Symphony Workpad"
    assert body =~ "mac-studio:/workspaces/SYM-1@abc123"
    assert body =~ "### Proposed Spec Amendments"

    for section <- Workpads.sections() do
      assert body =~ "### #{section}"
    end
  end

  test "contains_required_sections?/1 validates workpad completeness" do
    assert Workpads.contains_required_sections?(Workpads.new_body(%{}))
    refute Workpads.contains_required_sections?("## Symphony Workpad\n\n### Evidence\n")
  end

  test "workpad changeset validates one local workpad payload" do
    changeset =
      Workpad.changeset(%Workpad{}, %{
        symphony_issue_id: 123,
        body: Workpads.new_body(%{}),
        metadata: %{"github_comment_sync" => "disabled"}
      })

    assert changeset.valid?

    workpad = Ecto.Changeset.apply_action!(changeset, :insert)
    assert workpad.active == true
    assert workpad.metadata["github_comment_sync"] == "disabled"
  end

  test "workpad changeset rejects bodies missing required sections" do
    changeset =
      Workpad.changeset(%Workpad{}, %{
        symphony_issue_id: 123,
        body: "## Symphony Workpad\n\n### Evidence\n"
      })

    refute changeset.valid?
    assert {"is missing required workpad sections", _} = Keyword.fetch!(changeset.errors, :body)
  end
end
