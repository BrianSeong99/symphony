defmodule SymphonyElixirWeb.RuntimeApiController do
  @moduledoc """
  Private runtime-console API.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.RuntimeConsole.Api
  alias SymphonyElixirWeb.Endpoint

  @resources %{
    "projects" => :projects,
    "issues" => :issues,
    "milestones" => :milestones,
    "dependencies" => :dependencies,
    "checkpoints" => :checkpoints,
    "runs" => :runs,
    "agents" => :agents,
    "reviews" => :reviews,
    "policies" => :policies
  }

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params), do: json(conn, json_safe(Api.health(api_opts())))

  @spec resource(Conn.t(), map()) :: Conn.t()
  def resource(conn, %{"resource" => resource}) do
    case Map.fetch(@resources, resource) do
      {:ok, resource_key} ->
        json(conn, json_safe(Api.resource(resource_key, api_opts())))

      :error ->
        error_response(conn, 404, "runtime_resource_not_found", "Runtime resource not found")
    end
  end

  @spec relay_events(Conn.t(), map()) :: Conn.t()
  def relay_events(conn, _params), do: json(conn, json_safe(Api.resource(:relay_events, api_opts())))

  @spec projection_preview(Conn.t(), map()) :: Conn.t()
  def projection_preview(conn, params) do
    json(conn, json_safe(Api.projection_preview(params, api_opts())))
  end

  @spec linear_webhook(Conn.t(), map()) :: Conn.t()
  def linear_webhook(conn, params) do
    conn
    |> put_status(202)
    |> json(json_safe(Api.linear_webhook(params, api_opts())))
  end

  defp api_opts do
    [
      runtime_state: Endpoint.config(:runtime_console_state) || %{}
    ]
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp json_safe(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {key, json_safe(nested)} end)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value) when is_boolean(value) or is_nil(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value
end
