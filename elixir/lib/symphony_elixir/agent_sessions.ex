defmodule SymphonyElixir.AgentSessions do
  @moduledoc """
  Durable session lifecycle helpers for persistent Symphony agents.
  """

  alias SymphonyElixir.AgentSessions.AgentSession

  @terminal_issue_statuses ~w(done cancelled merged)
  @terminal_pr_states ~w(merged closed)
  @allowed_base_branches ~w(origin/main brian/main main)
  @public_output_rules [
    "Do not add public generation attribution.",
    "Do not mention assistant tooling in commits, pull requests, issues, or comments.",
    "Use Brian's normal commit and pull request style."
  ]

  @spec public_output_rules() :: [String.t()]
  def public_output_rules, do: @public_output_rules

  @spec ensure_builder_session(term(), [AgentSession.t()], map()) :: {:create | :resume, AgentSession.t()}
  def ensure_builder_session(issue, sessions, attrs \\ %{}) when is_list(sessions) and is_map(attrs) do
    issue_id = issue_id(issue)

    case find_active_builder(sessions, issue_id) do
      nil ->
        metadata =
          attrs
          |> Map.get(:metadata, %{})
          |> Map.put_new("session_name", Map.get(attrs, :session_name, issue_session_name(issue, "Builder")))

        {:create,
         new_session(
           "builder",
           issue_id,
           Map.merge(attrs, %{
             backend: Map.get(attrs, :backend, "claude_code"),
             session_id: Map.get(attrs, :session_id, "builder:#{issue_id}"),
             metadata: metadata
           })
         )}

      session ->
        {:resume, mark_resumed(session, attrs)}
    end
  end

  @spec ensure_reviewer_session(String.t(), [AgentSession.t()], map()) :: {:create | :resume, AgentSession.t()}
  def ensure_reviewer_session(pr_key, sessions, attrs \\ %{}) when is_binary(pr_key) and is_list(sessions) do
    case find_active_reviewer(sessions, pr_key) do
      nil ->
        metadata =
          attrs
          |> Map.get(:metadata, %{})
          |> Map.put("pr_key", pr_key)
          |> Map.put_new("session_name", Map.get(attrs, :session_name, "#{pr_key} Symphony Reviewer"))

        {:create,
         new_session(
           "reviewer",
           Map.fetch!(attrs, :symphony_issue_id),
           Map.merge(attrs, %{
             backend: Map.get(attrs, :backend, "codex"),
             session_id: Map.get(attrs, :session_id, "reviewer:#{pr_key}"),
             metadata: metadata
           })
         )}

      session ->
        {:resume, mark_resumed(session, attrs)}
    end
  end

  @spec rehydrate_active_sessions([AgentSession.t()]) :: [AgentSession.t()]
  def rehydrate_active_sessions(sessions) when is_list(sessions) do
    Enum.filter(sessions, &(&1.status == "active"))
  end

  @spec destroy_issue_sessions([AgentSession.t()], String.t()) :: [AgentSession.t()]
  def destroy_issue_sessions(sessions, issue_status) when is_list(sessions) and is_binary(issue_status) do
    if issue_status in @terminal_issue_statuses do
      Enum.map(sessions, &destroy_session(&1, "issue #{issue_status}"))
    else
      sessions
    end
  end

  @spec destroy_pr_sessions([AgentSession.t()], String.t()) :: [AgentSession.t()]
  def destroy_pr_sessions(sessions, pr_state) when is_list(sessions) and is_binary(pr_state) do
    if pr_state in @terminal_pr_states do
      Enum.map(sessions, &destroy_session(&1, "pr #{pr_state}"))
    else
      sessions
    end
  end

  @spec destroy_session(AgentSession.t(), String.t()) :: AgentSession.t()
  def destroy_session(%AgentSession{} = session, reason) when is_binary(reason) do
    %{session | status: "destroyed", destroy_reason: reason}
  end

  @spec valid_main_base?(String.t()) :: boolean()
  def valid_main_base?(base_branch) when is_binary(base_branch) do
    base_branch in @allowed_base_branches
  end

  @spec validate_main_base(String.t()) :: :ok | {:error, {:invalid_base_branch, String.t()}}
  def validate_main_base(base_branch) when is_binary(base_branch) do
    case valid_main_base?(base_branch) do
      true -> :ok
      false -> {:error, {:invalid_base_branch, base_branch}}
    end
  end

  defp find_active_builder(sessions, issue_id) do
    Enum.find(sessions, &(&1.status == "active" and &1.role == "builder" and &1.symphony_issue_id == issue_id))
  end

  defp find_active_reviewer(sessions, pr_key) do
    Enum.find(sessions, fn session ->
      session.status == "active" and session.role == "reviewer" and session.metadata["pr_key"] == pr_key
    end)
  end

  defp new_session(role, issue_id, attrs) do
    %AgentSession{
      symphony_issue_id: issue_id,
      role: role,
      backend: Map.fetch!(attrs, :backend),
      session_id: Map.fetch!(attrs, :session_id),
      status: "active",
      workspace_path: Map.get(attrs, :workspace_path),
      branch: Map.get(attrs, :branch),
      last_active_at: DateTime.utc_now(),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp mark_resumed(%AgentSession{} = session, attrs) do
    metadata =
      session.metadata
      |> Map.put("resume_reason", attrs |> Map.get(:reason, :retry) |> Atom.to_string())

    %{session | metadata: metadata, last_active_at: DateTime.utc_now()}
  end

  defp issue_id(%{id: id}), do: id
  defp issue_id(id), do: id

  defp issue_session_name(%{identifier: identifier}, role) when is_binary(identifier) do
    "#{identifier} Symphony #{role}"
  end

  defp issue_session_name(_issue, role), do: "Symphony #{role}"
end
