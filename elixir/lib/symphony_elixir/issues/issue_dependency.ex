defmodule SymphonyElixir.Issues.IssueDependency do
  @moduledoc """
  A directed local dependency edge between two Symphony issues.

  `dependent_issue_id` is blocked by `dependency_issue_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @policies ~w(all_done)

  @type t :: %__MODULE__{}

  schema "issue_dependencies" do
    field(:dependent_issue_id, :id)
    field(:dependency_issue_id, :id)
    field(:dependency_policy, :string, default: "all_done")
    field(:parallel_group, :string)
    field(:phase, :integer)
    field(:unblock_condition, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec policies() :: [String.t()]
  def policies, do: @policies

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(edge, attrs) when is_map(attrs) do
    edge
    |> cast(attrs, [
      :dependent_issue_id,
      :dependency_issue_id,
      :dependency_policy,
      :parallel_group,
      :phase,
      :unblock_condition,
      :metadata
    ])
    |> validate_required([:dependent_issue_id, :dependency_issue_id, :dependency_policy])
    |> validate_inclusion(:dependency_policy, @policies)
    |> validate_number(:phase, greater_than_or_equal_to: 0)
    |> validate_not_self_dependency()
    |> foreign_key_constraint(:dependent_issue_id)
    |> foreign_key_constraint(:dependency_issue_id)
    |> unique_constraint([:dependent_issue_id, :dependency_issue_id])
  end

  defp validate_not_self_dependency(changeset) do
    dependent_issue_id = get_field(changeset, :dependent_issue_id)
    dependency_issue_id = get_field(changeset, :dependency_issue_id)

    if not is_nil(dependent_issue_id) and dependent_issue_id == dependency_issue_id do
      add_error(changeset, :dependency_issue_id, "cannot depend on itself")
    else
      changeset
    end
  end
end
