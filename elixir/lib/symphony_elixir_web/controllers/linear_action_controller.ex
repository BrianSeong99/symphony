defmodule SymphonyElixirWeb.LinearActionController do
  @moduledoc """
  API endpoint for Linear custom actions.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Linear.Actions
  alias SymphonyElixirWeb.Endpoint

  @spec execute(Conn.t(), map()) :: Conn.t()
  def execute(conn, params) do
    case Actions.handle(params, action_opts(conn)) do
      {:ok, result} ->
        conn
        |> put_status(result.http_status)
        |> json(linear_response(result))

      {:error, result} ->
        conn
        |> put_status(result.http_status)
        |> json(linear_response(result))
    end
  end

  defp action_opts(conn) do
    [
      token: Endpoint.config(:linear_action_token),
      headers: conn.req_headers,
      runner: Endpoint.config(:linear_action_runner) || fn _command, _context -> {:ok, %{queued: true}} end
    ]
  end

  defp linear_response(result) do
    result
    |> Map.take([:status, :action, :reason, :summary, :policy, :runtime, :amendment, :merge_handoff, :simulation])
    |> stringify_reason()
  end

  defp stringify_reason(%{reason: reason} = result), do: %{result | reason: reason_to_string(reason)}
  defp stringify_reason(result), do: result

  defp reason_to_string({reason, values}) when is_atom(reason), do: "#{reason}:#{Enum.join(values, ",")}"
  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason), do: inspect(reason)
end
