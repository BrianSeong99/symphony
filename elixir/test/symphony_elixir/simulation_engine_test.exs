defmodule SymphonyElixir.SimulationEngineTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Simulation.Engine

  @snapshot_path Path.expand("../fixtures/simulation/all_scenarios.json", __DIR__)

  test "runs deterministic golden simulations for every configured orchestration scenario" do
    actual =
      Engine.run_all()
      |> Map.fetch!(:scenarios)
      |> Map.new(fn scenario ->
        {scenario |> Map.fetch!(:scenario) |> Atom.to_string(), Engine.golden(scenario)}
      end)

    assert actual == read_snapshot!()
  end

  test "Miden simulation keeps private planning metadata off every GitHub surface" do
    result = Engine.run!(:miden_private_linear_relay)

    assert result.github.private_leak_fields == []
    assert result.github.projection.github_issue_allowed == []
    assert result.github.projection.github_issue_rejected == ["public_comments"]
    assert "planning_notes" in result.linear.allowed_private_fields
    assert "agent_memory" in result.symphony.allowed_private_fields
  end

  test "scheduler simulation dispatches independent ready issues while blocked issues wait" do
    result = Engine.run!(:scheduler_parallel_dag)

    assert result.scheduler.dispatch == [202, 203]
    assert result.scheduler.blocked == [204]
    assert result.scheduler.waiting == [205]

    assert result.scheduler.blocked_by == %{
             "204" => [
               %{
                 dependency_issue_id: 202,
                 dependency_status: "ready",
                 dependency_title: "Build projection templates",
                 unblock_condition: "projection templates merged"
               }
             ]
           }
  end

  test "loop breaker simulation produces human checkpoints with evidence" do
    result = Engine.run!(:loop_breaker_human_checkpoint)

    assert result.status == "checkpoint_required"

    assert Enum.map(result.checkpoints, & &1.trigger) == [
             "repeated_failure_signature",
             "validation_spec_contradiction"
           ]

    assert Enum.all?(result.checkpoints, &(&1.evidence_count > 0))
  end

  defp read_snapshot! do
    @snapshot_path
    |> File.read!()
    |> Jason.decode!()
  end
end
