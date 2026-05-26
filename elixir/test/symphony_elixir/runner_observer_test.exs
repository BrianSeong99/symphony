defmodule SymphonyElixir.RunnerObserverTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunLog
  alias SymphonyElixir.RunnerObserver

  test "classifies missing tools, stale output, auth failures, and validation mismatch" do
    assert RunnerObserver.classify_failure(:bash_not_found) == :missing_tool
    assert RunnerObserver.classify_failure("stalled for 301000ms without codex activity") == :no_output_timeout
    assert RunnerObserver.classify_failure("403 forbidden from Linear") == :auth_failure
    assert RunnerObserver.classify_failure("acceptance criteria mismatch after validation") == :requirements_mismatch
    assert RunnerObserver.classify_failure("Mix.PubSub start failed with :eperm") == :permission_denied_loop
    assert RunnerObserver.classify_failure("startup_token_budget_exceeded total_tokens=120000") == :startup_token_budget_exceeded
    assert RunnerObserver.classify_failure("startup_no_progress total_tokens=120000") == :startup_no_progress

    assert RunnerObserver.classify_failure("fatal: unable to access URL: Could not resolve host: github.com") ==
             :external_service_failure
  end

  test "classifies package-manager setup in the wrong directory as requirements mismatch" do
    failure = """
    ERR_PNPM_NO_PKG_MANIFEST No package.json found in /Users/brianseong/Develop/Labs/worktrees/GH-353
    """

    assert RunnerObserver.classify_failure(failure) == :requirements_mismatch
  end

  test "classifies connector approval elicitations as non-retryable permission loops" do
    failure =
      ~s|{:turn_input_required, %{"method" => "mcpServer/elicitation/request", "params" => %{"_meta" => %{"codex_approval_kind" => "mcp_tool_call", "connector_name" => "GitHub", "tool_title" => "create_branch"}, "message" => "Allow GitHub to create a branch?"}}}|

    assert RunnerObserver.classify_failure(failure) == :permission_denied_loop

    payload = %{
      payload: %{
        "method" => "mcpServer/elicitation/request",
        "params" => %{
          "message" => "Allow GitHub to create a branch?",
          "_meta" => %{
            "codex_approval_kind" => "mcp_tool_call",
            "connector_name" => "GitHub",
            "tool_title" => "create_branch"
          }
        }
      }
    }

    assert RunnerObserver.classify_event(:turn_input_required, payload) == :permission_denied_loop
  end

  test "classifies final agent permission blocker messages" do
    payload = %{
      message: "gh pr create failed: CreatePullRequest needs the correct permissions"
    }

    assert RunnerObserver.classify_event(:agent_message, payload) == :auth_failure
  end

  test "classifies failed validation command notifications" do
    payload = %{
      payload: %{
        "method" => "item/completed",
        "params" => %{"title" => "command execution (failed)"}
      },
      raw: """
      item completed: command execution (call_123, failed)
      SYMPHONY_SERVER_PORT=0 mix test test/symphony_elixir/runner_smoke_test.exs
      1 test, 1 failure
      """
    }

    assert RunnerObserver.classify_event(:notification, payload) == :validation_failure_repeat
  end

  test "preserves preflight classifications through wrapped worker failures" do
    failure = %{
      classification: :missing_tool,
      reason: "missing required runner tool(s): codex",
      missing_tools: ["codex"]
    }

    assert RunnerObserver.classify_failure({:preflight_failed, failure}) == :missing_tool
    assert RunnerObserver.classify_failure(%{"classification" => "missing_tool"}) == :missing_tool
  end

  test "does not classify normal json payload text as a stream failure" do
    refute RunnerObserver.classify_event(:session_started, %{jsonrpc: "2.0", path: "package.json"})
    assert RunnerObserver.classify_event(:stderr, "invalid json from app-server stream") == :no_json_event_timeout
  end

  test "ignores historical run-log text inside benign event payloads" do
    old_log_payload = %{
      payload: %{
        "method" => "item/tool/call",
        "params" => %{
          "arguments" => %{
            "body" => "previous Symphony run log contained missing_tool, auth_failure, and validation_failure_repeat"
          }
        }
      },
      raw: "previous Symphony run log contained missing_tool and auth_failure"
    }

    refute RunnerObserver.classify_event(:notification, old_log_payload)
    refute RunnerObserver.classify_event(:tool_call_completed, old_log_payload)
  end

  test "classifies only trusted failure fields for runner events" do
    startup_payload = %{reason: {:preflight_failed, %{classification: :missing_tool}}}

    assert RunnerObserver.classify_event(:startup_failed, startup_payload) ==
             :missing_tool

    assert RunnerObserver.classify_event(:tool_call_failed, %{payload: "old validation failed text"}) ==
             :tool_failure_repeat

    assert RunnerObserver.classify_event(:turn_ended_with_error, %{reason: "no_progress_budget_exceeded"}) ==
             :no_progress_budget_exceeded
  end

  test "preflight reports missing command tools with deterministic evidence" do
    assert {:error,
            %{
              classification: :missing_tool,
              missing_tools: ["definitely-missing-symphony-tool"],
              failure_fingerprint: fingerprint,
              suggested_action: suggested_action
            }} =
             RunnerObserver.preflight("definitely-missing-symphony-tool app-server", shell: "sh")

    assert fingerprint =~ "missing_tool"
    assert suggested_action =~ "missing toolchain"
  end

  test "preflight preserves commands that require shell expansion" do
    assert :ok = RunnerObserver.preflight("$CODEX_BIN app-server", shell: "sh")
    assert :ok = RunnerObserver.preflight("./bin/codex app-server", shell: "sh")
    assert :ok = RunnerObserver.preflight("source ~/.nvm/nvm.sh && codex app-server", shell: "sh")
    assert :ok = RunnerObserver.preflight("CODEX_BIN=codex $CODEX_BIN app-server", shell: "sh")
  end

  test "preflight resolves simple commands through the configured launch shell" do
    previous_path = System.get_env("PATH")
    shell_dir = Path.join(System.tmp_dir!(), "symphony-shell-#{System.unique_integer([:positive])}")
    shell_path = Path.join(shell_dir, "symphony-test-shell")

    File.mkdir_p!(shell_dir)

    File.write!(shell_path, """
    #!/bin/sh
    case "$*" in
      *"command -v shell-only-tool"*) exit 0 ;;
      *) exec /bin/sh "$@" ;;
    esac
    """)

    File.chmod!(shell_path, 0o755)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(shell_dir)
    end)

    System.put_env("PATH", shell_dir <> ":" <> (previous_path || ""))

    assert System.find_executable("shell-only-tool") == nil
    assert :ok = RunnerObserver.preflight("shell-only-tool app-server", shell: "symphony-test-shell")
  end

  test "retry ceiling helper blocks attempt four when default max is three" do
    refute RunnerObserver.max_retry_attempts_exceeded?(3, 3)
    assert RunnerObserver.max_retry_attempts_exceeded?(4, 3)

    assert RunnerObserver.retry_limit_error(4, 3, :missing_tool) ==
             "max retry attempts exceeded: attempt=4 max=3 classification=missing_tool"
  end

  test "run log surfaces tracker writeback failures" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_comment_result, {:error, :linear_unavailable})

    assert {:error, :linear_unavailable} =
             RunLog.log("issue-run-log", :"retry.scheduled", %{identifier: "LAB-TEST"})
  end
end
