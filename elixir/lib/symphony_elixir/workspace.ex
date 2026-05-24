defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, RunLog, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?, workspace_kind} <-
             ensure_workspace(workspace, worker_host, safe_id, issue_context),
           :ok <- maybe_log_workspace_ready(issue_context, workspace, worker_host, workspace_kind),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil, safe_id, issue_context) do
    case local_git_worktree_source_repo() do
      nil ->
        ensure_directory_workspace(workspace)

      source_repo ->
        ensure_git_worktree_workspace(workspace, source_repo, safe_id, issue_context)
    end
  end

  defp ensure_workspace(workspace, worker_host, _safe_id, _issue_context) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        with {:ok, workspace, created?} <- parse_remote_workspace_output(output) do
          {:ok, workspace, created?, :remote_directory}
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_directory_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false, :directory}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace, :directory)

      true ->
        create_workspace(workspace, :directory)
    end
  end

  defp create_workspace(workspace, workspace_kind) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true, workspace_kind}
  end

  defp local_git_worktree_source_repo do
    case Config.settings!().workspace.source_repo do
      source_repo when is_binary(source_repo) and source_repo != "" ->
        source_repo
        |> Path.expand()
        |> PathSafety.canonicalize()
        |> case do
          {:ok, canonical_source_repo} -> canonical_source_repo
          {:error, reason} -> raise ArgumentError, "invalid workspace.source_repo: #{inspect(reason)}"
        end

      _ ->
        nil
    end
  end

  defp ensure_git_worktree_workspace(workspace, source_repo, safe_id, issue_context) do
    existing_worktree? = git_worktree?(workspace)

    with :ok <- validate_git_source_repo(source_repo),
         :ok <- prepare_git_worktree_path(workspace),
         :ok <- maybe_fetch_git_base_ref(source_repo),
         branch <- worktree_branch_name(safe_id),
         :ok <- create_git_worktree(source_repo, workspace, branch, Config.settings!().workspace.base_ref),
         :ok <- verify_git_worktree(workspace) do
      Logger.info("Workspace ready as git worktree #{issue_log_context(issue_context)} workspace=#{workspace} source_repo=#{source_repo} branch=#{branch}")
      {:ok, workspace, !existing_worktree?, :git_worktree}
    end
  end

  defp validate_git_source_repo(source_repo) do
    if File.dir?(source_repo) do
      case System.cmd("git", ["-C", source_repo, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:invalid_git_source_repo, source_repo, status, output}}
      end
    else
      {:error, {:missing_git_source_repo, source_repo}}
    end
  end

  defp prepare_git_worktree_path(workspace) do
    cond do
      git_worktree?(workspace) ->
        :ok

      File.dir?(workspace) ->
        quarantine_stale_workspace(workspace)

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        File.mkdir_p!(Path.dirname(workspace))
        :ok

      true ->
        File.mkdir_p!(Path.dirname(workspace))
        :ok
    end
  end

  defp quarantine_stale_workspace(workspace) do
    stale_path = workspace <> ".stale-" <> Integer.to_string(System.system_time(:second))
    File.rename!(workspace, stale_path)
    Logger.warning("Quarantined non-worktree Symphony workspace workspace=#{workspace} stale_path=#{stale_path}")
    :ok
  end

  defp maybe_fetch_git_base_ref(source_repo) do
    case split_remote_base_ref(Config.settings!().workspace.base_ref) do
      {:ok, remote, branch} ->
        maybe_fetch_remote_base_ref(source_repo, remote, branch)

      :local_ref ->
        :ok
    end
  end

  defp maybe_fetch_remote_base_ref(source_repo, remote, branch) do
    case System.cmd("git", ["-C", source_repo, "remote", "get-url", remote], stderr_to_stdout: true) do
      {_remote_url, 0} -> fetch_remote_base_ref(source_repo, remote, branch)
      {_output, _status} -> :ok
    end
  end

  defp fetch_remote_base_ref(source_repo, remote, branch) do
    case System.cmd("git", ["-C", source_repo, "fetch", remote, branch], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> git_fetch_failed(source_repo, status, output)
    end
  end

  defp git_fetch_failed(source_repo, status, output) do
    {:error, {:git_fetch_failed, source_repo, Config.settings!().workspace.base_ref, status, output}}
  end

  defp split_remote_base_ref(base_ref) when is_binary(base_ref) do
    case String.split(base_ref, "/", parts: 2) do
      [remote, branch] when remote != "" and branch != "" -> {:ok, remote, branch}
      _ -> :local_ref
    end
  end

  defp split_remote_base_ref(_base_ref), do: :local_ref

  defp create_git_worktree(source_repo, workspace, branch, base_ref) do
    cond do
      git_worktree?(workspace) and git_current_branch(workspace) == branch ->
        :ok

      git_worktree?(workspace) ->
        recreate_git_worktree(source_repo, workspace, branch, base_ref)

      true ->
        do_create_git_worktree(source_repo, workspace, branch, base_ref)
    end
  end

  defp recreate_git_worktree(source_repo, workspace, branch, base_ref) do
    Logger.warning("Recreating stale Symphony git worktree workspace=#{workspace} expected_branch=#{branch}")

    with :ok <- remove_git_worktree(source_repo, workspace) do
      do_create_git_worktree(source_repo, workspace, branch, base_ref)
    end
  end

  defp remove_git_worktree(source_repo, workspace) do
    case System.cmd("git", ["-C", source_repo, "worktree", "remove", "--force", workspace], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_worktree_remove_failed, workspace, status, output}}
    end
  end

  defp do_create_git_worktree(source_repo, workspace, branch, base_ref) do
    :ok = prune_git_worktrees(source_repo)

    args =
      if git_branch_exists?(source_repo, branch) do
        ["-C", source_repo, "worktree", "add", workspace, branch]
      else
        ["-C", source_repo, "worktree", "add", "-b", branch, workspace, base_ref]
      end

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git_worktree_add_failed, workspace, branch, base_ref, status, output}}
    end
  end

  defp prune_git_worktrees(source_repo) do
    System.cmd("git", ["-C", source_repo, "worktree", "prune"], stderr_to_stdout: true)
    :ok
  end

  defp git_branch_exists?(source_repo, branch) do
    case System.cmd("git", ["-C", source_repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp git_current_branch(workspace) do
    case System.cmd("git", ["-C", workspace, "branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      {_output, _status} -> nil
    end
  end

  defp verify_git_worktree(workspace) do
    if git_worktree?(workspace) do
      :ok
    else
      {:error, {:workspace_not_git_worktree, workspace}}
    end
  end

  defp git_worktree?(workspace) when is_binary(workspace) do
    if File.dir?(workspace) do
      with {git_dir, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "--git-dir"], stderr_to_stdout: true),
           {common_dir, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "--git-common-dir"], stderr_to_stdout: true) do
        normalize_git_path(workspace, git_dir) != normalize_git_path(workspace, common_dir)
      else
        _ -> false
      end
    else
      false
    end
  end

  defp normalize_git_path(workspace, path) when is_binary(path) do
    path = String.trim(path)

    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, workspace)
    end
  end

  defp worktree_branch_name(safe_id) do
    prefix =
      Config.settings!().workspace.branch_prefix
      |> to_string()
      |> String.trim()
      |> String.trim("/")

    case prefix do
      "" -> safe_id
      prefix -> prefix <> "/" <> safe_id
    end
  end

  defp maybe_log_workspace_ready(%{issue_id: issue_id, issue_identifier: identifier}, workspace, worker_host, workspace_kind)
       when is_binary(issue_id) do
    case RunLog.log(issue_id, :"build.progress", %{
           identifier: identifier,
           role: :runner,
           stage: "workspace.ready",
           workspace_kind: workspace_kind,
           worker_host: worker_host || "local",
           worktree: workspace
         }) do
      :ok -> :ok
      {:error, reason} -> {:error, {:linear_writeback_failed, reason}}
    end
  end

  defp maybe_log_workspace_ready(_issue_context, _workspace, _worker_host, _workspace_kind), do: :ok

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            remove_local_workspace_path(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_local_workspace_path(workspace) do
    if git_worktree?(workspace) do
      case System.cmd("git", ["-C", workspace, "worktree", "remove", "--force", workspace], stderr_to_stdout: true) do
        {_output, 0} -> {:ok, []}
        {output, status} -> {:error, {:git_worktree_remove_failed, workspace, status, output}, output}
      end
    else
      File.rm_rf(workspace)
    end
  rescue
    error -> {:error, error, Exception.message(error)}
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
