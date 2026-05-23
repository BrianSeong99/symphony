defmodule SymphonyElixir.Reviews.ReviewFinding do
  @moduledoc """
  Persistent reviewer finding attached to a Symphony issue and optional PR.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @states ~w(open resolved accepted false_positive)
  @severities ~w(low medium high critical)

  @type t :: %__MODULE__{}

  schema "review_findings" do
    field(:symphony_issue_id, :id)
    field(:pr_external_link_id, :id)
    field(:agent_session_id, :id)
    field(:state, :string, default: "open")
    field(:severity, :string, default: "medium")
    field(:title, :string)
    field(:body, :string)
    field(:source_url, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(finding, attrs) when is_map(attrs) do
    finding
    |> cast(attrs, [
      :symphony_issue_id,
      :pr_external_link_id,
      :agent_session_id,
      :state,
      :severity,
      :title,
      :body,
      :source_url,
      :metadata
    ])
    |> validate_required([:symphony_issue_id, :state, :severity, :title, :metadata])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:severity, @severities)
    |> foreign_key_constraint(:symphony_issue_id)
    |> foreign_key_constraint(:pr_external_link_id)
    |> foreign_key_constraint(:agent_session_id)
  end
end
