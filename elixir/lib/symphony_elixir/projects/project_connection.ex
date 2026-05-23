defmodule SymphonyElixir.Projects.ProjectConnection do
  @moduledoc """
  Optional downstream integration policy for a local Symphony project.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Projects

  @providers ~w(github manual)
  @statuses ~w(active paused disabled)

  @type t :: %__MODULE__{}

  schema "project_connections" do
    field(:provider, :string)
    field(:connection_mode, :string)
    field(:owner, :string)
    field(:repo, :string)
    field(:status, :string, default: "active")
    field(:capabilities, :map, default: %{})
    field(:settings, :map, default: %{})

    belongs_to(:project, Projects.Project)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(connection, attrs) when is_map(attrs) do
    connection
    |> cast(attrs, [:project_id, :provider, :connection_mode, :owner, :repo, :status, :capabilities, :settings])
    |> validate_required([:project_id, :provider, :connection_mode, :status])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:connection_mode, Projects.connection_mode_strings())
    |> validate_inclusion(:status, @statuses)
    |> validate_github_repo_fields()
    |> foreign_key_constraint(:project_id)
  end

  defp validate_github_repo_fields(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :provider) do
      "github" ->
        changeset
        |> validate_required([:owner, :repo])
        |> validate_format(:owner, ~r/^[A-Za-z0-9_.-]+$/)
        |> validate_format(:repo, ~r/^[A-Za-z0-9_.-]+$/)

      _ ->
        changeset
    end
  end
end
