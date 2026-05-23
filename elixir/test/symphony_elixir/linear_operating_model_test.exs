defmodule SymphonyElixir.Linear.OperatingModelTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.OperatingModel

  @root Path.expand("../../..", __DIR__)
  @config_path Path.join(@root, "config/symphony/linear-operating-model.yml")

  test "default operating model config is parseable and covers Brian's domains" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert OperatingModel.operating_domain_keys(model) == [
             "labs",
             "miden",
             "chainless",
             "wprc",
             "personal"
           ]
  end

  test "Homelab projects are first-class and repos remain metadata" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert OperatingModel.outcome_project_keys(model) == [
             "omega-docs",
             "omega-interface",
             "omega-zone",
             "cfo",
             "cmo",
             "homelab",
             "symphony",
             "docs",
             "miden-testnet-bridge",
             "miden-wallet",
             "0xmiden",
             "agent-skills",
             "personal-agent-skills",
             "resume",
             "wprc-website",
             "intelligence-stack"
           ]

    assert OperatingModel.default_project_unit(model) == "homelab_project"
    refute OperatingModel.repo_as_default_project_unit?(model)

    assert %{
             "homelab_workspace_id" => "labs",
             "homelab_project_id" => "homelab",
             "linear_project_key" => "homelab-02e0c66d1cb8",
             "linear_project_url" => "https://linear.app/brianseong/project/homelab-02e0c66d1cb8",
             "repo_metadata" => %{
               "representation" => "metadata",
               "full_sync_allowed" => true,
               "labels" => ["repo:homelab"],
               "custom_fields" => %{"github_repository" => "BrianSeong99/homelab"}
             }
           } = OperatingModel.outcome_project!(model, "homelab")
  end

  test "validates supported sync profiles and checkpoint cadence" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert OperatingModel.sync_profiles(model) == [
             "native-full-sync",
             "relay-full-sync",
             "relay-pr-only",
             "relay-context-only",
             "no-github"
           ]

    assert OperatingModel.checkpoint_cadence(model, "miden-wallet") == "twice-weekly"
    assert OperatingModel.checkpoint_cadence(model, "wprc-website") == "weekly"
  end

  test "Miden cannot use native GitHub issue sync" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)
    miden_native = put_in(model, ["outcome_projects", "docs", "sync_profile"], "native-full-sync")

    assert {:error, errors} = OperatingModel.validate(miden_native)
    assert "outcome_projects.docs.sync_profile cannot use native GitHub issue sync for Miden" in errors
  end

  test "Homelab can use native Linear-GitHub sync" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert :ok = OperatingModel.validate_project_sync_profile(model, "homelab", "native-full-sync")
    assert get_in(model, ["outcome_projects", "homelab", "repo_metadata", "full_sync_allowed"]) == true
    refute get_in(model, ["outcome_projects", "docs", "repo_metadata", "full_sync_allowed"]) == true
  end

  test "rejects unknown domains, workspace mismatches, and repo-as-project defaults" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    invalid =
      model
      |> put_in(["outcome_projects", "docs", "operating_domain"], "unknown")
      |> put_in(["outcome_projects", "homelab", "homelab_workspace_id"], "personal")
      |> put_in(["project_policy", "default_project_unit"], "repo")

    assert {:error, errors} = OperatingModel.validate(invalid)
    assert "project_policy.default_project_unit must be homelab_project" in errors
    assert "outcome_projects.docs.operating_domain references unknown domain unknown" in errors

    assert "outcome_projects.homelab.homelab_workspace_id personal does not match operating_domain labs" in errors
  end
end
