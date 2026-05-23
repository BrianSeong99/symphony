defmodule SymphonyElixir.IssueTypeRegistryTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @registry_path Path.join(@root, "config/symphony/issue-types.yml")

  @issue_types [
    "feature",
    "bug",
    "docs",
    "frontend-ui",
    "backend-api",
    "contract-security",
    "infra-homelab",
    "test-validation",
    "refactor",
    "research-spike",
    "release-integration",
    "follow-up-tech-debt"
  ]

  @required_sections [
    "Problem",
    "Scope",
    "Non-Goals",
    "Acceptance Criteria",
    "Validation / Test Plan",
    "Risk Level",
    "Human Checkpoints",
    "Rollback / Recovery",
    "Links / Context"
  ]

  test "issue type registry is parseable and contains the required type set" do
    registry = read_yaml!(@registry_path)

    assert registry["version"] == 1
    assert registry["default_required_sections"] == @required_sections

    issue_types = Map.fetch!(registry, "issue_types")
    keys = issue_types |> Enum.map(& &1["key"]) |> MapSet.new()

    for issue_type <- @issue_types do
      assert MapSet.member?(keys, issue_type)
    end
  end

  test "each issue type declares readiness and validation gates" do
    registry = read_yaml!(@registry_path)

    for issue_type <- Map.fetch!(registry, "issue_types") do
      assert is_binary(issue_type["key"])
      assert is_binary(issue_type["summary"])
      assert is_list(issue_type["required_sections"])
      assert is_list(issue_type["validation_requirements"])
      assert is_list(issue_type["readiness_gates"])

      for section <- @required_sections do
        assert section in issue_type["required_sections"]
      end
    end
  end

  test "high-risk and specialized issue types require their expected gates" do
    registry = read_yaml!(@registry_path)
    by_key = Map.new(registry["issue_types"], &{&1["key"], &1})

    assert "reproduction-evidence" in by_key["bug"]["readiness_gates"]
    assert "docs-render-or-build" in by_key["docs"]["validation_requirements"]
    assert "browser-walkthrough" in by_key["frontend-ui"]["validation_requirements"]
    assert "contract-impact-check" in by_key["backend-api"]["readiness_gates"]
    assert "human-approval-before-build" in by_key["contract-security"]["readiness_gates"]
    assert "docker-health-route-validation" in by_key["infra-homelab"]["validation_requirements"]
    assert "decision-output-required" in by_key["research-spike"]["readiness_gates"]
    assert "rollback-plan-required" in by_key["release-integration"]["readiness_gates"]
  end

  defp read_yaml!(path) do
    assert File.exists?(path), "expected #{path} to exist"

    assert {:ok, decoded} = path |> File.read!() |> YamlElixir.read_from_string()
    assert is_map(decoded)

    decoded
  end
end
