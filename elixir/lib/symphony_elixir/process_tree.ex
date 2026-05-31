defmodule SymphonyElixir.ProcessTree do
  @moduledoc """
  Small local process-tree terminator for host-runner child processes.
  """

  @spec terminate(integer() | String.t() | nil) :: :ok
  def terminate(pid), do: terminate(pid, [])

  @spec terminate(integer() | String.t() | nil, keyword()) :: :ok
  def terminate(pid, opts) do
    case parse_pid(pid) do
      {:ok, root_pid} ->
        grace_ms = Keyword.get(opts, :grace_ms, 250)
        pids = descendant_pids(root_pid) ++ [root_pid]

        signal_pids(pids, "TERM")
        sleep_grace(grace_ms)

        pids
        |> Enum.filter(&alive?/1)
        |> signal_pids("KILL")

        :ok

      :error ->
        :ok
    end
  end

  defp parse_pid(pid) when is_integer(pid) and pid > 0, do: {:ok, pid}

  defp parse_pid(pid) when is_binary(pid) do
    pid
    |> String.trim()
    |> Integer.parse()
    |> case do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_pid(_pid), do: :error

  defp descendant_pids(root_pid) when is_integer(root_pid) do
    children_by_parent =
      "ps"
      |> System.cmd(["-axo", "pid=,ppid="], stderr_to_stdout: true)
      |> case do
        {output, 0} -> output
        {_output, _status} -> ""
      end
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case parse_ps_line(line) do
          {:ok, pid, ppid} -> Map.update(acc, ppid, [pid], &[pid | &1])
          :error -> acc
        end
      end)

    collect_descendants(children_by_parent, [root_pid], [])
  rescue
    _error -> []
  end

  defp parse_ps_line(line) when is_binary(line) do
    with [pid, ppid] <- line |> String.trim() |> String.split(~r/\s+/, parts: 2),
         {pid, ""} <- Integer.parse(pid),
         {ppid, ""} <- Integer.parse(ppid) do
      {:ok, pid, ppid}
    else
      _ -> :error
    end
  end

  defp collect_descendants(_children_by_parent, [], descendants), do: descendants

  defp collect_descendants(children_by_parent, [pid | rest], descendants) do
    children = Map.get(children_by_parent, pid, [])
    collect_descendants(children_by_parent, children ++ rest, children ++ descendants)
  end

  defp signal_pids(pids, signal) when is_list(pids) do
    pids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == self_os_pid()))
    |> Enum.each(fn pid ->
      try do
        System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
      rescue
        _error -> :ok
      end
    end)
  end

  defp sleep_grace(grace_ms) when is_integer(grace_ms) and grace_ms > 0, do: Process.sleep(grace_ms)
  defp sleep_grace(_grace_ms), do: :ok

  defp alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  rescue
    _error -> false
  end

  defp self_os_pid do
    System.pid()
    |> String.to_integer()
  rescue
    _error -> nil
  end
end
