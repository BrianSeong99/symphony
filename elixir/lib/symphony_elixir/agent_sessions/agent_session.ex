defmodule SymphonyElixir.AgentSessions.AgentSession do
  @moduledoc """
  Durable local session identity for builder, reviewer, and planner agents.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @roles ~w(builder reviewer planner)
  @backends ~w(claude_code codex manual)
  @statuses ~w(active paused destroyed)

  @type t :: %__MODULE__{}

  schema "agent_sessions" do
    field(:symphony_issue_id, :id)
    field(:role, :string)
    field(:backend, :string)
    field(:session_id, :string)
    field(:status, :string, default: "active")
    field(:workspace_path, :string)
    field(:branch, :string)
    field(:last_active_at, :utc_datetime_usec)
    field(:destroy_reason, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) when is_map(attrs) do
    session
    |> cast(attrs, [
      :symphony_issue_id,
      :role,
      :backend,
      :session_id,
      :status,
      :workspace_path,
      :branch,
      :last_active_at,
      :destroy_reason,
      :metadata
    ])
    |> validate_required([:symphony_issue_id, :role, :backend, :session_id, :status, :metadata])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:backend, @backends)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:symphony_issue_id)
    |> unique_constraint([:role, :session_id])
  end
end
