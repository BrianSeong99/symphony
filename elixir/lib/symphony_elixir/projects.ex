defmodule SymphonyElixir.Projects do
  @moduledoc """
  Dashboard-first project onboarding and connection mode rules.
  """

  @connection_modes [:none, :context_only, :pr_only, :issue_mirror, :full_sync]

  @spec connection_modes() :: [atom()]
  def connection_modes, do: @connection_modes

  @spec connection_mode_strings() :: [String.t()]
  def connection_mode_strings, do: Enum.map(@connection_modes, &Atom.to_string/1)
end
