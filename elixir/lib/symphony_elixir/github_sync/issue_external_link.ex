defmodule SymphonyElixir.GitHubSync.IssueExternalLink do
  @moduledoc """
  Local association from a Symphony issue to a downstream GitHub object.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @providers ~w(github)
  @link_types ~w(github_repo github_issue github_pr github_check github_comment github_review github_milestone)
  @association_strengths ~w(canonical mirror context derived)

  @type t :: %__MODULE__{}

  schema "issue_external_links" do
    field(:symphony_issue_id, :id)
    field(:provider, :string)
    field(:link_type, :string)
    field(:association_strength, :string)
    field(:external_id, :string)
    field(:url, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) when is_map(attrs) do
    link
    |> cast(attrs, [
      :symphony_issue_id,
      :provider,
      :link_type,
      :association_strength,
      :external_id,
      :url,
      :metadata
    ])
    |> validate_required([:symphony_issue_id, :provider, :link_type, :association_strength, :url, :metadata])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:link_type, @link_types)
    |> validate_inclusion(:association_strength, @association_strengths)
    |> foreign_key_constraint(:symphony_issue_id)
  end
end
