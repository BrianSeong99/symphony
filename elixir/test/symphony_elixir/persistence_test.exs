defmodule SymphonyElixir.PersistenceTest do
  use ExUnit.Case, async: true

  @repo Module.concat(SymphonyElixir, Repo)

  test "application config exposes the local Ecto repo" do
    assert Code.ensure_loaded?(@repo)
    assert @repo in Application.fetch_env!(:symphony_elixir, :ecto_repos)

    repo_config = Application.fetch_env!(:symphony_elixir, @repo)
    assert repo_config[:adapter] == Ecto.Adapters.Postgres
  end

  test "application supervises the local Ecto repo" do
    children = Supervisor.which_children(SymphonyElixir.Supervisor)

    assert Enum.any?(children, fn
             {@repo, _pid, :supervisor, [@repo]} -> true
             _child -> false
           end)
  end

  test "initial migration creates dashboard-first orchestration tables" do
    migration_path =
      "priv/repo/migrations/*_create_dashboard_first_foundation.exs"
      |> Path.wildcard()
      |> List.first()

    assert migration_path

    migration = File.read!(migration_path)

    for table <- [
          "projects",
          "project_connections",
          "repositories",
          "symphony_issues",
          "symphony_milestones",
          "issue_external_links",
          "pr_external_links",
          "workpads",
          "validation_requirements",
          "checkpoints",
          "agent_sessions",
          "review_findings",
          "sync_events",
          "learning_events",
          "learned_rules",
          "research_sources",
          "pattern_rules",
          "run_metrics",
          "audit_events"
        ] do
      assert migration =~ "create table(:#{table})"
    end
  end
end
