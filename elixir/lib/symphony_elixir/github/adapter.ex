defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues tracker adapter.

  This adapter is intentionally label-scoped. Symphony only picks open GitHub
  issues that match configured `tracker.active_labels`, writes one durable run
  log comment marked with an HTML marker, and closes the issue for terminal
  states. It lets a project switch between Linear and GitHub without changing
  the orchestrator.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Linear.Issue}

  @run_log_marker "<!-- symphony-run-log -->"
  @terminal_states ~w(closed done cancelled canceled duplicate)

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, issues} <- list_issues("open") do
      {:ok, Enum.filter(issues, &candidate_issue?/1)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    if terminal_state_query?(state_names) do
      list_issues("closed")
    else
      fetch_candidate_issues()
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.map(&issue_number/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&view_issue/1)
    |> collect_results()
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    run_gh(["issue", "comment", issue_number!(issue_id), "--repo", repository(), "--body", body])
  end

  @spec upsert_run_log_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def upsert_run_log_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    number = issue_number!(issue_id)
    body = initial_run_log_body(body)

    with {:ok, comment_id} <- find_run_log_comment(number) do
      case comment_id do
        nil -> create_comment(number, body)
        id -> update_comment(id, body)
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    if terminal_state?(state_name) do
      run_gh(["issue", "close", issue_number!(issue_id), "--repo", repository(), "--comment", "Symphony marked this issue #{state_name}."])
    else
      create_comment(issue_id, "Symphony state update: #{state_name}")
    end
  end

  @spec normalize_issue(map()) :: Issue.t()
  def normalize_issue(%{} = issue) do
    labels = issue |> Map.get("labels", []) |> Enum.map(&Map.get(&1, "name")) |> Enum.reject(&is_nil/1)
    number = Map.fetch!(issue, "number")
    state = github_state(issue)

    %Issue{
      id: to_string(number),
      identifier: "GH-#{number}",
      title: Map.get(issue, "title"),
      description: Map.get(issue, "body"),
      state: state,
      url: Map.get(issue, "url"),
      labels: labels,
      assignee_id: assignee_id(issue),
      assigned_to_worker: true,
      created_at: parse_datetime(Map.get(issue, "createdAt")),
      updated_at: parse_datetime(Map.get(issue, "updatedAt"))
    }
  end

  defp list_issues(state) do
    args =
      ["issue", "list", "--repo", repository(), "--state", state, "--limit", "100"] ++
        label_args(active_labels()) ++
        ["--json", "number,title,body,state,labels,assignees,url,createdAt,updatedAt"]

    with {:ok, output} <- run_gh_json(args),
         {:ok, issues} when is_list(issues) <- Jason.decode(output) do
      {:ok, Enum.map(issues, &normalize_issue/1)}
    else
      {:ok, _other} -> {:error, :github_issue_list_unexpected_payload}
      {:error, {:github_cli_failed, status, output}} -> {:error, {:github_issue_list_failed, status, output}}
      {:error, reason} -> {:error, {:github_issue_list_failed, reason}}
    end
  end

  defp view_issue(number) do
    args = ["issue", "view", number, "--repo", repository(), "--json", "number,title,body,state,labels,assignees,url,createdAt,updatedAt"]

    with {:ok, output} <- run_gh_json(args),
         {:ok, issue} when is_map(issue) <- Jason.decode(output) do
      {:ok, normalize_issue(issue)}
    else
      {:ok, _other} -> {:error, :github_issue_view_unexpected_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_run_log_comment(number) do
    args = ["api", "repos/#{repository()}/issues/#{number}/comments", "--paginate", "--jq", ".[] | select(.body | contains(\"#{@run_log_marker}\")) | .id"]

    case run_gh_json(args) do
      {:ok, output} ->
        comment_id =
          output
          |> String.split("\n", trim: true)
          |> List.first()

        {:ok, comment_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_comment(comment_id, body) do
    run_gh(["api", "--method", "PATCH", "repos/#{repository()}/issues/comments/#{comment_id}", "-f", "body=#{body}"])
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, issue}, {:ok, issues} -> {:cont, {:ok, [issue | issues]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp candidate_issue?(%Issue{state: "Done"}), do: false
  defp candidate_issue?(%Issue{labels: labels}), do: active_labels() == [] or Enum.all?(active_labels(), &(&1 in labels))

  defp terminal_state_query?(state_names), do: Enum.any?(state_names, &terminal_state?/1)

  defp terminal_state?(state_name) when is_binary(state_name) do
    normalized =
      state_name
      |> String.downcase()
      |> String.trim()

    normalized in @terminal_states
  end

  defp terminal_state?(_state_name), do: false

  defp github_state(%{"state" => "CLOSED"}), do: "Done"
  defp github_state(%{"state" => "closed"}), do: "Done"
  defp github_state(_issue), do: "Todo"

  defp assignee_id(%{"assignees" => [assignee | _]}), do: Map.get(assignee, "login")
  defp assignee_id(_issue), do: nil

  defp label_args(labels), do: Enum.flat_map(labels, &["--label", &1])

  defp active_labels, do: Config.settings!().tracker.active_labels || []
  defp repository, do: Config.settings!().tracker.repository

  defp issue_number!(issue_id), do: issue_number(issue_id) || raise(ArgumentError, "invalid GitHub issue id: #{inspect(issue_id)}")

  defp issue_number(issue_id) when is_binary(issue_id) do
    issue_id
    |> String.trim()
    |> String.trim_leading("GH-")
    |> Integer.parse()
    |> case do
      {number, ""} when number > 0 -> Integer.to_string(number)
      _ -> nil
    end
  end

  defp initial_run_log_body(body), do: @run_log_marker <> "\n" <> body

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp run_gh(args) do
    case command_runner().(args) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:github_cli_failed, status, output}}
    end
  end

  defp run_gh_json(args) do
    case command_runner().(args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:github_cli_failed, status, output}}
    end
  end

  defp command_runner do
    Application.get_env(:symphony_elixir, :github_command_runner, fn args ->
      System.cmd("gh", args, stderr_to_stdout: true)
    end)
  end
end
