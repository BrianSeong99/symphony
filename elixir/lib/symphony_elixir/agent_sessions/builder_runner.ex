defmodule SymphonyElixir.AgentSessions.BuilderRunner do
  @moduledoc """
  Persistent builder runner contract for dashboard-first Symphony issues.
  """

  alias SymphonyElixir.AgentSessions

  @spec run(map(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(issue, existing_sessions, opts \\ []) when is_map(issue) and is_list(existing_sessions) do
    base_branch = Keyword.get(opts, :base_branch, "origin/main")

    with :ok <- AgentSessions.validate_main_base(base_branch) do
      runner = Keyword.get(opts, :runner, fn _command -> {:ok, %{}} end)
      {mode, session} = AgentSessions.ensure_builder_session(issue, existing_sessions, session_attrs(issue, opts))
      command = command(mode, session, issue, base_branch)

      case runner.(command) do
        {:ok, response} -> {:ok, %{mode: mode, session: session, command: command, response: response}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp session_attrs(issue, opts) do
    %{
      branch: Keyword.get(opts, :branch),
      workspace_path: Keyword.get(opts, :workspace_path),
      metadata: %{
        "issue_title" => Map.get(issue, :title),
        "public_output_rules" => AgentSessions.public_output_rules()
      },
      reason: Keyword.get(opts, :reason, :retry)
    }
  end

  defp command(mode, session, issue, base_branch) do
    %{
      mode: mode,
      backend: session.backend,
      session_id: session.session_id,
      session_name: session.metadata["session_name"],
      symphony_issue_id: session.symphony_issue_id,
      base_branch: base_branch,
      branch: session.branch,
      workspace_path: session.workspace_path,
      issue: issue,
      public_output_rules: AgentSessions.public_output_rules()
    }
  end
end
