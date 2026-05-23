defmodule SymphonyElixir.MilestonesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Milestones
  alias SymphonyElixir.Milestones.SymphonyMilestone

  @root Path.expand("../../..", __DIR__)
  @registry_path Path.join(@root, "config/symphony/milestone-types.yml")

  test "milestone type registry is parseable and contains required templates" do
    registry = read_yaml!(@registry_path)

    assert registry["version"] == 1

    keys = registry["milestone_types"] |> Enum.map(& &1["key"]) |> MapSet.new()

    for key <- [
          "project-roadmap",
          "release",
          "integration",
          "sprint",
          "research-track",
          "ops-maintenance",
          "launch-critical"
        ] do
      assert MapSet.member?(keys, key)
    end
  end

  test "milestone statuses and sync modes match local-first design" do
    assert Milestones.statuses() == [:active, :paused, :completed, :cancelled]
    assert Milestones.github_sync_modes() == [:none, :virtual, :native]
  end

  test "milestone changeset validates local milestone fields and defaults" do
    changeset =
      SymphonyMilestone.changeset(%SymphonyMilestone{}, %{
        project_id: 123,
        title: "Miden mainnet docs readiness",
        milestone_type: "release",
        target_date: ~D[2026-06-20],
        objective: "Docs/devex readiness for mainnet",
        success_criteria: ["Critical tutorials validated"],
        allowed_issue_types: ["docs", "release-integration"],
        required_checkpoints: ["planning_review", "midpoint_health_check", "final_validation_review"],
        github_sync: "none"
      })

    assert changeset.valid?

    milestone = Ecto.Changeset.apply_action!(changeset, :insert)
    assert milestone.slug == "miden-mainnet-docs-readiness"
    assert milestone.status == "active"
  end

  test "milestone changeset rejects unknown types and sync modes" do
    changeset =
      SymphonyMilestone.changeset(%SymphonyMilestone{}, %{
        project_id: 123,
        title: "Bad milestone",
        milestone_type: "whatever",
        github_sync: "force"
      })

    refute changeset.valid?
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :milestone_type)
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :github_sync)
  end

  defp read_yaml!(path) do
    assert File.exists?(path), "expected #{path} to exist"

    assert {:ok, decoded} = path |> File.read!() |> YamlElixir.read_from_string()
    assert is_map(decoded)

    decoded
  end
end
