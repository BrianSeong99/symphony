defmodule SymphonyElixir.LoopBreaker.FailureSignature do
  @moduledoc """
  Deterministic signatures for validation failures.
  """

  @type event :: map()

  @spec from_event(event()) :: String.t()
  def from_event(event) when is_map(event) do
    command = event |> field(:command, "") |> normalize_line()
    output = event |> field(:output, "") |> first_meaningful_line() |> normalize_line()

    :crypto.hash(:sha256, "#{command}|#{output}")
    |> Base.encode16(case: :lower)
  end

  @spec describe(event()) :: map()
  def describe(event) when is_map(event) do
    %{
      attempt: field(event, :attempt),
      phase: field(event, :phase),
      command: field(event, :command),
      output_excerpt: event |> field(:output, "") |> first_meaningful_line(),
      signature: from_event(event)
    }
  end

  defp first_meaningful_line(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp first_meaningful_line(_output), do: ""

  defp normalize_line(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_line(_value), do: ""

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
