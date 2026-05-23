defmodule SymphonyElixir.Repo do
  @moduledoc """
  Local durable store for dashboard-first Symphony orchestration state.
  """

  use Ecto.Repo,
    otp_app: :symphony_elixir,
    adapter: Ecto.Adapters.Postgres
end
