defmodule SymphonyElixir.RunnerReadiness do
  @moduledoc """
  Host-runtime readiness checks for GitHub-backed runner lanes.

  Symphony can run as a service, but GitHub lanes execute code through the
  local host toolchain. These checks make that contract visible before the
  orchestrator dispatches work into a loop that cannot succeed.
  """

  alias SymphonyElixir.Config.Schema

  @sensitive_patterns [
    ~r/github_pat_[A-Za-z0-9_]+/,
    ~r/gh[pousr]_[A-Za-z0-9_]+/,
    ~r/sk-[A-Za-z0-9_-]+/,
    ~r/(Authorization:\s*(Bearer|token)\s+)[^\s]+/i,
    ~r/(LINEAR_API_KEY=)[^\s]+/i,
    ~r/(GITHUB_TOKEN=)[^\s]+/i,
    ~r/(GH_TOKEN=)[^\s]+/i
  ]

  @type check_status :: :ok | :error | :skipped
  @type check :: %{
          name: String.t(),
          status: check_status(),
          message: String.t() | nil
        }

  @type snapshot :: %{
          status: check_status(),
          runtime: String.t(),
          tracker: map(),
          checked_at: DateTime.t(),
          checks: [check()]
        }

  @spec check(Schema.t()) :: {:ok, snapshot()} | {:error, snapshot()}
  def check(%Schema{} = settings) do
    case settings.tracker.kind do
      "github" -> check_github_lane(settings)
      _kind -> {:ok, skipped_snapshot(settings)}
    end
  end

  @spec sanitize_error(term()) :: String.t()
  def sanitize_error(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> mask_sensitive_values()
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.slice(0, 1_000)
  end

  defp check_github_lane(%Schema{} = settings) do
    checks = [
      executable_check("git"),
      executable_check("gh"),
      gh_auth_check(),
      source_repo_check(settings.workspace.source_repo),
      worktree_root_check(settings.workspace.root),
      codex_executable_check(settings.codex.command),
      codex_home_check(),
      codex_app_server_command_check(settings.codex.command)
    ]

    snapshot = %{
      status: aggregate_status(checks),
      runtime: "local-host",
      tracker: tracker_descriptor(settings),
      checked_at: DateTime.utc_now(),
      checks: checks
    }

    case snapshot.status do
      :ok -> {:ok, snapshot}
      :error -> {:error, snapshot}
    end
  end

  defp skipped_snapshot(%Schema{} = settings) do
    %{
      status: :skipped,
      runtime: "not-required",
      tracker: tracker_descriptor(settings),
      checked_at: DateTime.utc_now(),
      checks: [
        %{
          name: "host_runtime_contract",
          status: :skipped,
          message: "host runtime readiness is enforced for GitHub lanes"
        }
      ]
    }
  end

  defp tracker_descriptor(%Schema{} = settings) do
    %{
      kind: settings.tracker.kind,
      repository: settings.tracker.repository,
      project_slug: settings.tracker.project_slug
    }
  end

  defp aggregate_status(checks) do
    if Enum.all?(checks, &(&1.status == :ok)), do: :ok, else: :error
  end

  defp executable_check(name) do
    case find_executable(name) do
      nil ->
        %{
          name: "#{name}_executable",
          status: :error,
          message: "missing required executable: #{name}"
        }

      path ->
        %{
          name: "#{name}_executable",
          status: :ok,
          message: path
        }
    end
  end

  defp gh_auth_check do
    case run_command("gh", ["auth", "status"]) do
      {_output, 0} ->
        %{name: "gh_auth", status: :ok, message: "authenticated"}

      {output, status} ->
        %{
          name: "gh_auth",
          status: :error,
          message: "gh auth status failed status=#{status}: #{sanitize_output(output)}"
        }
    end
  rescue
    error ->
      %{name: "gh_auth", status: :error, message: "gh auth status failed: #{sanitize_error(error)}"}
  end

  defp source_repo_check(source_repo) when is_binary(source_repo) and source_repo != "" do
    source_repo = Path.expand(source_repo)

    if File.dir?(source_repo) do
      case run_command("git", ["-C", source_repo, "rev-parse", "--show-toplevel"]) do
        {_output, 0} ->
          %{name: "source_repo", status: :ok, message: source_repo}

        {output, status} ->
          %{
            name: "source_repo",
            status: :error,
            message: "workspace.source_repo is not a git repo status=#{status}: #{sanitize_output(output)}"
          }
      end
    else
      %{name: "source_repo", status: :error, message: "workspace.source_repo is missing: #{source_repo}"}
    end
  rescue
    error ->
      %{name: "source_repo", status: :error, message: "source repo check failed: #{sanitize_error(error)}"}
  end

  defp source_repo_check(_source_repo) do
    %{name: "source_repo", status: :error, message: "workspace.source_repo is required for GitHub lanes"}
  end

  defp worktree_root_check(root) when is_binary(root) and root != "" do
    root = Path.expand(root)
    probe_dir = if File.dir?(root), do: root, else: Path.dirname(root)
    probe = Path.join(probe_dir, ".symphony-readiness-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(probe_dir),
         :ok <- File.write(probe, "ok"),
         :ok <- File.rm(probe) do
      %{name: "worktree_root_writable", status: :ok, message: root}
    else
      {:error, reason} ->
        %{
          name: "worktree_root_writable",
          status: :error,
          message: "workspace.root is not writable: #{root} reason=#{inspect(reason)}"
        }
    end
  rescue
    error ->
      %{name: "worktree_root_writable", status: :error, message: "worktree root check failed: #{sanitize_error(error)}"}
  end

  defp worktree_root_check(_root) do
    %{name: "worktree_root_writable", status: :error, message: "workspace.root is required"}
  end

  defp codex_executable_check(command) do
    executable = command_executable(command)

    cond do
      is_nil(executable) ->
        %{name: "codex_executable", status: :error, message: "codex.command is missing an executable"}

      Path.basename(executable) != "codex" ->
        %{
          name: "codex_executable",
          status: :error,
          message: "codex.command must invoke codex app-server; found #{executable}"
        }

      not executable_available?(executable) ->
        %{name: "codex_executable", status: :error, message: "missing required executable: #{executable}"}

      true ->
        %{name: "codex_executable", status: :ok, message: executable}
    end
  end

  defp codex_home_check do
    codex_home =
      System.get_env("CODEX_HOME") ||
        Path.join(System.user_home!(), ".codex")

    if File.dir?(codex_home) do
      %{name: "codex_home", status: :ok, message: codex_home}
    else
      %{name: "codex_home", status: :error, message: "Codex config directory is missing: #{codex_home}"}
    end
  rescue
    error ->
      %{name: "codex_home", status: :error, message: "Codex config check failed: #{sanitize_error(error)}"}
  end

  defp codex_app_server_command_check(command) when is_binary(command) do
    tokens = command_tokens(command)

    if "app-server" in tokens do
      %{name: "codex_app_server_command", status: :ok, message: "codex app-server configured"}
    else
      %{name: "codex_app_server_command", status: :error, message: "codex.command must run app-server"}
    end
  end

  defp codex_app_server_command_check(_command) do
    %{name: "codex_app_server_command", status: :error, message: "codex.command is required"}
  end

  defp command_executable(command) when is_binary(command) do
    command
    |> command_tokens()
    |> Enum.drop_while(&env_assignment?/1)
    |> List.first()
  end

  defp command_executable(_command), do: nil

  defp command_tokens(command) when is_binary(command) do
    OptionParser.split(command)
  rescue
    _error -> String.split(command)
  end

  defp env_assignment?(token) when is_binary(token), do: String.match?(token, ~r/^[A-Za-z_][A-Za-z0-9_]*=/)
  defp env_assignment?(_token), do: false

  defp find_executable(executable) when is_binary(executable) do
    finder = Application.get_env(:symphony_elixir, :runner_readiness_find_executable, &System.find_executable/1)
    finder.(executable)
  end

  defp find_executable(_executable), do: nil

  defp executable_available?(executable) when is_binary(executable) do
    if String.contains?(executable, "/") do
      File.exists?(executable)
    else
      not is_nil(find_executable(executable))
    end
  end

  defp executable_available?(_executable), do: false

  defp run_command(command, args) do
    runner =
      Application.get_env(:symphony_elixir, :runner_readiness_command_runner, fn executable, command_args ->
        System.cmd(executable, command_args, stderr_to_stdout: true)
      end)

    runner.(command, args)
  end

  defp sanitize_output(output) when is_binary(output) do
    output
    |> mask_sensitive_values()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 500)
  end

  defp sanitize_output(output), do: sanitize_error(output)

  defp mask_sensitive_values(value) when is_binary(value) do
    Enum.reduce(@sensitive_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end
end
