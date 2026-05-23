defmodule SymphonyElixir.GitHubSync do
  @moduledoc """
  Deterministic planner/executor for optional downstream GitHub sync.
  """

  alias SymphonyElixir.Projects.PublicRepoPolicy

  @type association :: %{
          required(:link_type) => String.t(),
          required(:association_strength) => String.t(),
          required(:url) => String.t(),
          optional(:external_id) => String.t(),
          optional(:metadata) => map()
        }

  @type operation :: %{
          required(:action) => String.t(),
          required(:kind) => :mutation | :ingestion,
          required(:request) => map(),
          optional(:required_capability) => String.t() | [String.t()],
          optional(:policy_action) => atom(),
          optional(:policy_opts) => keyword()
        }

  @type plan :: %{
          required(:mode) => String.t(),
          required(:provider) => String.t(),
          required(:associations) => [association()],
          required(:operations) => [operation()]
        }

  @spec plan(map(), map()) :: plan()
  def plan(connection, context), do: plan(connection, context, [])

  @spec plan(map(), map(), keyword()) :: plan()
  def plan(connection, context, opts) when is_map(context) and is_list(opts) do
    mode = field(connection, :connection_mode, "none")

    %{
      mode: mode,
      provider: field(connection, :provider, "github"),
      associations: associations_for(mode, connection, context),
      operations: operations_for(mode, context)
    }
  end

  @spec execute(map(), map()) :: map()
  def execute(connection, context), do: execute(connection, context, [])

  @spec execute(map(), map(), keyword()) :: map()
  def execute(connection, context, opts) when is_map(context) and is_list(opts) do
    plan = plan(connection, context, opts)
    performer = Keyword.get(opts, :performer, fn _operation -> {:ok, %{}} end)
    project = Keyword.get(opts, :project) || Map.get(context, :project)

    {performed, capability_issues, sync_events} =
      Enum.reduce(plan.operations, {[], [], []}, fn operation, {performed, issues, events} ->
        case operation_allowed?(operation, project, connection) do
          :ok ->
            {status, response, error} = perform(operation, performer)

            event = sync_event(operation, context, status, response, error)
            {[operation | performed], issues, [event | events]}

          {:skip, reason} ->
            issue = Map.merge(operation, %{reason: reason})
            event = sync_event(operation, context, "skipped", %{}, inspect(reason))
            {performed, [issue | issues], [event | events]}
        end
      end)

    %{
      plan: plan,
      performed: Enum.reverse(performed),
      capability_issues: Enum.reverse(capability_issues),
      sync_events: Enum.reverse(sync_events)
    }
  end

  defp associations_for("none", _connection, _context), do: []

  defp associations_for("context_only", connection, context) do
    [
      repo_association(connection),
      url_association(context, :github_issue_url, "github_issue"),
      url_association(context, :github_pr_url, "github_pr"),
      url_association(context, :github_milestone_url, "github_milestone")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp associations_for("pr_only", connection, context), do: pr_associations(connection, context)

  defp associations_for("issue_mirror", connection, context) do
    [repo_association(connection), url_association(context, :github_issue_url, "github_issue")]
    |> Enum.reject(&is_nil/1)
  end

  defp associations_for("full_sync", connection, context) do
    (pr_associations(connection, context) ++
       [
         url_association(context, :github_issue_url, "github_issue"),
         url_association(context, :github_milestone_url, "github_milestone")
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp associations_for(_mode, _connection, _context), do: []

  defp pr_associations(connection, context) do
    [repo_association(connection), pr_association(connection, context)]
    |> Enum.reject(&is_nil/1)
  end

  defp repo_association(connection) do
    owner = field(connection, :owner)
    repo = field(connection, :repo)

    if present?(owner) and present?(repo) do
      %{
        link_type: "github_repo",
        association_strength: "context",
        external_id: "#{owner}/#{repo}",
        url: "https://github.com/#{owner}/#{repo}",
        metadata: %{}
      }
    end
  end

  defp url_association(context, key, link_type) do
    case map_get(context, key) do
      url when is_binary(url) and url != "" ->
        %{link_type: link_type, association_strength: "context", url: url, metadata: %{}}

      _ ->
        nil
    end
  end

  defp pr_association(connection, context) do
    cond do
      present?(map_get(context, :github_pr_url)) ->
        url_association(context, :github_pr_url, "github_pr")

      present?(map_get(context, :github_pr_number)) ->
        number = map_get(context, :github_pr_number)

        %{
          link_type: "github_pr",
          association_strength: "context",
          external_id: to_string(number),
          url: github_url(connection, "pull/#{number}"),
          metadata: %{"number" => number}
        }

      true ->
        nil
    end
  end

  defp operations_for("pr_only", context) do
    [
      operation("ingest_checks", :ingestion, "read_checks", pr_request(context)),
      operation("ingest_reviews", :ingestion, "read_reviews", pr_request(context))
    ]
  end

  defp operations_for("issue_mirror", context) do
    [
      operation("sync_issue", :mutation, "create_issues", issue_request(context), :edit_issue_body)
    ]
  end

  defp operations_for("full_sync", context) do
    [
      operation("sync_issue", :mutation, "create_issues", issue_request(context), :edit_issue_body),
      operation("sync_labels", :mutation, "create_labels", labels_request(context), :create_label),
      operation(
        "sync_milestone",
        :mutation,
        "edit_milestones",
        milestone_request(context),
        :create_milestone
      ),
      operation(
        "sync_workpad_comment",
        :mutation,
        "comment",
        workpad_comment_request(context),
        :sync_workpad_comment
      ),
      operation(
        "sync_pr_link",
        :mutation,
        ["create_prs", "read_prs"],
        pr_request(context),
        :associate_pr,
        explicit_pr_association: explicit?(context, :explicit_pr_association)
      ),
      operation(
        "sync_review_state",
        :mutation,
        "comment",
        review_state_request(context),
        :public_comment,
        explicit_public_comment: explicit?(context, :explicit_public_comment)
      ),
      operation("ingest_checks", :ingestion, "read_checks", pr_request(context)),
      operation("ingest_reviews", :ingestion, "read_reviews", pr_request(context))
    ]
  end

  defp operations_for(_mode, _context), do: []

  defp operation(action, kind, capability, request, policy_action \\ nil, policy_opts \\ []) do
    %{
      action: action,
      kind: kind,
      required_capability: capability,
      request: request,
      policy_action: policy_action,
      policy_opts: policy_opts
    }
  end

  defp issue_request(context) do
    body =
      [map_get(context, :body), map_get(context, :dependency_summary)]
      |> Enum.filter(&present?/1)
      |> Enum.join("\n\n")

    %{
      title: map_get(context, :title),
      body: body
    }
  end

  defp labels_request(context), do: %{labels: map_get(context, :labels, [])}

  defp milestone_request(context) do
    %{title: map_get(context, :milestone_title), url: map_get(context, :github_milestone_url)}
  end

  defp workpad_comment_request(context), do: %{body: map_get(context, :workpad_body)}

  defp pr_request(context) do
    %{number: map_get(context, :github_pr_number), url: map_get(context, :github_pr_url)}
  end

  defp review_state_request(context) do
    %{state: map_get(context, :review_state, "pending"), body: map_get(context, :review_body)}
  end

  defp operation_allowed?(operation, project, connection) do
    case capability_allowed?(connection, operation.required_capability) do
      :ok -> policy_allowed?(operation, project, connection)
      skipped -> skipped
    end
  end

  defp capability_allowed?(_connection, nil), do: :ok

  defp capability_allowed?(connection, capabilities) when is_list(capabilities) do
    if Enum.any?(capabilities, &capability_enabled?(connection, &1)) do
      :ok
    else
      {:skip, {:missing_capability, List.first(capabilities)}}
    end
  end

  defp capability_allowed?(connection, capability) do
    if capability_enabled?(connection, capability) do
      :ok
    else
      {:skip, {:missing_capability, capability}}
    end
  end

  defp policy_allowed?(%{policy_action: nil}, _project, _connection), do: :ok
  defp policy_allowed?(_operation, nil, _connection), do: :ok

  defp policy_allowed?(operation, project, connection) do
    case PublicRepoPolicy.evaluate(operation.policy_action, project, connection, operation.policy_opts) do
      {:allow, _reason} -> :ok
      {:block, reason} -> {:skip, reason}
    end
  end

  defp capability_enabled?(connection, capability) do
    connection
    |> field(:capabilities, %{})
    |> Map.get(capability, false)
  end

  defp perform(operation, performer) do
    case performer.(operation) do
      {:ok, response} -> {"success", response, nil}
      {:error, error} -> {"error", %{}, inspect(error)}
    end
  end

  defp sync_event(operation, context, status, response, error) do
    %{
      project_id: map_get(context, :project_id),
      symphony_issue_id: map_get(context, :symphony_issue_id),
      provider: "github",
      action: operation.action,
      kind: operation.kind,
      status: status,
      request: operation.request,
      response: response,
      error: error
    }
  end

  defp github_url(connection, path) do
    "https://github.com/#{field(connection, :owner)}/#{field(connection, :repo)}/#{path}"
  end

  defp explicit?(context, key), do: map_get(context, key, false) == true

  defp present?(value), do: (is_binary(value) and value != "") or (not is_nil(value) and value != "")

  defp map_get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(struct_or_map, key, default \\ nil), do: Map.get(struct_or_map, key, default)
end
