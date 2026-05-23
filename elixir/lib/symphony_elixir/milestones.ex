defmodule SymphonyElixir.Milestones do
  @moduledoc """
  Local milestone lifecycle and GitHub sync policy.
  """

  @statuses [:active, :paused, :completed, :cancelled]
  @github_sync_modes [:none, :virtual, :native]
  @milestone_types ~w(project-roadmap release integration sprint research-track ops-maintenance launch-critical)

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec status_strings() :: [String.t()]
  def status_strings, do: Enum.map(@statuses, &Atom.to_string/1)

  @spec github_sync_modes() :: [atom()]
  def github_sync_modes, do: @github_sync_modes

  @spec github_sync_mode_strings() :: [String.t()]
  def github_sync_mode_strings, do: Enum.map(@github_sync_modes, &Atom.to_string/1)

  @spec milestone_types() :: [String.t()]
  def milestone_types, do: @milestone_types
end
