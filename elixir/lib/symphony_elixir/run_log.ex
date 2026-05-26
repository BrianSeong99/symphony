defmodule SymphonyElixir.RunLog do
  @moduledoc """
  Writes durable runner events back to the configured issue tracker.

  These comments are intentionally structured and compact so an unattended run
  leaves a readable trail without leaking prompts, credentials, or large logs.
  """

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tracker

  @allowed_events MapSet.new([
                    :"plan.started",
                    :"plan.updated",
                    :"build.started",
                    :"build.progress",
                    :"build.validation",
                    :"review.started",
                    :"review.finding",
                    :"review.clean",
                    :"requirement.updated",
                    :"retry.scheduled",
                    :"retry.blocked",
                    :"runner.classified_failure",
                    :"context_ingestion.started",
                    :"context_ingestion.cache_hit",
                    :"context_ingestion.cache_miss",
                    :"context_ingestion.completed",
                    :"context_ingestion.failed",
                    :"context_packet.attached",
                    :"merge.ready",
                    :"merge.done"
                  ])

  @spec allowed_event?(atom()) :: boolean()
  def allowed_event?(event), do: MapSet.member?(@allowed_events, event)

  @spec log(Issue.t() | map() | String.t(), atom(), map()) :: :ok | {:error, term()}
  def log(issue_or_id, event, attrs \\ %{})

  @spec log(Issue.t() | map() | String.t(), atom(), map()) :: :ok | {:error, term()}
  def log(issue_or_id, event, attrs) when is_atom(event) and is_map(attrs) do
    with :ok <- validate_event(event),
         {:ok, issue_id, identifier} <- issue_context(issue_or_id) do
      body = format_body(event, identifier, attrs)

      case upsert_tracker_run_log_comment(issue_id, body) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.warning("Failed to write run log event=#{event} issue_id=#{issue_id}: #{inspect(reason)}")
          error
      end
    end
  end

  def log(_issue_or_id, event, attrs) do
    {:error, {:invalid_run_log, event, attrs}}
  end

  defp validate_event(event) do
    if allowed_event?(event) do
      :ok
    else
      {:error, {:unsupported_run_log_event, event}}
    end
  end

  if Mix.env() == :test do
    defp upsert_tracker_run_log_comment(issue_id, body) do
      if placeholder_linear_config?() do
        :ok
      else
        Tracker.upsert_run_log_comment(issue_id, body)
      end
    end

    defp placeholder_linear_config? do
      settings = SymphonyElixir.Config.settings!()
      settings.tracker.kind == "linear" and settings.tracker.api_key in [nil, "token"]
    end
  else
    defp upsert_tracker_run_log_comment(issue_id, body), do: Tracker.upsert_run_log_comment(issue_id, body)
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    {:ok, issue_id, identifier || issue_id}
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    {:ok, issue_id, identifier || issue_id}
  end

  defp issue_context(%{issue_id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    {:ok, issue_id, identifier || issue_id}
  end

  defp issue_context(issue_id) when is_binary(issue_id), do: {:ok, issue_id, issue_id}
  defp issue_context(other), do: {:error, {:missing_issue_id, other}}

  defp format_body(event, identifier, attrs) do
    attrs =
      attrs
      |> Map.put_new(:identifier, identifier)
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" or value == [] end)

    lines =
      [
        "### Symphony run log: #{event}",
        "",
        "| Field | Value |",
        "| --- | --- |"
      ] ++ Enum.map(attrs, fn {key, value} -> "| `#{key}` | #{format_value(value)} |" end)

    Enum.join(lines, "\n")
  end

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_value(value) when is_atom(value), do: "`#{value}`"
  defp format_value(value) when is_binary(value), do: value |> scrub_value() |> markdown_cell()
  defp format_value(value), do: value |> inspect(limit: 20, printable_limit: 600) |> scrub_value() |> markdown_cell()

  defp scrub_value(value) when is_binary(value) do
    value
    |> String.replace(~r/(sk-[A-Za-z0-9_\-]{12,}|lin_api_[A-Za-z0-9_\-]+)/, "[redacted]")
    |> String.slice(0, 900)
  end

  defp markdown_cell(value) when is_binary(value) do
    value
    |> String.replace("|", "\\|")
    |> String.replace("\n", "<br>")
  end
end
