defmodule SymphonyElixirWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Health

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    result = Health.check()
    status = if Health.healthy?(result), do: :ok, else: :service_unavailable

    conn
    |> put_status(status)
    |> json(result)
  end
end
