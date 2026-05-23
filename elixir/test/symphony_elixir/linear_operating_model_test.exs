defmodule SymphonyElixir.Linear.OperatingModelTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.OperatingModel

  @root Path.expand("../../..", __DIR__)
  @config_path Path.join(@root, "config/symphony/linear-operating-model.yml")

  test "default operating model config is parseable and covers Brian's domains" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert OperatingModel.operating_domain_keys(model) == [
             "homelab-personal",
             "miden",
             "chainless",
             "wprc",
             "symphony"
           ]
  end

  test "outcome projects are first-class and repos remain metadata" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert OperatingModel.outcome_project_keys(model) == [
             "guardian-launch",
             "wallet-prd",
             "pioneer-integrations",
             "homelab-runtime",
             "wprc-website",
             "chainless-alpha",
             "symphony-linear-cockpit"
           ]

    assert OperatingModel.default_project_unit(model) == "outcome"
    refute OperatingModel.repo_as_default_project_unit?(model)

    assert %{
             "repo_metadata" => %{
               "representation" => "metadata",
               "labels" => ["repo:homelab"],
               "custom_fields" => %{"github_repository" => "BrianSeong99/homelab"}
             }
           } = OperatingModel.outcome_project!(model, "homelab-runtime")
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

    assert OperatingModel.checkpoint_cadence(model, "guardian-launch") == "twice-weekly"
    assert OperatingModel.checkpoint_cadence(model, "wprc-website") == "weekly"
  end

  test "Miden cannot use native GitHub issue sync" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)
    miden_native = put_in(model, ["outcome_projects", "guardian-launch", "sync_profile"], "native-full-sync")

    assert {:error, errors} = OperatingModel.validate(miden_native)
    assert "outcome_projects.guardian-launch.sync_profile cannot use native GitHub issue sync for Miden" in errors
  end

  test "Homelab can use native Linear-GitHub sync" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    assert :ok = OperatingModel.validate_project_sync_profile(model, "homelab-runtime", "native-full-sync")
  end

  test "rejects unknown domains and repo-as-project defaults" do
    assert {:ok, model} = OperatingModel.load_file(@config_path)

    invalid =
      model
      |> put_in(["outcome_projects", "guardian-launch", "operating_domain"], "unknown")
      |> put_in(["project_policy", "default_project_unit"], "repo")

    assert {:error, errors} = OperatingModel.validate(invalid)
    assert "project_policy.default_project_unit must be outcome" in errors
    assert "outcome_projects.guardian-launch.operating_domain references unknown domain unknown" in errors
  end
end
