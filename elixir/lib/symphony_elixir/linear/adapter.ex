defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @run_log_marker "<!-- symphony-run-log -->"
  @max_run_log_comment_bytes 40_000

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @run_log_comment_query """
  query SymphonyRunLogComment($issueId: String!, $after: String) {
    issue(id: $issueId) {
      comments(first: 50, after: $after) {
        nodes {
          id
          body
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}, skipEditedAt: true) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec upsert_run_log_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def upsert_run_log_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, existing_comment} <- find_run_log_comment(issue_id) do
      case existing_comment do
        %{id: comment_id, body: existing_body} when is_binary(comment_id) ->
          upsert_existing_run_log_comment(issue_id, comment_id, existing_body, body)

        nil ->
          create_comment(issue_id, initial_run_log_body(body))
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp find_run_log_comment(issue_id), do: find_run_log_comment(issue_id, nil)

  defp find_run_log_comment(issue_id, after_cursor) do
    with {:ok, response} <-
           client_module().graphql(@run_log_comment_query, %{issueId: issue_id, after: after_cursor}) do
      response
      |> get_in(["data", "issue", "comments"])
      |> case do
        %{"nodes" => nodes} = comments when is_list(nodes) ->
          run_log_comment_from_page(issue_id, nodes, Map.get(comments, "pageInfo", %{}))

        _ ->
          {:error, :comment_lookup_failed}
      end
    end
  end

  defp run_log_comment_from_page(issue_id, nodes, page_info) do
    case find_run_log_marker(nodes) do
      %{id: _id, body: _body} = comment ->
        {:ok, comment}

      nil ->
        next_run_log_comment_page(issue_id, page_info)
    end
  end

  defp next_run_log_comment_page(issue_id, %{"hasNextPage" => true, "endCursor" => end_cursor})
       when is_binary(end_cursor) do
    find_run_log_comment(issue_id, end_cursor)
  end

  defp next_run_log_comment_page(_issue_id, _page_info), do: {:ok, nil}

  defp find_run_log_marker(nodes) do
    Enum.find_value(nodes, fn
      %{"id" => id, "body" => body} when is_binary(id) and is_binary(body) ->
        if String.contains?(body, @run_log_marker) and reusable_run_log_body?(body) do
          %{id: id, body: body}
        end

      _ ->
        nil
    end)
  end

  defp reusable_run_log_body?(body) when is_binary(body) do
    byte_size(body) < @max_run_log_comment_bytes
  end

  defp upsert_existing_run_log_comment(issue_id, comment_id, existing_body, body) do
    next_body = append_run_log_body(existing_body, body)

    if reusable_run_log_body?(next_body) do
      case update_comment(comment_id, next_body) do
        :ok -> :ok
        {:error, :comment_update_failed} -> create_comment(issue_id, continued_run_log_body(body))
        {:error, reason} -> {:error, reason}
      end
    else
      create_comment(issue_id, continued_run_log_body(body))
    end
  end

  defp update_comment(comment_id, body) do
    with {:ok, response} <-
           client_module().graphql(@update_comment_mutation, %{commentId: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  defp initial_run_log_body(body) do
    Enum.join([@run_log_marker, "### Symphony run log", "", body], "\n")
  end

  defp continued_run_log_body(body) do
    Enum.join([@run_log_marker, "### Symphony run log continued", "", body], "\n")
  end

  defp append_run_log_body(existing_body, body) when is_binary(existing_body) do
    Enum.join([existing_body, "", "---", "", body], "\n")
  end
end
