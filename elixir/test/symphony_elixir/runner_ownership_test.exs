defmodule SymphonyElixir.RunnerOwnershipTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RunnerOwnership

  test "acquires one leader and blocks duplicate owners until release" do
    lock_path = temp_lock_path("single-owner")

    assert {:ok, leader} = RunnerOwnership.acquire(lock_path: lock_path)
    assert leader.leader? == true
    assert leader.mode == "leader"
    assert File.dir?(lock_path)

    assert {:error, {:already_owned, owner, ^lock_path}} = RunnerOwnership.acquire(lock_path: lock_path)
    assert is_binary(owner["owner_id"])

    assert :ok = RunnerOwnership.release(leader)
    refute File.exists?(lock_path)

    assert {:ok, next_leader} = RunnerOwnership.acquire(lock_path: lock_path)
    assert next_leader.leader? == true
    RunnerOwnership.release(next_leader)
  end

  test "reclaims stale lock owned by a dead process" do
    lock_path = temp_lock_path("stale-owner")
    File.mkdir_p!(lock_path)

    stale_owner =
      lock_path
      |> RunnerOwnership.owner()
      |> Map.put(:os_pid, "999999999")

    File.write!(Path.join(lock_path, "owner.json"), Jason.encode!(stale_owner))

    assert {:ok, leader} = RunnerOwnership.acquire(lock_path: lock_path)
    assert leader.leader? == true
    refute leader.owner_id == stale_owner.owner_id

    RunnerOwnership.release(leader)
  end

  test "orchestrator followers expose ownership state and do not accept refresh work" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      poll_interval_ms: 5_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    lock_path = temp_lock_path("orchestrator")
    leader_name = Module.concat(__MODULE__, :LeaderOrchestrator)
    follower_name = Module.concat(__MODULE__, :FollowerOrchestrator)

    {:ok, leader_pid} =
      Orchestrator.start_link(
        name: leader_name,
        runner_ownership: true,
        runner_lock_path: lock_path
      )

    {:ok, follower_pid} =
      Orchestrator.start_link(
        name: follower_name,
        runner_ownership: true,
        runner_lock_path: lock_path
      )

    on_exit(fn ->
      if Process.alive?(follower_pid), do: Process.exit(follower_pid, :normal)
      if Process.alive?(leader_pid), do: Process.exit(leader_pid, :normal)
      File.rm_rf(lock_path)
    end)

    assert %{runner: %{leader?: true, mode: "leader"}} = Orchestrator.snapshot(leader_name, 1_000)

    assert %{
             runner: %{leader?: false, mode: "follower", lock_path: ^lock_path},
             polling: %{next_poll_in_ms: nil}
           } = Orchestrator.snapshot(follower_name, 1_000)

    assert %{
             queued: false,
             operations: ["runner_ownership"],
             reason: "runner is not leader"
           } = Orchestrator.request_refresh(follower_name)
  end

  test "application starts PubSub before the orchestrator" do
    previous_runner_enabled = System.get_env("SYMPHONY_RUNNER_ENABLED")

    on_exit(fn ->
      restore_env("SYMPHONY_RUNNER_ENABLED", previous_runner_enabled)
    end)

    System.put_env("SYMPHONY_RUNNER_ENABLED", "true")

    children = SymphonyElixir.Application.children_for_test()
    pubsub_index = Enum.find_index(children, &match?({Phoenix.PubSub, _}, &1))
    orchestrator_index = Enum.find_index(children, &(&1 == SymphonyElixir.Orchestrator))

    assert is_integer(pubsub_index)
    assert is_integer(orchestrator_index)
    assert pubsub_index < orchestrator_index
  end

  defp temp_lock_path(name) do
    Path.join(System.tmp_dir!(), "symphony-runner-ownership-#{name}-#{System.unique_integer([:positive])}")
  end
end
