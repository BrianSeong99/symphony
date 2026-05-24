defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children =
      maybe_repo_children() ++
        [
          {Phoenix.PubSub, name: SymphonyElixir.PubSub},
          {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ] ++ maybe_orchestrator_children()

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  @doc false
  @spec children_for_test() :: list()
  def children_for_test do
    maybe_repo_children() ++
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        SymphonyElixir.WorkflowStore,
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ] ++ maybe_orchestrator_children()
  end

  defp maybe_repo_children do
    if repo_enabled?() do
      [SymphonyElixir.Repo]
    else
      []
    end
  end

  defp maybe_orchestrator_children do
    if runner_enabled?() do
      [SymphonyElixir.Orchestrator]
    else
      []
    end
  end

  defp repo_enabled? do
    case System.get_env("SYMPHONY_REPO_ENABLED", "true") |> String.downcase() do
      value when value in ["0", "false", "no", "off"] -> false
      _ -> true
    end
  end

  defp runner_enabled? do
    case System.get_env("SYMPHONY_RUNNER_ENABLED", "true") |> String.downcase() do
      value when value in ["0", "false", "no", "off"] -> false
      _ -> true
    end
  end
end
