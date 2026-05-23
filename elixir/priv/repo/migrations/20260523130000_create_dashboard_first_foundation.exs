defmodule SymphonyElixir.Repo.Migrations.CreateDashboardFirstFoundation do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:workspace, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:risk_policy, :string, null: false, default: "medium")
      add(:settings, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:projects, [:slug]))
    create(index(:projects, [:workspace]))
    create(index(:projects, [:status]))

    create table(:project_connections) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      add(:provider, :string, null: false)
      add(:connection_mode, :string, null: false)
      add(:owner, :string)
      add(:repo, :string)
      add(:status, :string, null: false, default: "active")
      add(:capabilities, :map, null: false, default: %{})
      add(:settings, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:project_connections, [:project_id]))
    create(index(:project_connections, [:provider, :connection_mode]))

    create table(:repositories) do
      add(:project_id, references(:projects, on_delete: :nilify_all))
      add(:provider, :string, null: false, default: "github")
      add(:owner, :string, null: false)
      add(:name, :string, null: false)
      add(:default_branch, :string, null: false, default: "main")
      add(:visibility, :string)
      add(:external_id, :string)
      add(:url, :text)
      add(:capabilities, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:repositories, [:project_id]))
    create(unique_index(:repositories, [:provider, :owner, :name]))

    create table(:symphony_milestones) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      add(:title, :string, null: false)
      add(:slug, :string, null: false)
      add(:milestone_type, :string, null: false)
      add(:target_date, :date)
      add(:objective, :text)
      add(:status, :string, null: false, default: "active")
      add(:github_sync, :string, null: false, default: "none")
      add(:success_criteria, {:array, :text}, null: false, default: [])
      add(:allowed_issue_types, {:array, :string}, null: false, default: [])
      add(:required_checkpoints, {:array, :string}, null: false, default: [])
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:symphony_milestones, [:project_id]))
    create(unique_index(:symphony_milestones, [:project_id, :slug]))

    create table(:symphony_issues) do
      add(:project_id, references(:projects, on_delete: :delete_all), null: false)
      add(:repository_id, references(:repositories, on_delete: :nilify_all))
      add(:milestone_id, references(:symphony_milestones, on_delete: :nilify_all))
      add(:title, :string, null: false)
      add(:description, :text)
      add(:issue_type, :string)
      add(:status, :string, null: false, default: "draft")
      add(:priority, :integer)
      add(:risk_level, :string, null: false, default: "medium")
      add(:acceptance_criteria, {:array, :text}, null: false, default: [])
      add(:validation_plan, {:array, :text}, null: false, default: [])
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:symphony_issues, [:project_id]))
    create(index(:symphony_issues, [:repository_id]))
    create(index(:symphony_issues, [:milestone_id]))
    create(index(:symphony_issues, [:status]))
    create(index(:symphony_issues, [:issue_type]))

    create table(:issue_external_links) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:provider, :string, null: false)
      add(:link_type, :string, null: false)
      add(:association_strength, :string, null: false)
      add(:external_id, :string)
      add(:url, :text, null: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:issue_external_links, [:symphony_issue_id]))
    create(index(:issue_external_links, [:provider, :external_id]))

    create table(:pr_external_links) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:repository_id, references(:repositories, on_delete: :nilify_all))
      add(:provider, :string, null: false, default: "github")
      add(:external_id, :string)
      add(:number, :integer)
      add(:url, :text, null: false)
      add(:branch, :string)
      add(:status, :string, null: false, default: "open")
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:pr_external_links, [:symphony_issue_id]))
    create(index(:pr_external_links, [:repository_id]))
    create(index(:pr_external_links, [:provider, :external_id]))

    create table(:workpads) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:body, :text, null: false)
      add(:active, :boolean, null: false, default: true)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:workpads, [:symphony_issue_id]))
    create(unique_index(:workpads, [:symphony_issue_id], name: :workpads_active_symphony_issue_id_index, where: "active"))

    create table(:validation_requirements) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:requirement_type, :string, null: false)
      add(:label, :text, null: false)
      add(:command, :text)
      add(:status, :string, null: false, default: "pending")
      add(:evidence, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:validation_requirements, [:symphony_issue_id]))
    create(index(:validation_requirements, [:status]))

    create table(:checkpoints) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:checkpoint_type, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:requested_at, :utc_datetime_usec)
      add(:approved_at, :utc_datetime_usec)
      add(:approved_by, :string)
      add(:notes, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:checkpoints, [:symphony_issue_id]))
    create(index(:checkpoints, [:status]))

    create table(:agent_sessions) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:role, :string, null: false)
      add(:backend, :string, null: false)
      add(:session_id, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:workspace_path, :text)
      add(:branch, :string)
      add(:last_active_at, :utc_datetime_usec)
      add(:destroy_reason, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:agent_sessions, [:symphony_issue_id]))
    create(index(:agent_sessions, [:role, :status]))
    create(unique_index(:agent_sessions, [:role, :session_id]))

    create table(:review_findings) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:pr_external_link_id, references(:pr_external_links, on_delete: :nilify_all))
      add(:agent_session_id, references(:agent_sessions, on_delete: :nilify_all))
      add(:state, :string, null: false, default: "open")
      add(:severity, :string, null: false, default: "medium")
      add(:title, :string, null: false)
      add(:body, :text)
      add(:source_url, :text)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:review_findings, [:symphony_issue_id]))
    create(index(:review_findings, [:pr_external_link_id]))
    create(index(:review_findings, [:state]))

    create table(:sync_events) do
      add(:project_id, references(:projects, on_delete: :nilify_all))
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :nilify_all))
      add(:provider, :string, null: false)
      add(:action, :string, null: false)
      add(:status, :string, null: false)
      add(:request, :map, null: false, default: %{})
      add(:response, :map, null: false, default: %{})
      add(:error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sync_events, [:project_id]))
    create(index(:sync_events, [:symphony_issue_id]))
    create(index(:sync_events, [:provider, :status]))

    create table(:learning_events) do
      add(:project_id, references(:projects, on_delete: :nilify_all))
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :nilify_all))
      add(:event_type, :string, null: false)
      add(:source, :string, null: false)
      add(:payload, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:learning_events, [:project_id]))
    create(index(:learning_events, [:event_type]))

    create table(:learned_rules) do
      add(:rule_key, :string, null: false)
      add(:rule_type, :string, null: false)
      add(:status, :string, null: false, default: "proposed")
      add(:scope, :map, null: false, default: %{})
      add(:body, :text, null: false)
      add(:confidence, :float)
      add(:approved_at, :utc_datetime_usec)
      add(:approved_by, :string)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:learned_rules, [:rule_key]))
    create(index(:learned_rules, [:status]))

    create table(:research_sources) do
      add(:title, :string, null: false)
      add(:url, :text, null: false)
      add(:topic, :string, null: false)
      add(:last_reviewed_on, :date)
      add(:applicable_rule, :string)
      add(:confidence, :float)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:research_sources, [:url]))
    create(index(:research_sources, [:topic]))

    create table(:pattern_rules) do
      add(:pattern_key, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:description, :text, null: false)
      add(:config, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:pattern_rules, [:pattern_key]))
    create(index(:pattern_rules, [:status]))

    create table(:run_metrics) do
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :delete_all), null: false)
      add(:metric_key, :string, null: false)
      add(:value_float, :float)
      add(:value_integer, :bigint)
      add(:unit, :string)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:run_metrics, [:symphony_issue_id]))
    create(index(:run_metrics, [:metric_key]))

    create table(:audit_events) do
      add(:project_id, references(:projects, on_delete: :nilify_all))
      add(:symphony_issue_id, references(:symphony_issues, on_delete: :nilify_all))
      add(:actor, :string, null: false)
      add(:action, :string, null: false)
      add(:target_type, :string)
      add(:target_id, :string)
      add(:payload, :map, null: false, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:audit_events, [:project_id]))
    create(index(:audit_events, [:symphony_issue_id]))
    create(index(:audit_events, [:action]))
  end
end
