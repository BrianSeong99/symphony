defmodule Mix.Tasks.Learning.SelfImprovement do
  @moduledoc """
  Runs a dry self-improvement review from a JSON signal file.

      mix learning.self_improvement --signals /tmp/signals.json
      mix learning.self_improvement --signals /tmp/signals.json --existing-issues /tmp/issues.json
  """

  use Mix.Task

  alias SymphonyElixir.Learning.SelfImprovement

  @shortdoc "Prints Symphony self-improvement issue proposals"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          signals: :string,
          existing_issues: :string,
          runner_proven: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Unknown options: #{inspect(invalid)}")
    end

    signals = opts |> Keyword.fetch!(:signals) |> read_json_list!("signals")
    existing_issues = opts |> Keyword.get(:existing_issues) |> read_optional_json_list!("existing issues")

    review =
      SelfImprovement.review(signals,
        existing_issues: existing_issues,
        runner_proven?: Keyword.get(opts, :runner_proven, false)
      )

    Mix.shell().info(Jason.encode!(review, pretty: true))
  end

  defp read_optional_json_list!(nil, _label), do: []
  defp read_optional_json_list!(path, label), do: read_json_list!(path, label)

  defp read_json_list!(path, label) do
    with {:ok, body} <- File.read(Path.expand(path)),
         {:ok, values} when is_list(values) <- Jason.decode(body) do
      values
    else
      {:ok, _other} -> Mix.raise("#{label} file must contain a JSON array")
      {:error, reason} -> Mix.raise("Could not read #{label} file: #{inspect(reason)}")
    end
  end
end
