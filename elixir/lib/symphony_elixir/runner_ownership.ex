defmodule SymphonyElixir.RunnerOwnership do
  @moduledoc """
  Single-owner guard for unattended runner dispatch.

  The guard uses an atomic directory lock so duplicate Symphony services can
  start for observability without also polling Linear and dispatching agents.
  """

  @lock_env "SYMPHONY_RUNNER_LOCK_PATH"
  @enabled_env "SYMPHONY_RUNNER_OWNERSHIP_ENABLED"

  @type acquisition ::
          {:ok, map()}
          | {:error, {:already_owned, map(), String.t()}}
          | {:error, term()}

  @spec acquire(keyword()) :: acquisition()
  def acquire(opts \\ []) do
    settings = Keyword.get(opts, :settings)
    lock_path = Keyword.get(opts, :lock_path) || lock_path(settings)
    owner = owner(lock_path)

    acquire_lock(lock_path, owner, 0)
  end

  @spec release(map() | nil) :: :ok
  def release(%{leader?: true, lock_path: lock_path, owner_id: owner_id})
      when is_binary(lock_path) and is_binary(owner_id) do
    with {:ok, existing_owner} <- read_owner(lock_path),
         ^owner_id <- map_value(existing_owner, ["owner_id", :owner_id]) do
      File.rm_rf(lock_path)
    end

    :ok
  end

  def release(_ownership), do: :ok

  @spec disabled() :: map()
  def disabled do
    %{
      enabled?: false,
      leader?: true,
      mode: "disabled",
      reason: "runner ownership disabled"
    }
  end

  @spec enabled_by_default?() :: boolean()
  def enabled_by_default? do
    case System.get_env(@enabled_env) do
      nil -> not test_env?()
      value -> enabled_string?(value)
    end
  end

  @spec lock_path(term()) :: String.t()
  def lock_path(settings \\ nil) do
    System.get_env(@lock_env) || default_lock_path(settings)
  end

  @spec owner(String.t()) :: map()
  def owner(lock_path) when is_binary(lock_path) do
    %{
      owner_id: unique_owner_id(),
      host: host(),
      os_pid: System.pid(),
      beam_pid: self() |> :erlang.pid_to_list() |> to_string(),
      lock_path: lock_path,
      booted_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp acquire_lock(lock_path, owner, reclaim_attempt) do
    File.mkdir_p!(Path.dirname(lock_path))

    case File.mkdir(lock_path) do
      :ok ->
        write_owner!(lock_path, owner)

        {:ok,
         owner
         |> atomize_owner()
         |> Map.merge(%{enabled?: true, leader?: true, mode: "leader"})}

      {:error, :eexist} ->
        handle_existing_lock(lock_path, owner, reclaim_attempt)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_existing_lock(lock_path, owner, reclaim_attempt) do
    existing_owner =
      case read_owner(lock_path) do
        {:ok, owner} -> owner
        {:error, _reason} -> %{}
      end

    if stale_owner?(existing_owner) and reclaim_attempt < 1 do
      File.rm_rf(lock_path)
      acquire_lock(lock_path, owner, reclaim_attempt + 1)
    else
      {:error, {:already_owned, existing_owner, lock_path}}
    end
  end

  defp stale_owner?(owner) when map_size(owner) == 0, do: true

  defp stale_owner?(owner) when is_map(owner) do
    owner_host = map_value(owner, ["host", :host])
    os_pid = map_value(owner, ["os_pid", :os_pid])
    beam_pid = map_value(owner, ["beam_pid", :beam_pid])

    cond do
      owner_host != host() ->
        false

      os_pid == System.pid() ->
        stale_beam_pid?(beam_pid)

      is_binary(os_pid) ->
        not os_process_alive?(os_pid)

      true ->
        true
    end
  end

  defp stale_owner?(_owner), do: true

  defp stale_beam_pid?(beam_pid) when is_binary(beam_pid) do
    beam_pid
    |> String.to_charlist()
    |> :erlang.list_to_pid()
    |> Process.alive?()
    |> Kernel.not()
  rescue
    ArgumentError -> true
  end

  defp stale_beam_pid?(_beam_pid), do: true

  defp os_process_alive?(pid) when is_binary(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp write_owner!(lock_path, owner) do
    File.write!(Path.join(lock_path, "owner.json"), Jason.encode!(owner))
  end

  defp read_owner(lock_path) do
    case File.read(Path.join(lock_path, "owner.json")) do
      {:ok, body} -> Jason.decode(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomize_owner(owner) do
    %{
      owner_id: map_value(owner, ["owner_id", :owner_id]),
      host: map_value(owner, ["host", :host]),
      os_pid: map_value(owner, ["os_pid", :os_pid]),
      beam_pid: map_value(owner, ["beam_pid", :beam_pid]),
      lock_path: map_value(owner, ["lock_path", :lock_path]),
      booted_at: map_value(owner, ["booted_at", :booted_at])
    }
  end

  defp default_lock_path(settings) do
    project_slug =
      settings
      |> project_slug()
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")

    Path.join(System.tmp_dir!(), "symphony-runner-#{project_slug}.lock")
  end

  defp project_slug(%{tracker: %{project_slug: slug}}) when is_binary(slug) and slug != "", do: slug
  defp project_slug(_settings), do: "default"

  defp host do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "unknown"
    end
  end

  defp unique_owner_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp enabled_string?(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    value in ["1", "true", "yes", "on"]
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  end

  defp map_value(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end
end
