defmodule SymphonyElixir.Repositories.Repository do
  @moduledoc """
  A downstream source repository known to Symphony.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @providers ~w(github)
  @visibilities ~w(public private internal)

  @type t :: %__MODULE__{}

  schema "repositories" do
    field(:project_id, :id)
    field(:provider, :string, default: "github")
    field(:owner, :string)
    field(:name, :string)
    field(:default_branch, :string, default: "main")
    field(:visibility, :string)
    field(:external_id, :string)
    field(:url, :string)
    field(:capabilities, :map, default: %{})
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(repository, attrs) when is_map(attrs) do
    repository
    |> cast(attrs, [
      :project_id,
      :provider,
      :owner,
      :name,
      :default_branch,
      :visibility,
      :external_id,
      :url,
      :capabilities,
      :metadata
    ])
    |> validate_required([:provider, :owner, :name, :default_branch, :capabilities, :metadata])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_format(:owner, ~r/^[A-Za-z0-9_.-]+$/)
    |> validate_format(:name, ~r/^[A-Za-z0-9_.-]+$/)
    |> validate_format(:default_branch, ~r/^[A-Za-z0-9_.\/-]+$/)
    |> unique_constraint([:provider, :owner, :name])
  end
end
