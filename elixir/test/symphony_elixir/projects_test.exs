defmodule SymphonyElixir.ProjectsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Projects
  alias SymphonyElixir.Projects.{Project, ProjectConnection}

  test "connection modes cover dashboard-only through full GitHub sync" do
    assert Projects.connection_modes() == [
             :none,
             :context_only,
             :pr_only,
             :issue_mirror,
             :full_sync
           ]
  end

  test "project changeset generates a stable slug and validates policy fields" do
    changeset =
      Project.changeset(%Project{}, %{
        name: "Miden Docs Readiness",
        workspace: "miden",
        risk_policy: "high"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :slug) == "miden-docs-readiness"

    project = Ecto.Changeset.apply_action!(changeset, :insert)
    assert project.status == "active"
    assert project.settings == %{}
  end

  test "project changeset rejects unknown workspaces and risk policies" do
    changeset =
      Project.changeset(%Project{}, %{
        name: "Bad Project",
        workspace: "random",
        risk_policy: "reckless"
      })

    refute changeset.valid?
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :workspace)
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :risk_policy)
  end

  test "project connection changeset validates modes and stores capability probe results" do
    changeset =
      ProjectConnection.changeset(%ProjectConnection{}, %{
        project_id: 123,
        provider: "github",
        connection_mode: "pr_only",
        owner: "0xMiden",
        repo: "miden-docs",
        capabilities: %{
          "read_repo" => true,
          "read_issues" => true,
          "create_issues" => false,
          "create_labels" => false,
          "edit_milestones" => false,
          "create_prs" => true,
          "read_checks" => true,
          "comment" => false
        }
      })

    assert changeset.valid?

    connection = Ecto.Changeset.apply_action!(changeset, :insert)
    assert connection.connection_mode == "pr_only"
    assert connection.capabilities["create_labels"] == false
    assert connection.status == "active"
  end

  test "project connection rejects unsupported providers and modes" do
    changeset =
      ProjectConnection.changeset(%ProjectConnection{}, %{
        project_id: 123,
        provider: "linear",
        connection_mode: "everything"
      })

    refute changeset.valid?
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :provider)
    assert {"is invalid", _} = Keyword.fetch!(changeset.errors, :connection_mode)
  end
end
