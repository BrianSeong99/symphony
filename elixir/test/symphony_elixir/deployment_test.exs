defmodule SymphonyElixir.DeploymentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Health}

  @root Path.expand("../../..", __DIR__)

  defmodule HealthyRepo do
    def query("SELECT 1", [], _opts), do: {:ok, %{rows: [[1]]}}
  end

  defmodule UnhealthyRepo do
    def query("SELECT 1", [], _opts), do: {:error, :database_down}
  end

  test "health check requires app and database checks to pass when repo is enabled" do
    healthy = Health.check(repo: HealthyRepo)
    unhealthy = Health.check(repo: UnhealthyRepo)

    assert healthy.status == "ok"
    assert healthy.checks.database.status == "ok"
    assert Health.healthy?(healthy)

    assert unhealthy.status == "error"
    assert unhealthy.checks.database.status == "error"
    refute Health.healthy?(unhealthy)
  end

  test "health check skips database for native repo-disabled runner" do
    old_repo_enabled = System.get_env("SYMPHONY_REPO_ENABLED")
    System.put_env("SYMPHONY_REPO_ENABLED", "false")

    on_exit(fn -> restore_env("SYMPHONY_REPO_ENABLED", old_repo_enabled) end)

    health = Health.check(repo: UnhealthyRepo)
    assert health.status == "ok"
    assert health.checks.database == %{status: "skipped", reason: "repo_disabled"}
    assert Health.healthy?(health)
  end

  test "server host and port can be configured through container environment" do
    old_host = System.get_env("SYMPHONY_SERVER_HOST")
    old_port = System.get_env("SYMPHONY_SERVER_PORT")

    System.put_env("SYMPHONY_SERVER_HOST", "0.0.0.0")
    System.put_env("SYMPHONY_SERVER_PORT", "4000")

    on_exit(fn ->
      restore_env("SYMPHONY_SERVER_HOST", old_host)
      restore_env("SYMPHONY_SERVER_PORT", old_port)
    end)

    assert Config.server_host() == "0.0.0.0"
    assert Config.server_port() == 4000
  end

  test "compose file is homelab-ready and avoids host port bindings" do
    compose = @root |> Path.join("compose.yaml") |> YamlElixir.read_from_file!()

    assert compose["name"] == "symphony"
    assert compose["services"]["db"]["ports"] in [nil, []]
    assert compose["services"]["web"]["ports"] in [nil, []]
    assert compose["services"]["web"]["environment"]["SYMPHONY_RUNNER_ENABLED"] == "false"
    assert "homelab" in compose["services"]["web"]["networks"]
    assert compose["networks"]["homelab"] == %{"external" => true, "name" => "homelab"}
    assert compose["services"]["web"]["healthcheck"]["test"] == ["CMD-SHELL", "curl -fsS http://127.0.0.1:4000/healthz >/dev/null"]
  end

  test "homelab registration metadata points at the native Mac runner" do
    metadata = @root |> Path.join("config/homelab/symphony.yml") |> YamlElixir.read_from_file!()
    launchd_plist = File.read!(Path.join(@root, "ops/launchd/ai.symphony.runner.plist"))

    assert metadata["name"] == "symphony"
    assert metadata["kind"] == "prod"
    assert metadata["upstream"] == "host.docker.internal:4000"
    assert metadata["upstream_kind"] == "host"
    assert metadata["health_path"] == "/healthz"
    assert File.exists?(Path.join(@root, "bin/homelab-smoke.sh"))
    assert File.exists?(Path.join(@root, "bin/symphony-native"))
    assert File.exists?(Path.join(@root, "ops/launchd/ai.symphony.runner.plist"))
    assert launchd_plist =~ "/tmp/ai.symphony.runner.out.log"
    assert launchd_plist =~ "/tmp/ai.symphony.runner.err.log"
    refute launchd_plist =~ "/log/launchd."
  end
end
