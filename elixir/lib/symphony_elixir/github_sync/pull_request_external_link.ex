defmodule SymphonyElixir.GitHubSync.PullRequestExternalLink do
  @moduledoc """
  Local association from a Symphony issue to a downstream GitHub pull request.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @providers ~w(github)
  @statuses ~w(open closed merged draft)

  @type t :: %__MODULE__{}

  schema "pr_external_links" do
    field(:symphony_issue_id, :id)
    field(:repository_id, :id)
    field(:provider, :string, default: "github")
    field(:external_id, :string)
    field(:number, :integer)
    field(:url, :string)
    field(:branch, :string)
    field(:status, :string, default: "open")
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) when is_map(attrs) do
    link
    |> cast(attrs, [
      :symphony_issue_id,
      :repository_id,
      :provider,
      :external_id,
      :number,
      :url,
      :branch,
      :status,
      :metadata
    ])
    |> validate_required([:symphony_issue_id, :provider, :url, :status, :metadata])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:number, greater_than: 0)
    |> foreign_key_constraint(:symphony_issue_id)
    |> foreign_key_constraint(:repository_id)
  end
end
