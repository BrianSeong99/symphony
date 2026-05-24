defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    case prompt_mode(opts) do
      "compact" -> compact_prompt(issue, opts)
      "workflow" -> workflow_prompt(issue, opts)
    end
  end

  defp workflow_prompt(issue, opts) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_mode(opts) do
    case Keyword.get(opts, :prompt_mode) do
      :compact -> "compact"
      :workflow -> "workflow"
      mode when mode in ["compact", "workflow"] -> mode
      _ -> configured_prompt_mode()
    end
  end

  defp configured_prompt_mode do
    Config.settings!().agent.prompt_mode
  rescue
    ArgumentError -> "workflow"
  end

  defp compact_prompt(issue, opts) do
    attempt = Keyword.get(opts, :attempt)
    labels = issue.labels || []
    description = issue.description || "No description provided."

    [
      "You are running a Symphony-managed repository task.",
      "",
      "Issue:",
      "- Identifier: #{issue.identifier}",
      "- Title: #{issue.title}",
      "- Current status: #{issue.state}",
      "- URL: #{issue.url}",
      "- Labels: #{Enum.join(labels, ", ")}",
      compact_attempt(attempt),
      "",
      "Description:",
      description,
      "",
      "Execution rules:",
      "- Work only in the current repository worktree.",
      "- Verify this is a real git worktree before edits: `git rev-parse --git-dir` and `git rev-parse --git-common-dir` must differ.",
      "- Read nearest `AGENTS.md`, `CLAUDE.md`, `elixir/AGENTS.md`, and repo PR/validation guidance before public artifacts.",
      "- Do not add AI attribution to commits, PRs, issues, comments, README files, or other public copy.",
      "- Branches must be based on `main`; do not create stacked PRs.",
      "- Symphony backend owns routine Linear run-log writeback. Do not use `linear_graphql` during startup unless required issue data is missing or requirements must be changed.",
      "- For small tasks, inspect or edit repository files within 45 seconds. Do not spend the opening turn maintaining Linear workpads.",
      "- Your first action after reading this prompt should be a repository command such as `pwd`, `git status --short`, `find`, `rg`, or opening the relevant guidance file. Do not spend the opening turn only reasoning.",
      "- Optional MCP tools such as Notion are not required and missing optional tools are not blockers.",
      "- If requirements are wrong or validation is misaligned, record the required issue update through Linear, then continue in the same session.",
      "",
      "Deliverable:",
      "- Implement the issue, run the stated validation, commit cleanly, push, open a PR, and self-merge when validation passes and repo policy allows it.",
      "- Final response should contain completed actions and blockers only."
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp compact_attempt(nil), do: nil
  defp compact_attempt(attempt), do: "- Retry attempt: #{attempt}"

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
