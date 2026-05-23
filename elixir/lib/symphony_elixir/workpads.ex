defmodule SymphonyElixir.Workpads do
  @moduledoc """
  Local-first workpad helpers for Symphony planning state.
  """

  @sections [
    "Environment",
    "Issue Type",
    "Milestone",
    "Scope Interpretation",
    "Non-Goals",
    "Acceptance Criteria",
    "Validation / Test Plan",
    "Risk And Checkpoints",
    "Implementation Plan",
    "Evidence",
    "Confusions",
    "Proposed Spec Amendments"
  ]

  @section_fields [
    {"Environment", [:environment]},
    {"Issue Type", [:issue_type]},
    {"Milestone", [:milestone]},
    {"Scope Interpretation", [:scope_interpretation]},
    {"Non-Goals", [:non_goals]},
    {"Acceptance Criteria", [:acceptance_criteria]},
    {"Validation / Test Plan", [:validation_test_plan, :validation_plan]},
    {"Risk And Checkpoints", [:risk_and_checkpoints]},
    {"Implementation Plan", [:implementation_plan]},
    {"Evidence", [:evidence]},
    {"Confusions", [:confusions]},
    {"Proposed Spec Amendments", [:proposed_spec_amendments]}
  ]

  @spec sections() :: [String.t()]
  def sections, do: @sections

  @spec new_body(map()) :: String.t()
  def new_body(attrs \\ %{}) when is_map(attrs) do
    rendered_sections =
      Enum.map(@section_fields, fn {section, keys} ->
        """
        ### #{section}

        #{attrs |> section_value(keys) |> format_value()}
        """
        |> String.trim_trailing()
      end)

    Enum.join(["## Symphony Workpad" | rendered_sections], "\n\n") <> "\n"
  end

  @spec contains_required_sections?(term()) :: boolean()
  def contains_required_sections?(body) when is_binary(body) do
    String.contains?(body, "## Symphony Workpad") and
      Enum.all?(@sections, &section_present?(body, &1))
  end

  def contains_required_sections?(_body), do: false

  defp section_value(attrs, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
    end)
  end

  defp format_value(nil), do: ""
  defp format_value(""), do: ""

  defp format_value(values) when is_list(values) do
    Enum.map_join(values, "\n", &format_list_item/1)
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp format_list_item(value) when is_binary(value), do: "- #{value}"
  defp format_list_item(value), do: "- #{inspect(value)}"

  defp section_present?(body, section) do
    Regex.match?(~r/(^|\n)###\s+#{Regex.escape(section)}\s*(\n|$)/, body)
  end
end
