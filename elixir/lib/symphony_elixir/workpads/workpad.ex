defmodule SymphonyElixir.Workpads.Workpad do
  @moduledoc """
  Local Symphony workpad persisted for one dashboard-first issue.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Workpads

  @type t :: %__MODULE__{}

  schema "workpads" do
    field(:symphony_issue_id, :id)
    field(:body, :string)
    field(:active, :boolean, default: true)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workpad, attrs) when is_map(attrs) do
    workpad
    |> cast(attrs, [:symphony_issue_id, :body, :active, :metadata])
    |> validate_required([:symphony_issue_id, :body, :active, :metadata])
    |> validate_required_sections()
  end

  defp validate_required_sections(changeset) do
    validate_change(changeset, :body, fn :body, body ->
      if Workpads.contains_required_sections?(body) do
        []
      else
        [body: "is missing required workpad sections"]
      end
    end)
  end
end
