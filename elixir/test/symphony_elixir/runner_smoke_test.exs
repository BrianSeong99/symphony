defmodule SymphonyElixir.RunnerSmokeTest do
  use ExUnit.Case, async: true

  @fixture_path Path.expand("../fixtures/runner_smoke/lab_60.txt", __DIR__)

  test "reads lab 60 terminal evidence smoke fixture" do
    assert File.read!(@fixture_path) == "LAB-60 terminal evidence smoke test\n"
  end
end
