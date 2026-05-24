defmodule SymphonyElixir.RunnerSmokeTest do
  use ExUnit.Case, async: true

  @fixture_path Path.expand("../fixtures/runner_smoke/lab_59.txt", __DIR__)

  test "reads lab 59 runner smoke fixture" do
    assert File.read!(@fixture_path) == "LAB-59 native runner smoke test\n"
  end
end
