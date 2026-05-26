defmodule SymphonyElixir.ContextIngestionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ContextIngestion

  test "workflow config parses context ingestion settings" do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-config-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      context_ingestion_enabled: true,
      context_ingestion_provider: "graphify",
      context_ingestion_command: "uvx --from graphifyy graphify",
      context_ingestion_cache_root: cache_root,
      context_ingestion_refresh_policy: "always",
      context_ingestion_max_ingestion_seconds: 90,
      context_ingestion_max_context_packet_tokens: 8_000,
      context_ingestion_include: ["AGENTS.md", "docs/**/*.md"],
      context_ingestion_exclude: ["tmp/**"],
      context_ingestion_required_for_runner: true
    )

    settings = Config.settings!()

    assert settings.context_ingestion.enabled
    assert settings.context_ingestion.provider == "graphify"
    assert settings.context_ingestion.cache_root == cache_root
    assert settings.context_ingestion.refresh_policy == "always"
    assert settings.context_ingestion.max_ingestion_seconds == 90
    assert settings.context_ingestion.max_context_packet_tokens == 8_000
    assert settings.context_ingestion.include == ["AGENTS.md", "docs/**/*.md"]
    assert settings.context_ingestion.exclude == ["tmp/**"]
    assert settings.context_ingestion.required_for_runner
  end

  test "internal ingestion builds a compact cached context packet" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-internal-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "repo")
      cache_root = Path.join(test_root, "cache")
      File.mkdir_p!(Path.join(workspace, "docs"))
      File.mkdir_p!(Path.join(workspace, "deps"))
      File.mkdir_p!(Path.join(workspace, "graphify-out"))
      File.write!(Path.join(workspace, "AGENTS.md"), "agent guide\n")
      File.write!(Path.join(workspace, "Makefile"), "all:\n\ttrue\n")
      File.write!(Path.join([workspace, "docs", "agent-workflow.md"]), "workflow\n")
      File.write!(Path.join([workspace, "deps", "large.txt"]), "ignored\n")
      File.write!(Path.join([workspace, "graphify-out", "graph.json"]), "{}")
      init_git!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        context_ingestion_enabled: true,
        context_ingestion_provider: "internal",
        context_ingestion_cache_root: cache_root,
        context_ingestion_include: ["AGENTS.md", "Makefile", "docs/**/*.md", "deps/**", "graphify-out/**"],
        context_ingestion_exclude: ["deps/**"]
      )

      issue = %Issue{
        id: "GH-391",
        identifier: "GH-391",
        title: "Update agent workflow docs",
        description: "Please update docs/agent-workflow.md"
      }

      assert {:ok, packet} = ContextIngestion.prepare(workspace, issue)
      assert packet.provider == "internal"
      assert packet.cache_status == "miss"
      assert "AGENTS.md" in packet.guidance_files
      assert "Makefile" in packet.validation_files
      assert "docs/agent-workflow.md" in packet.likely_relevant_files
      refute Enum.any?(packet.likely_relevant_files, &String.starts_with?(&1, "deps/"))
      refute Enum.any?(packet.likely_relevant_files, &String.starts_with?(&1, "graphify-out/"))

      assert {:ok, cached_packet} = ContextIngestion.prepare(workspace, issue)
      assert cached_packet.cache_status == "hit"
      assert cached_packet.id == packet.id
    after
      File.rm_rf(test_root)
    end
  end

  test "missing graphify provider falls back without blocking the runner" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-graphify-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "repo")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "agent guide\n")
      init_git!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        context_ingestion_enabled: true,
        context_ingestion_provider: "graphify",
        context_ingestion_command: "definitely-missing-graphify-command",
        context_ingestion_cache_root: Path.join(test_root, "cache"),
        context_ingestion_include: ["AGENTS.md"],
        context_ingestion_required_for_runner: false
      )

      issue = %Issue{id: "GH-1", identifier: "GH-1", title: "Read guide"}

      assert {:ok, packet} = ContextIngestion.prepare(workspace, issue)
      assert packet.provider == "graphify"
      assert packet.provider_status == "fallback"
      assert packet.fallback_reason =~ "context_provider_missing"
      assert "AGENTS.md" in packet.guidance_files
    after
      File.rm_rf(test_root)
    end
  end

  test "required graphify provider failure blocks context preparation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-required-fallback-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "repo")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "agent guide\n")
      init_git!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        context_ingestion_enabled: true,
        context_ingestion_provider: "graphify",
        context_ingestion_command: "definitely-missing-graphify-command",
        context_ingestion_cache_root: Path.join(test_root, "cache"),
        context_ingestion_include: ["AGENTS.md"],
        context_ingestion_required_for_runner: true
      )

      issue = %Issue{id: "GH-2", identifier: "GH-2", title: "Read guide"}

      assert {:error, {:context_ingestion_failed, reason}} = ContextIngestion.prepare(workspace, issue)
      assert reason =~ "context provider failed"
      assert reason =~ "context_provider_missing"
    after
      File.rm_rf(test_root)
    end
  end

  test "graphify provider success records graph metadata and query output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-context-graphify-success-#{System.unique_integer([:positive])}"
      )

    old_path = System.get_env("PATH")

    try do
      workspace = Path.join(test_root, "repo")
      bin_dir = Path.join(test_root, "bin")
      fake_graphify = Path.join(bin_dir, "fake-graphify")

      File.mkdir_p!(workspace)
      File.mkdir_p!(bin_dir)
      File.write!(Path.join(workspace, "AGENTS.md"), "agent guide\n")
      File.write!(Path.join(workspace, "Makefile"), "all:\n\ttrue\n")
      File.write!(fake_graphify, fake_graphify_script())
      File.chmod!(fake_graphify, 0o755)
      System.put_env("PATH", "#{bin_dir}:#{old_path}")
      init_git!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        context_ingestion_enabled: true,
        context_ingestion_provider: "graphify",
        context_ingestion_command: "fake-graphify",
        context_ingestion_cache_root: Path.join(test_root, "cache"),
        context_ingestion_include: ["AGENTS.md", "Makefile"],
        context_ingestion_required_for_runner: false
      )

      issue = %Issue{id: "GH-3", identifier: "GH-3", title: "Explain agent guide"}

      assert {:ok, packet} = ContextIngestion.prepare(workspace, issue)
      assert packet.provider == "graphify"
      assert packet.provider_status == "graphify"
      assert is_binary(packet.graph_hash)
      assert packet.graphify_update_summary =~ "fake graph updated"
      assert packet.graphify_query =~ "fake query result"

      {exclude_path, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "--git-path", "info/exclude"])
      assert exclude_path |> String.trim() |> Path.expand(workspace) |> File.read!() =~ "graphify-out/"
    after
      restore_env("PATH", old_path)
      File.rm_rf(test_root)
    end
  end

  test "prompt builder injects context packet text" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt_mode: "compact")

    issue = %Issue{
      id: "GH-1",
      identifier: "GH-1",
      title: "Update docs",
      description: "Small docs task",
      labels: ["agent:symphony"],
      state: "Todo",
      url: "https://github.com/BrianSeong99/homelab/issues/1"
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        context_packet: %{
          id: "ctx-test",
          provider: "graphify",
          cache_status: "hit",
          base_commit: "abc123",
          graph_hash: "def456",
          token_estimate: 42,
          included_path_count: 3,
          excluded_patterns: ["deps/"],
          guidance_files: ["AGENTS.md"],
          validation_files: ["Makefile"],
          service_files: [],
          likely_relevant_files: ["docs/agent-workflow.md"],
          graphify_query: "Relevant docs node"
        }
      )

    assert prompt =~ "## Cached Codebase Context"
    assert prompt =~ "Context packet: ctx-test"
    assert prompt =~ "docs/agent-workflow.md"
    assert prompt =~ "Relevant docs node"
  end

  defp init_git!(workspace) do
    System.cmd("git", ["-C", workspace, "init", "-b", "main"])
    System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", workspace, "add", "."])
    System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
  end

  defp fake_graphify_script do
    """
    #!/bin/sh
    if [ "$1" = "update" ]; then
      mkdir -p "$2/graphify-out"
      printf '{"nodes":[{"id":"AGENTS.md"}],"edges":[]}' > "$2/graphify-out/graph.json"
      printf 'fake graph updated'
      exit 0
    fi

    if [ "$1" = "query" ]; then
      printf 'fake query result for %s' "$2"
      exit 0
    fi

    exit 1
    """
  end
end
