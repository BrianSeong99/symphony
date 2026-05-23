defmodule SymphonyElixir.Repo.Migrations.CreateIssueDependencies do
  use Ecto.Migration

  def change do
    create table(:issue_dependencies) do
      add(:dependent_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:dependency_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:dependency_policy, :string, null: false, default: "all_done")
      add(:parallel_group, :string)
      add(:phase, :integer)
      add(:unblock_condition, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:issue_dependencies, [:dependent_issue_id]))
    create(index(:issue_dependencies, [:dependency_issue_id]))
    create(index(:issue_dependencies, [:parallel_group]))
    create(index(:issue_dependencies, [:phase]))
    create(unique_index(:issue_dependencies, [:dependent_issue_id, :dependency_issue_id]))
  end
end
