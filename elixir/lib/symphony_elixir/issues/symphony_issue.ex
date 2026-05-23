defmodule SymphonyElixir.Issues.SymphonyIssue do
  @moduledoc """
  A local Symphony issue owned by the dashboard-first control plane.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Issues

  @risk_levels ~w(low medium high critical)

  @type t :: %__MODULE__{}

  schema "symphony_issues" do
    field(:project_id, :id)
    field(:repository_id, :id)
    field(:milestone_id, :id)
    field(:title, :string)
    field(:description, :string)
    field(:issue_type, :string)
    field(:status, :string, default: "draft")
    field(:priority, :integer)
    field(:risk_level, :string, default: "medium")
    field(:acceptance_criteria, {:array, :string}, default: [])
    field(:validation_plan, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(issue, attrs) when is_map(attrs) do
    issue
    |> cast(attrs, [
      :project_id,
      :repository_id,
      :milestone_id,
      :title,
      :description,
      :issue_type,
      :status,
      :priority,
      :risk_level,
      :acceptance_criteria,
      :validation_plan,
      :metadata
    ])
    |> validate_required([:project_id, :title, :status, :risk_level])
    |> validate_inclusion(:status, Issues.status_strings())
    |> validate_inclusion(:risk_level, @risk_levels)
    |> validate_inclusion(:issue_type, Issues.issue_types())
    |> validate_number(:priority, greater_than_or_equal_to: 0)
  end
end
