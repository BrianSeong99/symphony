defmodule SymphonyElixir.Projects.Project do
  @moduledoc """
  A local Symphony project.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @workspaces ~w(miden chainless wprc personal labs)
  @risk_policies ~w(low medium high critical)
  @statuses ~w(active paused archived)

  @type t :: %__MODULE__{}

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:workspace, :string)
    field(:status, :string, default: "active")
    field(:risk_policy, :string, default: "medium")
    field(:settings, :map, default: %{})

    has_many(:connections, SymphonyElixir.Projects.ProjectConnection)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) when is_map(attrs) do
    project
    |> cast(attrs, [:name, :slug, :workspace, :status, :risk_policy, :settings])
    |> put_slug_from_name()
    |> validate_required([:name, :slug, :workspace, :status, :risk_policy])
    |> validate_inclusion(:workspace, @workspaces)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:risk_policy, @risk_policies)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> unique_constraint(:slug)
  end

  defp put_slug_from_name(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) -> put_change(changeset, :slug, slugify(name))
      {"", name} when is_binary(name) -> put_change(changeset, :slug, slugify(name))
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
