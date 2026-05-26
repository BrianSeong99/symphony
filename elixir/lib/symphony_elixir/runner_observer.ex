defmodule SymphonyElixir.RunnerObserver do
  @moduledoc """
  Deterministic runner-health classification for unattended Symphony runs.

  The observer intentionally does not ask the model whether it is healthy. It
  classifies process, stream, retry, timeout, and validation signals from the
  orchestration layer so stale state can become visible and bounded.
  """

  @type classification ::
          :api_retries_exhausted
          | :auth_failure
          | :budget_exhausted
          | :compaction_stall
          | :external_service_failure
          | :internal_error
          | :max_retry_attempts_exceeded
          | :max_turns_exceeded
          | :missing_tool
          | :no_progress_budget_exceeded
          | :no_json_event_timeout
          | :no_output_timeout
          | :permission_denied_loop
          | :process_exit_nonzero
          | :requirements_mismatch
          | :startup_token_budget_exceeded
          | :tool_failure_repeat
          | :token_budget_exceeded
          | :turn_failed
          | :unknown_failure
          | :validation_failure_repeat

  @type failure :: term()

  @classification_patterns [
    {:missing_tool,
     [
       "missing_tool",
       "missing required runner tool",
       "missing required executable",
       "bash_not_found",
       "enoent",
       "executable not found",
       "command not found",
       "no such file"
     ]},
    {:auth_failure,
     [
       "401",
       "403",
       "unauthorized",
       "forbidden",
       "missing_linear_api_token",
       "missing auth",
       "expired credential",
       "createpullrequest",
       "correct permissions"
     ]},
    {:api_retries_exhausted, ["api_retries_exhausted", "retries exhausted"]},
    {:internal_error, ["internal_error", "internal error"]},
    {:compaction_stall, ["compaction_stall", "no_output_after_compaction", "precompact", "postcompact", "compaction"]},
    {:no_json_event_timeout, ["malformed json", "invalid json", "no_json_event_timeout", "json event timeout", "no json event"]},
    {:no_output_timeout, ["turn_timeout", "response_timeout", "stalled", "no output", "without codex activity"]},
    {:no_progress_budget_exceeded, ["no_progress_budget_exceeded", "no progress budget", "no git progress"]},
    {:startup_token_budget_exceeded, ["startup_token_budget_exceeded", "startup token budget", "startup max total tokens"]},
    {:token_budget_exceeded, ["token_budget_exceeded", "hard token budget", "max total tokens"]},
    {:permission_denied_loop,
     [
       "permission denied",
       "approval_required",
       "requires approval",
       "eperm",
       "operation not permitted",
       "mcpserver/elicitation/request",
       "codex_approval_kind",
       "mcp_tool_call",
       "allow github to create a branch",
       "allow github",
       "approval prompt"
     ]},
    {:requirements_mismatch,
     [
       "requirements_mismatch",
       "validation contract",
       "acceptance criteria mismatch",
       "err_pnpm_no_pkg_manifest",
       "no package.json found",
       "no package manifest found"
     ]},
    {:validation_failure_repeat, ["validation_failure_repeat", "test failure", "mix test", "validation failed"]},
    {:tool_failure_repeat, ["tool_failure_repeat", "tool_call_failed"]},
    {:external_service_failure,
     [
       "econnrefused",
       "timeout connecting",
       "external_service_failure",
       "service unavailable",
       "could not resolve host",
       "could not reach host",
       "name or service not known",
       "temporary failure in name resolution"
     ]},
    {:budget_exhausted, ["budget_exhausted", "max-budget", "budget exceeded"]},
    {:max_turns_exceeded, ["max_turns_exceeded", "max turns"]},
    {:turn_failed, ["turn_failed", "turn/failed"]},
    {:process_exit_nonzero, ["port_exit", "exit_status", "nonzero", "agent exited"]}
  ]

  @known_classifications Keyword.keys(@classification_patterns) ++ [:max_retry_attempts_exceeded]
  @trusted_event_names %{
    "malformed" => :malformed,
    "stderr" => :stderr,
    "startup_failed" => :startup_failed,
    "notification" => :notification,
    "turn_ended_with_error" => :turn_ended_with_error,
    "turn_failed" => :turn_failed,
    "turn_cancelled" => :turn_cancelled,
    "tool_call_failed" => :tool_call_failed,
    "agent_message" => :agent_message,
    "unsupported_tool_call" => :unsupported_tool_call,
    "turn_input_required" => :turn_input_required,
    "approval_required" => :approval_required
  }

  @spec classify_failure(failure()) :: classification()
  def classify_failure({:preflight_failed, failure}), do: classify_failure(failure)
  def classify_failure(%{classification: classification}) when is_atom(classification), do: known_classification(classification)
  def classify_failure(%{"classification" => classification}) when is_atom(classification), do: known_classification(classification)

  def classify_failure(%{"classification" => classification}) when is_binary(classification) do
    classification
    |> String.downcase()
    |> known_classification_name()
  end

  def classify_failure(reason) do
    reason
    |> normalize_reason()
    |> classify_reason_text()
  end

  @spec classify_retry_error(String.t() | nil) :: classification() | nil
  def classify_retry_error(nil), do: nil

  def classify_retry_error(error) when is_binary(error) do
    case classify_reason_text(String.downcase(error)) do
      :unknown_failure -> nil
      classification -> classification
    end
  end

  @spec classify_event(atom() | String.t() | nil, map() | nil) :: classification() | nil
  def classify_event(event, payload \\ nil)

  @spec classify_event(atom() | String.t() | nil, map() | nil) :: classification() | nil
  def classify_event(event, payload) do
    explicit_payload_classification(payload) ||
      event
      |> trusted_event_failure_text(payload)
      |> case do
        nil ->
          nil

        text ->
          case classify_reason_text(text) do
            :unknown_failure -> nil
            classification -> classification
          end
      end
  end

  @spec max_retry_attempts_exceeded?(integer(), integer()) :: boolean()
  def max_retry_attempts_exceeded?(attempt, max_attempts)
      when is_integer(attempt) and is_integer(max_attempts) and max_attempts > 0 do
    attempt > max_attempts
  end

  def max_retry_attempts_exceeded?(_attempt, _max_attempts), do: false

  @spec retry_limit_error(integer(), integer(), classification() | nil) :: String.t()
  def retry_limit_error(attempt, max_attempts, classification) do
    base = "max retry attempts exceeded: attempt=#{attempt} max=#{max_attempts}"

    case classification do
      nil -> base
      classification -> "#{base} classification=#{classification}"
    end
  end

  @spec failure_fingerprint(failure(), classification() | nil) :: String.t()
  def failure_fingerprint(reason, classification \\ nil) do
    classification = classification || classify_failure(reason)

    reason
    |> normalize_reason()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 240)
    |> then(&"#{classification}:#{&1}")
  end

  @spec suggested_action(classification() | nil) :: String.t()
  def suggested_action(:missing_tool), do: "Block the run, install or route the missing toolchain, then retry from the same issue workspace."
  def suggested_action(:no_progress_budget_exceeded), do: "Stop the stale process, preserve the worktree, and inspect why no branch/file/PR progress occurred within budget."
  def suggested_action(:startup_token_budget_exceeded), do: "Stop the process, preserve the worktree, shrink startup context, then retry with a narrower prompt and fewer initial reads."
  def suggested_action(:token_budget_exceeded), do: "Stop the process, preserve the worktree, shrink context or split scope, then retry with a tighter prompt."
  def suggested_action(:no_output_timeout), do: "Stop the stale process, preserve the worktree, and retry once with the same issue context."
  def suggested_action(:no_json_event_timeout), do: "Treat the app-server stream as unhealthy and restart the session after recording the last raw output."
  def suggested_action(:compaction_stall), do: "Resume the same issue with a compacted workpad summary and do not start unrelated work."
  def suggested_action(:auth_failure), do: "Block until credentials are restored; do not keep retrying."
  def suggested_action(:permission_denied_loop), do: "Block and surface the denied command or approval request."
  def suggested_action(:validation_failure_repeat), do: "Compare validation output with acceptance criteria and update the issue before more fixes."
  def suggested_action(:requirements_mismatch), do: "Update the issue/workpad requirements, re-plan, then continue in the same builder session."
  def suggested_action(:external_service_failure), do: "Record the dependency health evidence and retry only after the service is reachable."
  def suggested_action(:process_exit_nonzero), do: "Retry only within policy after preserving exit output and command context."
  def suggested_action(:max_retry_attempts_exceeded), do: "Stop broad rollout and diagnose the repeated failure before any further retry."
  def suggested_action(:max_turns_exceeded), do: "Block and split or re-plan the issue before continuing."
  def suggested_action(:budget_exhausted), do: "Block and wait for budget/quota recovery or route to an approved runtime."
  def suggested_action(_classification), do: "Record evidence, classify the failure, and require a concrete next action before retrying."

  @spec preflight(String.t(), keyword()) :: :ok | {:error, map()}
  def preflight(command, opts \\ [])

  @spec preflight(String.t(), keyword()) :: :ok | {:error, map()}
  def preflight(command, opts) when is_binary(command) do
    shell = Keyword.get(opts, :shell, "bash")
    shell_executable = System.find_executable(shell)
    command_executable = command_executable(command)

    missing_tools =
      cond do
        is_nil(shell_executable) ->
          [shell]

        is_nil(command_executable) ->
          []

        shell_resolves_command?(shell_executable, command_executable) ->
          []

        true ->
          [command_executable]
      end

    case missing_tools do
      [] ->
        :ok

      missing_tools ->
        reason = "missing required runner tool(s): #{Enum.join(missing_tools, ", ")}"

        {:error,
         %{
           classification: :missing_tool,
           reason: reason,
           missing_tools: missing_tools,
           failure_fingerprint: failure_fingerprint(reason, :missing_tool),
           suggested_action: suggested_action(:missing_tool)
         }}
    end
  end

  def preflight(command, _opts) do
    reason = "invalid runner command: #{inspect(command)}"

    {:error,
     %{
       classification: :missing_tool,
       reason: reason,
       missing_tools: [],
       failure_fingerprint: failure_fingerprint(reason, :missing_tool),
       suggested_action: suggested_action(:missing_tool)
     }}
  end

  defp classify_reason_text(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    Enum.find_value(@classification_patterns, :unknown_failure, fn {classification, patterns} ->
      if Enum.any?(patterns, &String.contains?(normalized, &1)) do
        classification
      end
    end)
  end

  defp explicit_payload_classification(%{classification: classification}), do: known_classification_value(classification)
  defp explicit_payload_classification(%{"classification" => classification}), do: known_classification_value(classification)
  defp explicit_payload_classification(_payload), do: nil

  defp known_classification_value(classification) when is_atom(classification) do
    case known_classification(classification) do
      :unknown_failure -> nil
      known -> known
    end
  end

  defp known_classification_value(classification) when is_binary(classification) do
    case classification |> String.downcase() |> known_classification_name() do
      :unknown_failure -> nil
      known -> known
    end
  end

  defp known_classification_value(_classification), do: nil

  defp trusted_event_failure_text(event, payload) do
    case normalize_event_name(event) do
      :malformed ->
        "malformed json"

      :notification ->
        notification_failure_text(payload)

      :stderr ->
        trusted_payload_reason(payload, include_raw?: true)

      event
      when event in [
             :startup_failed,
             :turn_ended_with_error,
             :turn_failed,
             :turn_cancelled,
             :tool_call_failed,
             :agent_message,
             :unsupported_tool_call,
             :turn_input_required,
             :approval_required
           ] ->
        include_raw? = event in [:turn_input_required, :approval_required]

        [Atom.to_string(event), trusted_payload_reason(payload, include_raw?: include_raw?)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")

      _event ->
        nil
    end
  end

  defp notification_failure_text(payload) do
    text = normalize_reason(payload)

    cond do
      not command_execution_failed?(text) ->
        nil

      validation_failure_text?(text) ->
        "validation failed #{text}"

      true ->
        "tool_call_failed #{text}"
    end
  end

  defp command_execution_failed?(text) when is_binary(text) do
    String.contains?(text, "command execution") and String.contains?(text, "failed")
  end

  defp validation_failure_text?(text) when is_binary(text) do
    String.contains?(text, [
      "mix test",
      "exunit",
      "test/",
      "1 failure",
      "2 failures",
      "failed tests"
    ])
  end

  defp normalize_event_name(event) when is_atom(event), do: event

  defp normalize_event_name(event) when is_binary(event) do
    event
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> then(&Map.get(@trusted_event_names, &1))
  end

  defp normalize_event_name(_event), do: nil

  defp trusted_payload_reason(payload, opts) when is_map(payload) do
    include_raw? = Keyword.get(opts, :include_raw?, false)

    keys =
      [:classification, "classification", :reason, "reason", :error, "error", :details, "details", :message, "message"]

    raw_keys = if include_raw?, do: [:payload, "payload", :raw, "raw"], else: []
    nested_details = if include_raw?, do: trusted_nested_payload_details(payload), else: []

    (keys ++ raw_keys)
    |> Enum.map(&Map.get(payload, &1))
    |> Kernel.++(nested_details)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_reason/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp trusted_payload_reason(payload, _opts) when is_binary(payload), do: normalize_reason(payload)
  defp trusted_payload_reason(payload, _opts), do: normalize_reason(payload)

  defp trusted_nested_payload_details(payload) when is_map(payload) do
    nested_payload = Map.get(payload, :payload) || Map.get(payload, "payload") || %{}

    [
      get_in(nested_payload, ["method"]),
      get_in(nested_payload, ["params", "message"]),
      get_in(nested_payload, ["params", "_meta", "codex_approval_kind"]),
      get_in(nested_payload, ["params", "_meta", "connector_name"]),
      get_in(nested_payload, ["params", "_meta", "tool_title"]),
      get_in(nested_payload, ["params", "_meta", "tool_description"])
    ]
  end

  defp trusted_nested_payload_details(_payload), do: []

  defp known_classification(classification) do
    if classification in @known_classifications do
      classification
    else
      :unknown_failure
    end
  end

  defp known_classification_name(classification) do
    Enum.find(@known_classifications, :unknown_failure, &(Atom.to_string(&1) == classification))
  end

  defp normalize_reason(reason) when is_binary(reason), do: String.downcase(reason)
  defp normalize_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> String.downcase()
  defp normalize_reason(reason), do: reason |> inspect(limit: 50, printable_limit: 2_000) |> String.downcase()

  defp command_executable(command) when is_binary(command) do
    trimmed = String.trim(command)

    if shell_command?(trimmed) do
      nil
    else
      trimmed
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> normalize_command_executable()
    end
  end

  defp shell_command?(command) when is_binary(command) do
    String.contains?(command, ["&&", "||", ";", "|", "<", ">", "\n", "\r"]) or
      command
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> shell_leading_token?()
  end

  defp shell_leading_token?(token) when token in ["source", ".", "cd", "export", "eval", "exec", "alias", "ulimit"], do: true
  defp shell_leading_token?(token) when is_binary(token), do: String.contains?(token, ["=", "~", "$", "`"])
  defp shell_leading_token?(_token), do: true

  defp normalize_command_executable(nil), do: nil
  defp normalize_command_executable(""), do: nil

  defp normalize_command_executable("$" <> _command), do: nil

  defp normalize_command_executable(command) do
    command
    |> String.trim_leading("'")
    |> String.trim_leading("\"")
    |> String.trim_trailing("'")
    |> String.trim_trailing("\"")
    |> literal_path_executable()
  end

  defp literal_path_executable(command) do
    cond do
      command == "" -> nil
      String.starts_with?(command, "$") -> nil
      String.contains?(command, "/") -> nil
      String.match?(command, ~r/^[A-Za-z0-9_.-]+$/) -> command
      true -> nil
    end
  end

  defp shell_resolves_command?(shell_executable, command) when is_binary(shell_executable) and is_binary(command) do
    case System.cmd(shell_executable, ["-lc", "command -v #{command} >/dev/null 2>&1"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _error -> false
  end
end
