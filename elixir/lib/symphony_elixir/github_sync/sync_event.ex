defmodule SymphonyElixir.GitHubSync.SyncEvent do
  @moduledoc """
  Audit record for one attempted downstream sync operation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @providers ~w(github)
  @statuses ~w(pending success error skipped)

  @type t :: %__MODULE__{}

  schema "sync_events" do
    field(:project_id, :id)
    field(:symphony_issue_id, :id)
    field(:provider, :string)
    field(:action, :string)
    field(:status, :string)
    field(:request, :map, default: %{})
    field(:response, :map, default: %{})
    field(:error, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) when is_map(attrs) do
    event
    |> cast(attrs, [
      :project_id,
      :symphony_issue_id,
      :provider,
      :action,
      :status,
      :request,
      :response,
      :error
    ])
    |> validate_required([:provider, :action, :status, :request, :response])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:symphony_issue_id)
  end
end
