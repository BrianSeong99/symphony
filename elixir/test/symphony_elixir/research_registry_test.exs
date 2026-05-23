defmodule SymphonyElixir.ResearchRegistryTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @research_path Path.join(@root, "config/symphony/research-corpus.yml")
  @patterns_path Path.join(@root, "config/symphony/pattern-registry.yml")

  test "research corpus is parseable and captures canonical agent references" do
    corpus = read_yaml!(@research_path)

    assert corpus["version"] == 1

    urls = corpus["sources"] |> Enum.map(& &1["url"]) |> MapSet.new()

    for url <- [
          "https://code.claude.com/docs/en/best-practices",
          "https://code.claude.com/docs/en/memory",
          "https://code.claude.com/docs/en/hooks",
          "https://code.claude.com/docs/en/agent-sdk/sessions",
          "https://openai.com/index/unrolling-the-codex-agent-loop/",
          "https://openai.com/index/unlocking-the-codex-harness/",
          "https://openai.com/index/running-codex-safely/",
          "https://developers.openai.com/codex/integrations/github",
          "https://cursor.com/blog/agent-best-practices",
          "https://docs.cursor.com/background-agents",
          "https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent"
        ] do
      assert MapSet.member?(urls, url)
    end

    assert Enum.all?(corpus["sources"], fn source ->
             is_binary(source["title"]) and is_binary(source["topic"]) and
               is_binary(source["last_reviewed_on"]) and is_number(source["confidence"]) and
               is_list(source["applicable_patterns"])
           end)
  end

  test "pattern registry defines enforceable orchestration patterns" do
    registry = read_yaml!(@patterns_path)

    assert registry["version"] == 1

    patterns = Map.fetch!(registry, "patterns")
    pattern_keys = patterns |> Enum.map(& &1["key"]) |> MapSet.new()

    for key <- [
          "explore-plan-code",
          "planner-worker-reviewer-separation",
          "persistent-builder-session",
          "persistent-reviewer-session",
          "review-repair-validate",
          "deterministic-hooks-over-soft-instructions",
          "context-freshness-check",
          "loop-breaker",
          "final-green-pass",
          "human-gated-rule-promotion",
          "simulation-before-production"
        ] do
      assert MapSet.member?(pattern_keys, key)
    end

    assert Enum.all?(patterns, fn pattern ->
             is_binary(pattern["key"]) and is_binary(pattern["summary"]) and
               is_list(pattern["origin_sources"]) and is_list(pattern["enforces"]) and
               is_map(pattern["safety_policy"])
           end)
  end

  defp read_yaml!(path) do
    assert File.exists?(path), "expected #{path} to exist"

    assert {:ok, decoded} = path |> File.read!() |> YamlElixir.read_from_string()
    assert is_map(decoded)

    decoded
  end
end
