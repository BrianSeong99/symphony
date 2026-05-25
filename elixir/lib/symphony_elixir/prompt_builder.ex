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
    |> append_context_hygiene_rules()
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
      "- Internal id: #{issue.id}",
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
      context_hygiene_rule(),
      "- Verify this is a real git worktree before edits: `git rev-parse --git-dir` and `git rev-parse --git-common-dir` must differ.",
      "- Treat injected `AGENTS.md`/`CLAUDE.md` guidance as already loaded. Do not print or re-read full guidance files; use targeted `rg` or line ranges only when a specific rule is missing.",
      "- Do not add AI attribution to commits, PRs, issues, comments, README files, or other public copy.",
      "- Branches must be based on `main`; do not create stacked PRs.",
      "- Symphony backend owns routine Linear run-log writeback. Do not use `linear_graphql` during startup unless required issue data is missing or requirements must be changed.",
      "- Do not use GitHub connectors, app connectors, or MCP app tools for branch, commit, push, PR, review, or merge operations. Use local `git` and `gh` CLI from the worktree instead.",
      "- Start with `git diff --stat` after the worktree check. If existing dirty files match the issue, inspect only the changed files and validation path.",
      "- Keep startup context lean: use targeted `rg` and line-range reads; do not print full guidance files, package manifests, generated files, complete workflow docs, or full diffs unless required.",
      "- If this worktree already has relevant edits, validate and repair those edits first instead of restarting broad discovery.",
      "- Within three startup commands, either edit a target file or run targeted validation unless you are blocked by missing credentials or tools.",
      "- Keep shell commands single-purpose. Avoid chained reads with `&&`, semicolons, or separator `echo` blocks because their combined output can hide runaway context.",
      "- For small tasks, inspect or edit repository files within 45 seconds. Do not spend the opening turn maintaining Linear workpads.",
      "- If the issue names exact files, exact fixture content, or an exact validation command, implement that direct path before broad repository searches.",
      "- Your first action after reading this prompt should be a repository command such as `pwd`, `git status --short`, `find`, `rg`, or opening the relevant guidance file. Do not spend the opening turn only reasoning.",
      "- Publish with `${SYMPHONY_GIT_PUSH_REMOTE:-origin}` and create/view PRs with `${SYMPHONY_GITHUB_REPO:-the current repo}` when those env vars are set.",
      "- For Symphony Elixir validation, run from `elixir/`; fresh worktrees should run `mix deps.get` before tests, and test commands should inherit `SYMPHONY_RUNNER_ENABLED=false SYMPHONY_SERVER_PORT=0`.",
      "- For PR state checks, use `gh pr view <number> --json number,title,state,mergeStateStatus,mergeable,headRefName,baseRefName,statusCheckRollup,url`.",
      "- If Linear access is required, query by the injected internal issue id with `issue(id: ...)`; do not filter by `identifier`.",
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

  defp append_context_hygiene_rules(prompt) do
    prompt <> "\n\n" <> context_hygiene_section()
  end

  defp context_hygiene_section do
    [
      "## Context hygiene",
      "",
      context_hygiene_rule(),
      "- Do not install dependencies during initial exploration. Install or build only after you know the validation path needs it.",
      "- Prefer targeted file reads and `rg` searches over broad directory listings.",
      "- Treat injected `AGENTS.md`/`CLAUDE.md` guidance as already loaded; do not print or re-read full guidance files.",
      "- Keep startup context lean: use `git diff --stat`, targeted `rg`, and line-range reads instead of printing full guidance files, package manifests, generated files, complete workflow docs, or full diffs.",
      "- If the worktree already has relevant edits, validate and repair those edits before broad rediscovery."
    ]
    |> Enum.join("\n")
  end

  defp context_hygiene_rule do
    patterns =
      Config.settings!().workspace.context_exclude_patterns
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.join(", ")

    "- Avoid dependency, cache, build, coverage, and generated-artifact paths unless the issue explicitly requires them: #{patterns}."
  rescue
    ArgumentError ->
      "- Avoid dependency, cache, build, coverage, and generated-artifact paths unless the issue explicitly requires them."
  end
end
