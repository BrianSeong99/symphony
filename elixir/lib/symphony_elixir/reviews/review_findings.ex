defmodule SymphonyElixir.Reviews.ReviewFindings do
  @moduledoc """
  Review finding state transition helpers.
  """

  alias SymphonyElixir.Reviews.ReviewFinding

  @spec transition(ReviewFinding.t(), String.t(), keyword() | map()) ::
          {:ok, ReviewFinding.t()} | {:error, Ecto.Changeset.t()}
  def transition(%ReviewFinding{} = finding, next_state, attrs \\ []) when is_binary(next_state) do
    metadata =
      finding.metadata
      |> Map.merge(attrs |> Map.new() |> stringify_keys())

    changeset =
      ReviewFinding.changeset(finding, %{
        state: next_state,
        metadata: metadata
      })

    Ecto.Changeset.apply_action(changeset, :update)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
