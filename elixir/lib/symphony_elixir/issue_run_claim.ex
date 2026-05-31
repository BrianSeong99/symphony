defmodule SymphonyElixir.IssueRunClaim do
  @moduledoc """
  Durable per-issue claim used to prevent duplicate runner sessions.

  The orchestrator keeps in-memory `running` state, but multiple runner
  processes or restarts do not share that state. This file-system claim is the
  cross-process guard: exactly one live owner may run an issue, and stale claims
  preserve the last Codex thread id so the next owner can resume instead of
  creating a new chat.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ProcessTree

  @owner_file "claim.json"

  @type claim :: map()

  @spec acquire(Issue.t(), map()) :: {:ok, claim()} | {:error, {:already_claimed, claim()}} | {:error, term()}
  def acquire(%Issue{id: issue_id} = issue, attrs \\ %{}) when is_binary(issue_id) and is_map(attrs) do
    path = claim_path(issue_id)
    owner = owner(path)
    attrs = normalize_attrs(issue, attrs)

    do_acquire(path, owner, attrs, 0)
  end

  @spec update(String.t(), map()) :: :ok | {:error, term()}
  def update(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    path = claim_path(issue_id)

    case read_claim(path) do
      {:ok, claim} ->
        write_claim(path, Map.merge(claim, encode_attrs(attrs)))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec release(String.t(), String.t()) :: :ok
  def release(issue_id, reason \\ "released") when is_binary(issue_id) and is_binary(reason) do
    path = claim_path(issue_id)
    archive_claim(path, issue_id, reason)
    File.rm_rf(path)

    :ok
  end

  @spec active_claim?(String.t()) :: boolean()
  def active_claim?(issue_id) when is_binary(issue_id) do
    issue_id
    |> claim_path()
    |> read_claim()
    |> case do
      {:ok, claim} -> live_owner?(claim)
      _ -> false
    end
  end

  @spec claim_path(String.t()) :: Path.t()
  def claim_path(issue_id) when is_binary(issue_id) do
    Path.join(claim_root(), issue_key(issue_id))
  end

  @spec claim_root() :: Path.t()
  def claim_root do
    Config.settings!().workspace.root
    |> Path.expand()
    |> Path.join(".symphony/issue-runs")
  end

  defp do_acquire(path, owner, attrs, reclaim_attempt) do
    File.mkdir_p!(Path.dirname(path))

    case File.mkdir(path) do
      :ok ->
        claim =
          attrs
          |> Map.merge(owner)
          |> Map.put("status", "running")
          |> Map.put("claimed_at", iso_now())

        case write_claim(path, claim) do
          :ok -> {:ok, claim}
          error -> error
        end

      {:error, :eexist} ->
        handle_existing_claim(path, owner, attrs, reclaim_attempt)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_existing_claim(path, owner, attrs, reclaim_attempt) do
    existing =
      case read_claim(path) do
        {:ok, claim} -> claim
        {:error, _reason} -> %{}
      end

    cond do
      current_owner?(existing) ->
        claim =
          existing
          |> Map.merge(attrs)
          |> maybe_put("resume_thread_id", claim_value(existing, "codex_thread_id"))
          |> maybe_put("previous_session_id", claim_value(existing, "session_id"))
          |> Map.merge(owner)
          |> Map.put("status", "running")
          |> Map.put("claimed_at", iso_now())

        case write_claim(path, claim) do
          :ok -> {:ok, claim}
          error -> error
        end

      live_owner?(existing) ->
        {:error, {:already_claimed, existing}}

      reclaim_attempt < 1 ->
        previous_thread_id = claim_value(existing, "codex_thread_id")
        previous_session_id = claim_value(existing, "session_id")
        previous_workspace_path = claim_value(existing, "workspace_path")

        cleanup_stale_owner_processes(existing)
        File.rm_rf(path)

        attrs =
          attrs
          |> maybe_put("resume_thread_id", previous_thread_id)
          |> maybe_put("previous_session_id", previous_session_id)
          |> maybe_put("previous_workspace_path", previous_workspace_path)
          |> maybe_put("recovered_claim_at", iso_now())

        do_acquire(path, owner, attrs, reclaim_attempt + 1)

      true ->
        {:error, {:already_claimed, existing}}
    end
  end

  defp normalize_attrs(%Issue{} = issue, attrs) do
    attrs
    |> encode_attrs()
    |> Map.put("issue_id", issue.id)
    |> Map.put("identifier", issue.identifier)
    |> Map.put("title", issue.title)
  end

  defp encode_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), encode_value(value)} end)
  end

  defp encode_value(%DateTime{} = datetime), do: DateTime.to_iso8601(DateTime.truncate(datetime, :second))
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp owner(path) do
    %{
      "owner_id" => unique_owner_id(),
      "host" => host(),
      "os_pid" => System.pid(),
      "beam_pid" => self() |> :erlang.pid_to_list() |> to_string(),
      "claim_path" => path
    }
  end

  defp current_owner?(claim) when is_map(claim) do
    claim_value(claim, "host") == host() and
      claim_value(claim, "os_pid") == System.pid() and
      claim_value(claim, "beam_pid") == self() |> :erlang.pid_to_list() |> to_string()
  end

  defp current_owner?(_claim), do: false

  defp live_owner?(claim) when is_map(claim) and map_size(claim) > 0 do
    owner_host = claim_value(claim, "host")
    os_pid = claim_value(claim, "os_pid")
    beam_pid = claim_value(claim, "beam_pid")

    cond do
      owner_host != host() ->
        true

      os_pid == System.pid() ->
        live_beam_pid?(beam_pid)

      is_binary(os_pid) ->
        os_process_alive?(os_pid)

      true ->
        false
    end
  end

  defp live_owner?(_claim), do: false

  defp cleanup_stale_owner_processes(claim) when is_map(claim) do
    if claim_value(claim, "host") == host() do
      claim
      |> claim_value("codex_app_server_pid")
      |> ProcessTree.terminate()
    end
  end

  defp cleanup_stale_owner_processes(_claim), do: :ok

  defp live_beam_pid?(beam_pid) when is_binary(beam_pid) do
    beam_pid
    |> String.to_charlist()
    |> :erlang.list_to_pid()
    |> Process.alive?()
  rescue
    ArgumentError -> false
  end

  defp live_beam_pid?(_beam_pid), do: false

  defp os_process_alive?(pid) when is_binary(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp read_claim(path) do
    path
    |> Path.join(@owner_file)
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_claim(path, claim) do
    File.mkdir_p!(path)
    File.write(Path.join(path, @owner_file), Jason.encode!(claim))
  end

  defp archive_claim(path, issue_id, reason) do
    case read_claim(path) do
      {:ok, claim} ->
        archive_root = Path.join(claim_root(), "archive")
        File.mkdir_p!(archive_root)

        archive =
          claim
          |> Map.put("status", "archived")
          |> Map.put("archive_reason", reason)
          |> Map.put("archived_at", iso_now())

        File.write(Path.join(archive_root, "#{issue_key(issue_id)}-#{archive_stamp()}.json"), Jason.encode!(archive))

      {:error, _reason} ->
        :ok
    end
  end

  defp claim_value(claim, key), do: Map.get(claim, key) || Map.get(claim, String.to_atom(key))

  defp issue_key(issue_id) do
    :crypto.hash(:sha256, issue_id)
    |> Base.encode16(case: :lower)
  end

  defp host do
    case :inet.gethostname() do
      {:ok, hostname} -> List.to_string(hostname)
      _ -> "unknown"
    end
  end

  defp unique_owner_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp iso_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp archive_stamp do
    DateTime.utc_now()
    |> DateTime.to_unix(:microsecond)
    |> Integer.to_string()
  end
end
