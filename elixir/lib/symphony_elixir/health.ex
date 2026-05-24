defmodule SymphonyElixir.Health do
  @moduledoc """
  Runtime health checks for the Symphony service.
  """

  alias SymphonyElixir.Repo

  @type check_result :: %{
          required(:status) => String.t(),
          required(:checks) => map()
        }

  @spec check() :: check_result()
  def check, do: check([])

  @spec check(keyword()) :: check_result()
  def check(opts) when is_list(opts) do
    checks =
      %{app: app_check()}
      |> maybe_put_database_check(Keyword.get(opts, :repo, Repo))

    %{
      status: status_for(checks),
      checks: checks
    }
  end

  @spec healthy?(check_result()) :: boolean()
  def healthy?(%{status: "ok"}), do: true
  def healthy?(_result), do: false

  defp app_check do
    if Application.started_applications() |> Enum.any?(fn {app, _description, _version} -> app == :symphony_elixir end) do
      %{status: "ok"}
    else
      %{status: "error", error: "application_not_started"}
    end
  end

  defp maybe_put_database_check(checks, repo) do
    if repo_enabled?() do
      Map.put(checks, :database, database_check(repo))
    else
      Map.put(checks, :database, %{status: "skipped", reason: "repo_disabled"})
    end
  end

  defp database_check(repo) do
    case repo.query("SELECT 1", [], timeout: 2_000) do
      {:ok, _result} -> %{status: "ok"}
      {:error, reason} -> %{status: "error", error: inspect(reason)}
    end
  rescue
    error -> %{status: "error", error: Exception.message(error)}
  catch
    :exit, reason -> %{status: "error", error: inspect(reason)}
  end

  defp status_for(checks) do
    if Enum.all?(checks, fn {_name, check} -> check.status in ["ok", "skipped"] end) do
      "ok"
    else
      "error"
    end
  end

  defp repo_enabled? do
    case System.get_env("SYMPHONY_REPO_ENABLED", "true") |> String.downcase() do
      value when value in ["0", "false", "no", "off"] -> false
      _ -> true
    end
  end
end
