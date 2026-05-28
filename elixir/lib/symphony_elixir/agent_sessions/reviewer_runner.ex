defmodule SymphonyElixir.AgentSessions.ReviewerRunner do
  @moduledoc """
  Persistent reviewer runner contract for PR-scoped Codex review sessions.
  """

  alias SymphonyElixir.AgentSessions

  @spec run(map(), list(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(pr, existing_sessions, opts \\ []) when is_map(pr) and is_list(existing_sessions) do
    runner = Keyword.get(opts, :runner, fn _command -> {:ok, %{}} end)
    pr_key = pr_key(pr)

    {mode, session} =
      AgentSessions.ensure_reviewer_session(pr_key, existing_sessions, %{
        symphony_issue_id: Map.fetch!(pr, :symphony_issue_id),
        reason: Keyword.get(opts, :reason, :pr_update)
      })

    command = command(mode, session, pr, pr_key)

    case runner.(command) do
      {:ok, response} -> {:ok, %{mode: mode, session: session, command: command, response: response}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pr_key(pr) do
    "#{Map.fetch!(pr, :owner)}/#{Map.fetch!(pr, :repo)}##{Map.fetch!(pr, :number)}"
  end

  defp command(mode, session, pr, pr_key) do
    %{
      mode: mode,
      backend: session.backend,
      session_id: session.session_id,
      session_name: session.metadata["session_name"],
      symphony_issue_id: session.symphony_issue_id,
      pr_key: pr_key,
      pr: pr
    }
  end
end
