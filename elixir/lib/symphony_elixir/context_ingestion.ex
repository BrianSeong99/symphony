defmodule SymphonyElixir.ContextIngestion do
  @moduledoc """
  Builds bounded codebase context packets before an agent run starts.
  """

  require Logger

  alias SymphonyElixir.{Config, RunLog}
  alias SymphonyElixir.Linear.Issue

  @default_include [
    "AGENTS.md",
    "CLAUDE.md",
    "WORKFLOW*.md",
    ".github/pull_request_template.md",
    ".github/workflows/*.{yml,yaml}",
    "docs/**/*.md",
    "config/**/*.{yml,yaml,json,toml,exs}",
    "elixir/**/*.{ex,exs,md}",
    "lib/**/*.{ex,exs,js,jsx,ts,tsx,py,rs,go,md}",
    "src/**/*.{js,jsx,ts,tsx,py,rs,go,md}",
    "app/**/*.{js,jsx,ts,tsx,py,rs,go,md}",
    "test/**/*.{exs,js,jsx,ts,tsx,py,rs,go,md}",
    "Makefile",
    "Justfile",
    "mix.exs",
    "package.json",
    "pyproject.toml",
    "Cargo.toml",
    "compose*.yml",
    "compose*.yaml",
    "docker-compose*.yml",
    "docker-compose*.yaml"
  ]

  @doc false
  @spec prepare(Path.t(), Issue.t() | map(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def prepare(workspace, issue, opts \\ []) when is_binary(workspace) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    ingestion = settings.context_ingestion

    if ingestion.enabled do
      do_prepare(workspace, issue, settings)
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec packet_text(map() | nil) :: String.t() | nil
  def packet_text(nil), do: nil

  def packet_text(packet) when is_map(packet) do
    [
      "## Cached Codebase Context",
      "",
      "- Context packet: #{packet[:id]}",
      "- Provider: #{packet[:provider]}",
      "- Cache: #{packet[:cache_status]}",
      "- Base commit: #{packet[:base_commit]}",
      "- Graph hash: #{packet[:graph_hash] || "n/a"}",
      "- Packet token estimate: #{packet[:token_estimate]}",
      "- Included paths: #{packet[:included_path_count]}",
      "- Excluded patterns: #{Enum.join(packet[:excluded_patterns] || [], ", ")}",
      packet_list("Guidance files", packet[:guidance_files]),
      packet_list("Validation files", packet[:validation_files]),
      packet_list("Service files", packet[:service_files]),
      packet_list("Likely relevant files", packet[:likely_relevant_files]),
      provider_summary(packet)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @doc false
  @spec summary(map() | nil) :: map()
  def summary(nil) do
    %{
      context_packet_id: nil,
      likely_relevant_files: [],
      validation_files: [],
      guidance_files: [],
      assumptions: ["Context ingestion is disabled for this lane."],
      next_action: "Use targeted repository commands to identify the smallest relevant edit or validation path."
    }
  end

  def summary(packet) when is_map(packet) do
    %{
      context_packet_id: packet[:id],
      provider: packet[:provider],
      provider_status: packet[:provider_status],
      cache_status: packet[:cache_status],
      base_commit: packet[:base_commit],
      graph_hash: packet[:graph_hash],
      included_path_count: packet[:included_path_count],
      context_packet_tokens: packet[:token_estimate],
      likely_relevant_files: packet[:likely_relevant_files] |> List.wrap() |> Enum.take(10),
      validation_files: packet[:validation_files] |> List.wrap() |> Enum.take(10),
      guidance_files: packet[:guidance_files] |> List.wrap() |> Enum.take(10),
      service_files: packet[:service_files] |> List.wrap() |> Enum.take(10),
      assumptions: [
        "Use targeted line-range reads for listed files before broad repository search.",
        "Do not ingest logs, generated assets, dependency trees, caches, coverage, or build output."
      ],
      next_action: next_action(packet)
    }
  end

  @doc false
  @spec cache_key_for_test(Path.t(), map(), map()) :: String.t()
  def cache_key_for_test(workspace, issue, settings), do: cache_key(workspace, issue, settings)

  defp do_prepare(workspace, issue, settings) do
    ingestion = settings.context_ingestion
    started_at = System.monotonic_time(:millisecond)
    base_commit = git_output(workspace, ["rev-parse", "HEAD"]) || "unknown"
    cache_key = cache_key(workspace, issue, settings)
    packet_path = packet_path(ingestion.cache_root, cache_key)

    safe_log(issue, :"context_ingestion.started", %{
      provider: ingestion.provider,
      workspace: workspace,
      cache_root: ingestion.cache_root,
      base_commit: base_commit,
      refresh_policy: ingestion.refresh_policy,
      max_ingestion_seconds: ingestion.max_ingestion_seconds
    })

    case read_cached_packet(packet_path, ingestion.refresh_policy) do
      {:ok, packet} ->
        packet =
          packet
          |> Map.put(:cache_status, "hit")
          |> Map.put(:ingestion_duration_ms, elapsed_ms(started_at))

        safe_log(issue, :"context_ingestion.cache_hit", log_attrs(packet, started_at))
        safe_log(issue, :"context_packet.attached", log_attrs(packet, started_at))
        {:ok, packet}

      :miss ->
        safe_log(issue, :"context_ingestion.cache_miss", %{
          provider: ingestion.provider,
          base_commit: base_commit,
          packet_path: packet_path
        })

        packet =
          build_packet(workspace, issue, settings, base_commit, started_at)
          |> Map.put(:cache_status, "miss")

        :ok = write_packet(packet_path, packet)

        maybe_log_provider_fallback(issue, packet)
        safe_log(issue, :"context_ingestion.completed", log_attrs(packet, started_at))
        safe_log(issue, :"context_packet.attached", log_attrs(packet, started_at))
        {:ok, packet}
    end
  rescue
    error ->
      settings = Config.settings!()
      ingestion = settings.context_ingestion
      reason = Exception.message(error)

      safe_log(issue, :"context_ingestion.failed", %{
        provider: ingestion.provider,
        error: reason,
        fallback: not ingestion.required_for_runner
      })

      if ingestion.required_for_runner do
        {:error, {:context_ingestion_failed, reason}}
      else
        fallback_packet(workspace, issue, settings, "exception: #{reason}")
      end
  end

  defp read_cached_packet(_packet_path, "always"), do: :miss

  defp read_cached_packet(packet_path, _refresh_policy) do
    with true <- File.exists?(packet_path),
         {:ok, content} <- File.read(packet_path),
         {:ok, packet} <- Jason.decode(content, keys: :atoms) do
      {:ok, packet}
    else
      _ -> :miss
    end
  end

  defp write_packet(packet_path, packet) do
    File.mkdir_p!(Path.dirname(packet_path))
    File.write!(packet_path, Jason.encode!(packet, pretty: true))
    :ok
  end

  defp build_packet(workspace, issue, settings, base_commit, started_at) do
    internal = internal_context(workspace, issue, settings)

    provider_result =
      case settings.context_ingestion.provider do
        "graphify" -> graphify_context(workspace, issue, settings)
        _provider -> {:ok, %{provider_status: "internal"}}
      end

    provider_context =
      case provider_result do
        {:ok, context} ->
          context

        {:error, reason} ->
          if settings.context_ingestion.required_for_runner do
            raise RuntimeError, "context provider failed: #{inspect(reason)}"
          else
            %{provider_status: "fallback", fallback_reason: inspect(reason)}
          end
      end

    packet =
      internal
      |> Map.merge(provider_context)
      |> Map.merge(%{
        id: packet_id(workspace, issue, settings),
        provider: settings.context_ingestion.provider,
        base_commit: base_commit,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        ingestion_duration_ms: elapsed_ms(started_at),
        max_context_packet_tokens: settings.context_ingestion.max_context_packet_tokens
      })

    packet
    |> Map.put(:token_estimate, token_estimate(packet))
    |> enforce_packet_budget(settings.context_ingestion.max_context_packet_tokens)
  end

  defp fallback_packet(workspace, issue, settings, reason) do
    started_at = System.monotonic_time(:millisecond)
    base_commit = git_output(workspace, ["rev-parse", "HEAD"]) || "unknown"

    packet =
      workspace
      |> internal_context(issue, settings)
      |> Map.merge(%{
        id: packet_id(workspace, issue, settings),
        provider: "internal",
        provider_status: "fallback",
        fallback_reason: reason,
        cache_status: "fallback",
        base_commit: base_commit,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        ingestion_duration_ms: elapsed_ms(started_at)
      })

    packet = Map.put(packet, :token_estimate, token_estimate(packet))
    safe_log(issue, :"context_packet.attached", log_attrs(packet, started_at))
    {:ok, packet}
  end

  defp internal_context(workspace, issue, settings) do
    files = included_files(workspace, settings)
    issue_terms = issue_terms(issue)

    %{
      source: "internal_file_map",
      included_path_count: length(files),
      excluded_patterns: exclusion_patterns(settings),
      guidance_files: select_files(files, ["AGENTS.md", "CLAUDE.md", "WORKFLOW", "workflow"]),
      validation_files: select_files(files, ["Makefile", "Justfile", "mix.exs", "package.json", ".github/workflows", "test/"]),
      service_files: select_files(files, ["compose", "docker-compose", "Dockerfile", "homelab", "health"]),
      likely_relevant_files: likely_relevant_files(files, issue_terms)
    }
  end

  defp graphify_context(workspace, issue, settings) do
    ingestion = settings.context_ingestion

    with :ok <- ensure_provider_available(ingestion.command),
         :ok <- ensure_git_exclude(workspace, "graphify-out/"),
         {:ok, update_output} <- run_graphify_update(workspace, ingestion),
         {:ok, graph_hash} <- graph_hash(workspace),
         query_output <- run_graphify_query(workspace, issue, ingestion) do
      {:ok,
       %{
         provider_status: "graphify",
         graph_hash: graph_hash,
         graphify_update_summary: compact_output(update_output),
         graphify_query: compact_output(query_output)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_log_provider_fallback(issue, %{provider_status: "fallback"} = packet) do
    safe_log(issue, :"context_ingestion.failed", %{
      context_packet_id: packet[:id],
      provider: packet[:provider],
      error: packet[:fallback_reason],
      fallback: true
    })
  end

  defp maybe_log_provider_fallback(_issue, _packet), do: :ok

  defp ensure_provider_available(command) when is_binary(command) do
    executable =
      command
      |> String.split(~r/\s+/, trim: true)
      |> List.first()

    cond do
      executable in [nil, ""] ->
        {:error, :context_provider_missing}

      System.find_executable(executable) ->
        :ok

      true ->
        {:error, :context_provider_missing}
    end
  end

  defp ensure_git_exclude(workspace, pattern) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--git-path", "info/exclude"], stderr_to_stdout: true) do
      {path, 0} ->
        exclude_path = path |> String.trim() |> Path.expand(workspace)
        File.mkdir_p!(Path.dirname(exclude_path))
        content = if File.exists?(exclude_path), do: File.read!(exclude_path), else: ""

        unless String.contains?(content, pattern) do
          File.write!(exclude_path, String.trim_trailing(content) <> "\n#{pattern}\n")
        end

        :ok

      {_output, _status} ->
        :ok
    end
  end

  defp run_graphify_update(workspace, ingestion) do
    run_shell(
      "#{ingestion.command} update #{shell_escape(workspace)} --no-cluster",
      ingestion.max_ingestion_seconds * 1_000
    )
  end

  defp run_graphify_query(workspace, issue, ingestion) do
    graph_path = Path.join([workspace, "graphify-out", "graph.json"])
    query = issue_query(issue)

    case run_shell(
           "#{ingestion.command} query #{shell_escape(query)} --budget #{ingestion.max_context_packet_tokens} --graph #{shell_escape(graph_path)}",
           30_000
         ) do
      {:ok, output} -> output
      {:error, reason} -> "graphify query unavailable: #{inspect(reason)}"
    end
  end

  defp graph_hash(workspace) do
    graph_path = Path.join([workspace, "graphify-out", "graph.json"])

    if File.exists?(graph_path) do
      hash =
        graph_path
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, hash}
    else
      {:error, :graphify_graph_missing}
    end
  end

  defp run_shell(command, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:command_failed, status, compact_output(output)}}
      nil -> {:error, :command_timeout}
    end
  end

  defp included_files(workspace, settings) do
    includes =
      case settings.context_ingestion.include do
        [] -> @default_include
        configured -> configured
      end

    excludes = exclusion_patterns(settings)

    includes
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(workspace, pattern), match_dot: true) end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.reject(&excluded?(&1, excludes))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(250)
  end

  defp exclusion_patterns(settings) do
    (settings.workspace.context_exclude_patterns ++ settings.context_ingestion.exclude ++ ["graphify-out/"])
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp excluded?(relative_path, patterns) do
    Enum.any?(patterns, fn pattern -> path_excluded?(relative_path, pattern) end)
  end

  defp path_excluded?(relative_path, pattern) do
    cond do
      String.ends_with?(pattern, "/") ->
        relative_path == String.trim_trailing(pattern, "/") or String.starts_with?(relative_path, pattern)

      String.contains?(pattern, "*") ->
        pattern
        |> glob_regex()
        |> Regex.match?(relative_path)

      true ->
        relative_path == pattern or String.starts_with?(relative_path, pattern <> "/")
    end
  end

  defp select_files(files, needles) do
    files
    |> Enum.filter(fn file ->
      Enum.any?(needles, &String.contains?(String.downcase(file), String.downcase(&1)))
    end)
    |> Enum.take(20)
  end

  defp likely_relevant_files(files, issue_terms) do
    files
    |> Enum.map(fn file -> {file, relevance_score(file, issue_terms)} end)
    |> Enum.filter(fn {_file, score} -> score > 0 end)
    |> Enum.sort_by(fn {file, score} -> {-score, file} end)
    |> Enum.map(fn {file, _score} -> file end)
    |> Enum.take(25)
  end

  defp relevance_score(file, terms) do
    file = String.downcase(file)
    Enum.count(terms, &String.contains?(file, &1))
  end

  defp glob_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> then(&Regex.compile!("^#{&1}$"))
  end

  defp issue_terms(issue) do
    [field(issue, :identifier), field(issue, :title), field(issue, :description)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-\/.]+/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= 4))
    |> Enum.reject(&(&1 in ["issue", "task", "work", "with", "from", "this", "that", "should"]))
    |> Enum.uniq()
    |> Enum.take(40)
  end

  defp issue_query(issue) do
    [field(issue, :title), field(issue, :description)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.slice(0, 1_500)
  end

  defp field(%Issue{} = issue, key), do: Map.get(issue, key)
  defp field(issue, key) when is_map(issue), do: Map.get(issue, key) || Map.get(issue, to_string(key))
  defp field(_issue, _key), do: nil

  defp packet_path(cache_root, cache_key), do: Path.join([cache_root, cache_key, "packet.json"])

  defp cache_key(workspace, issue, settings) do
    [
      workspace_repo_identity(workspace),
      git_output(workspace, ["rev-parse", "HEAD"]) || "unknown",
      field(issue, :id) || field(issue, :identifier) || "issue",
      settings.context_ingestion.provider,
      settings.context_ingestion.command,
      Integer.to_string(settings.context_ingestion.max_context_packet_tokens),
      Enum.join(settings.context_ingestion.include, "\0"),
      Enum.join(exclusion_patterns(settings), "\0")
    ]
    |> Enum.join("\0")
    |> hash_text()
  end

  defp packet_id(workspace, issue, settings), do: "ctx-" <> String.slice(cache_key(workspace, issue, settings), 0, 12)

  defp workspace_repo_identity(workspace) do
    git_output(workspace, ["config", "--get", "remote.origin.url"]) || workspace
  end

  defp git_output(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  end

  defp hash_text(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp enforce_packet_budget(packet, max_tokens) do
    if token_estimate(packet) <= max_tokens do
      packet
    else
      packet
      |> Map.update(:likely_relevant_files, [], &Enum.take(&1, 10))
      |> Map.update(:guidance_files, [], &Enum.take(&1, 10))
      |> Map.update(:validation_files, [], &Enum.take(&1, 10))
      |> Map.update(:service_files, [], &Enum.take(&1, 10))
      |> Map.update(:graphify_query, nil, &truncate(&1, max_tokens * 3))
      |> then(&Map.put(&1, :token_estimate, token_estimate(&1)))
    end
  end

  defp token_estimate(packet) do
    packet
    |> Jason.encode!()
    |> String.length()
    |> div(4)
  end

  defp packet_list(_title, nil), do: nil
  defp packet_list(_title, []), do: nil

  defp packet_list(title, values) when is_list(values) do
    list =
      values
      |> Enum.take(25)
      |> Enum.map_join("\n", &"- #{&1}")

    "\n#{title}:\n#{list}"
  end

  defp provider_summary(%{graphify_query: query}) when is_binary(query) and query != "" do
    "\nGraphify query summary:\n#{truncate(query, 4_000)}"
  end

  defp provider_summary(%{fallback_reason: reason}) when is_binary(reason) do
    "\nContext fallback reason: #{reason}"
  end

  defp provider_summary(_packet), do: nil

  defp log_attrs(packet, started_at) do
    summary = summary(packet)

    %{
      context_packet_id: packet[:id],
      provider: packet[:provider],
      provider_status: packet[:provider_status],
      cache_status: packet[:cache_status],
      base_commit: packet[:base_commit],
      graph_hash: packet[:graph_hash],
      included_path_count: packet[:included_path_count],
      context_packet_tokens: packet[:token_estimate],
      likely_relevant_files: summary.likely_relevant_files,
      validation_files: summary.validation_files,
      guidance_files: summary.guidance_files,
      next_action: summary.next_action,
      ingestion_duration_ms: packet[:ingestion_duration_ms] || elapsed_ms(started_at),
      fallback_reason: packet[:fallback_reason]
    }
  end

  defp next_action(packet) do
    cond do
      List.wrap(packet[:likely_relevant_files]) != [] ->
        "Inspect the likely relevant file shortlist with targeted line ranges, then edit or run focused validation."

      List.wrap(packet[:validation_files]) != [] ->
        "Inspect the validation files to choose the smallest relevant validation command before broad discovery."

      true ->
        "Run one targeted repository search from the issue terms, then update the issue with a blocker if no target path appears."
    end
  end

  defp safe_log(issue, event, attrs) do
    case RunLog.log(issue, event, attrs) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Context ingestion run-log writeback failed event=#{event}: #{inspect(reason)}")
    end
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp compact_output(output) when is_binary(output) do
    output
    |> String.trim()
    |> truncate(2_000)
  end

  defp compact_output(output), do: inspect(output, limit: 20, printable_limit: 2_000)

  defp truncate(nil, _max), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) > max, do: binary_part(text, 0, max) <> "\n[truncated]"
  defp truncate(text, _max), do: text

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
