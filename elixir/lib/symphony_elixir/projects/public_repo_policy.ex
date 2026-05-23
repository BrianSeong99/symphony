defmodule SymphonyElixir.Projects.PublicRepoPolicy do
  @moduledoc """
  Guards downstream GitHub mutations for public or company-owned repositories.
  """

  alias SymphonyElixir.Projects.{Project, ProjectConnection}

  @type action ::
          :create_label
          | :create_milestone
          | :sync_workpad_comment
          | :edit_issue_body
          | :public_comment
          | :associate_pr

  @type decision ::
          {:allow, atom()}
          | {:block, atom()}
          | {:block, {:missing_capability, String.t()}}
          | {:block, {:unsupported_action, term()}}

  @actions [
    :create_label,
    :create_milestone,
    :sync_workpad_comment,
    :edit_issue_body,
    :public_comment,
    :associate_pr
  ]

  @miden_block_reasons %{
    create_label: :miden_public_labels_disabled,
    create_milestone: :miden_public_milestones_disabled,
    sync_workpad_comment: :miden_public_workpad_comments_disabled,
    edit_issue_body: :miden_issue_body_rewrites_disabled,
    public_comment: :miden_public_comments_require_approval
  }

  @issue_metadata_actions [
    :create_label,
    :create_milestone,
    :sync_workpad_comment,
    :edit_issue_body,
    :public_comment
  ]

  @pr_modes ~w(pr_only issue_mirror full_sync)

  @spec evaluate(action(), Project.t() | map(), ProjectConnection.t() | map()) :: decision()
  def evaluate(action, project, connection), do: evaluate(action, project, connection, [])

  @spec evaluate(action(), Project.t() | map(), ProjectConnection.t() | map(), keyword() | map()) ::
          decision()
  def evaluate(action, _project, _connection, _opts) when action not in @actions do
    {:block, {:unsupported_action, action}}
  end

  def evaluate(action, project, connection, opts) do
    opts = Map.new(opts)

    cond do
      github_connection?(connection) == false ->
        {:block, :non_github_connection}

      connection_status(connection) != "active" ->
        {:block, :connection_inactive}

      miden_workspace?(project) ->
        evaluate_miden(action, connection, opts)

      action == :associate_pr ->
        evaluate_pr_association(connection)

      action in @issue_metadata_actions ->
        evaluate_full_sync_mutation(action, connection)
    end
  end

  @spec miden_block_reasons() :: [atom()]
  def miden_block_reasons do
    @miden_block_reasons
    |> Map.values()
    |> Enum.uniq()
  end

  defp evaluate_miden(:associate_pr, connection, opts) do
    cond do
      explicit?(opts, :explicit_pr_association) == false ->
        {:block, :explicit_pr_association_required}

      pr_mode?(connection) == false ->
        {:block, :connection_mode_does_not_support_prs}

      true ->
        with {:allow, :capability_present} <- require_capability(connection, ["create_prs", "read_prs"]) do
          {:allow, :explicit_pr_association}
        end
    end
  end

  defp evaluate_miden(:public_comment, connection, opts) do
    case explicit?(opts, :explicit_public_comment) do
      true ->
        with {:allow, :capability_present} <- require_capability(connection, "comment") do
          {:allow, :explicit_public_comment}
        end

      false ->
        {:block, Map.fetch!(@miden_block_reasons, :public_comment)}
    end
  end

  defp evaluate_miden(action, _connection, _opts) do
    {:block, Map.fetch!(@miden_block_reasons, action)}
  end

  defp evaluate_pr_association(connection) do
    case pr_mode?(connection) do
      true -> require_capability(connection, ["create_prs", "read_prs"])
      false -> {:block, :connection_mode_does_not_support_prs}
    end
  end

  defp evaluate_full_sync_mutation(action, connection) do
    case connection_mode(connection) do
      "full_sync" -> require_capability(connection, required_capability(action))
      _ -> {:block, :connection_mode_does_not_support_issue_mutation}
    end
  end

  defp required_capability(:create_label), do: "create_labels"
  defp required_capability(:create_milestone), do: "edit_milestones"
  defp required_capability(:sync_workpad_comment), do: "comment"
  defp required_capability(:edit_issue_body), do: "edit_issues"
  defp required_capability(:public_comment), do: "comment"

  defp require_capability(connection, capabilities) when is_list(capabilities) do
    case Enum.find(capabilities, &capability_enabled?(connection, &1)) do
      nil -> {:block, {:missing_capability, List.first(capabilities)}}
      _capability -> {:allow, :capability_present}
    end
  end

  defp require_capability(connection, capability) when is_binary(capability) do
    case capability_enabled?(connection, capability) do
      true -> {:allow, :capability_present}
      false -> {:block, {:missing_capability, capability}}
    end
  end

  defp capability_enabled?(connection, capability) do
    connection
    |> field(:capabilities, %{})
    |> Map.get(capability, false)
  end

  defp github_connection?(connection), do: field(connection, :provider) == "github"

  defp miden_workspace?(project), do: field(project, :workspace) == "miden"

  defp pr_mode?(connection), do: connection_mode(connection) in @pr_modes

  defp connection_mode(connection), do: field(connection, :connection_mode)

  defp connection_status(connection), do: field(connection, :status)

  defp explicit?(opts, key), do: Map.get(opts, key, false) == true

  defp field(struct_or_map, key, default), do: Map.get(struct_or_map, key, default)

  defp field(struct_or_map, key), do: field(struct_or_map, key, nil)
end
