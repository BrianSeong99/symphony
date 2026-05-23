defmodule SymphonyElixir.Milestones.SymphonyMilestone do
  @moduledoc """
  A local Symphony milestone.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.{Issues, Milestones}

  @type t :: %__MODULE__{}

  schema "symphony_milestones" do
    field(:project_id, :id)
    field(:title, :string)
    field(:slug, :string)
    field(:milestone_type, :string)
    field(:target_date, :date)
    field(:objective, :string)
    field(:status, :string, default: "active")
    field(:github_sync, :string, default: "none")
    field(:success_criteria, {:array, :string}, default: [])
    field(:allowed_issue_types, {:array, :string}, default: [])
    field(:required_checkpoints, {:array, :string}, default: [])
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(milestone, attrs) when is_map(attrs) do
    milestone
    |> cast(attrs, [
      :project_id,
      :title,
      :slug,
      :milestone_type,
      :target_date,
      :objective,
      :status,
      :github_sync,
      :success_criteria,
      :allowed_issue_types,
      :required_checkpoints,
      :metadata
    ])
    |> put_slug_from_title()
    |> validate_required([:project_id, :title, :slug, :milestone_type, :status, :github_sync])
    |> validate_inclusion(:milestone_type, Milestones.milestone_types())
    |> validate_inclusion(:status, Milestones.status_strings())
    |> validate_inclusion(:github_sync, Milestones.github_sync_mode_strings())
    |> validate_subset(:allowed_issue_types, Issues.issue_types())
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
  end

  defp put_slug_from_title(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :title)} do
      {nil, title} when is_binary(title) -> put_change(changeset, :slug, slugify(title))
      {"", title} when is_binary(title) -> put_change(changeset, :slug, slugify(title))
      _ -> changeset
    end
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
