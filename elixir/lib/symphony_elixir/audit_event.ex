defmodule SymphonyElixir.AuditEvent do
  @moduledoc """
  Generic local audit event for Symphony runtime decisions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field(:project_id, :id)
    field(:symphony_issue_id, :id)
    field(:actor, :string)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:payload, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) when is_map(attrs) do
    event
    |> cast(attrs, [
      :project_id,
      :symphony_issue_id,
      :actor,
      :action,
      :target_type,
      :target_id,
      :payload
    ])
    |> validate_required([:actor, :action, :payload])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:symphony_issue_id)
  end
end
