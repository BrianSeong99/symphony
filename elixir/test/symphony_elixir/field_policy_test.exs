defmodule SymphonyElixir.FieldPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FieldPolicy
  alias SymphonyElixir.Linear.OperatingModel

  test "loads field ownership for the core Linear/Symphony/GitHub fields" do
    policy = FieldPolicy.load!()

    assert FieldPolicy.field(policy, :title).owner == "linear"
    assert FieldPolicy.field(policy, :workpad).owner == "symphony"
    assert FieldPolicy.field(policy, :agent_memory).github == "blocked"
    assert FieldPolicy.field(policy, :pr_state).owner == "github"
    assert FieldPolicy.field(policy, :checks).owner == "github"
    assert FieldPolicy.field(policy, :run_metrics).owner == "symphony"
  end

  test "Linear-safe projection includes summaries but blocks private runtime memory" do
    preview =
      FieldPolicy.preview(:linear, :homelab, %{
        title: "Runtime console",
        workpad: "private detailed notes",
        agent_memory: "private chain of work",
        run_metrics: %{retry_count: 1},
        dependencies: ["SYM-1"]
      })

    assert preview.allowed == %{
             title: "Runtime console",
             workpad: "[summary available]",
             run_metrics: "[summary available]",
             dependencies: ["SYM-1"]
           }

    assert preview.rejected == %{agent_memory: :target_blocks_field}
  end

  test "Miden GitHub projection blocks private metadata and issue body rewrites" do
    preview =
      FieldPolicy.preview(:github, :miden, %{
        title: "Guardian launch",
        planning_notes: "private strategy",
        workpad: "private workpad",
        agent_memory: "private reviewer memory",
        private_comments: "private comment",
        run_metrics: %{runtime: 10},
        public_comments: "ready to post"
      })

    assert preview.allowed == %{}

    assert preview.rejected == %{
             title: :miden_public_issue_body_rewrites_disabled,
             planning_notes: :miden_blocks_private_github_projection,
             workpad: :miden_blocks_private_github_projection,
             agent_memory: :miden_blocks_private_github_projection,
             private_comments: :miden_blocks_private_github_projection,
             run_metrics: :miden_blocks_private_github_projection,
             public_comments: :explicit_approval_required
           }
  end

  test "Miden public comments can project only with explicit approval" do
    preview =
      FieldPolicy.preview(:github, :miden, %{public_comments: "public-safe update"}, approvals: [:public_comments])

    assert preview.allowed == %{public_comments: "public-safe update"}
    assert preview.rejected == %{}
  end

  test "Homelab owned profile allows GitHub full-sync fields when capabilities exist" do
    preview =
      FieldPolicy.preview(
        :github,
        :homelab,
        %{
          title: "Homelab runtime",
          dependencies: ["SYM-34"],
          validation: "mix test passed",
          public_comments: "Run passed"
        },
        approvals: [:public_comments],
        capabilities: %{"edit_issues" => true, "comment" => true}
      )

    assert preview.allowed == %{
             title: "Homelab runtime",
             dependencies: ["SYM-34"],
             validation: "mix test passed",
             public_comments: "Run passed"
           }
  end

  test "projection previews include exact missing approval and capability reasons" do
    preview =
      FieldPolicy.preview(:github, :homelab, %{public_comments: "Run passed"}, capabilities: %{"comment" => false})

    assert preview.rejected == %{public_comments: {:missing_capability, "comment"}}
  end

  test "unknown profile or field is rejected with exact reason" do
    assert FieldPolicy.preview(:github, :unknown, %{title: "x"}).rejected == %{title: :unknown_profile}
    assert FieldPolicy.preview(:github, :homelab, %{whatever: "x"}).rejected == %{whatever: :unknown_field}
  end

  test "policy profiles align with Linear operating domain config" do
    policy = FieldPolicy.load!()
    {:ok, operating_model} = OperatingModel.load_file("../config/symphony/linear-operating-model.yml")

    assert Enum.sort(FieldPolicy.operating_domain_profiles(policy)) ==
             Enum.sort([
               :homelab,
               :personal,
               :miden,
               :chainless,
               :wprc,
               :symphony
             ])

    profile_map =
      policy
      |> FieldPolicy.profiles_for_operating_domains(operating_model)
      |> Map.new(fn {domain, profiles} -> {domain, Enum.sort(profiles)} end)

    assert profile_map == %{
             "labs" => [:homelab, :symphony],
             "miden" => [:miden],
             "chainless" => [:chainless],
             "personal" => [:personal],
             "wprc" => [:wprc]
           }
  end
end
