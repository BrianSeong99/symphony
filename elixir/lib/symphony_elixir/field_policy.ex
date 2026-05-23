defmodule SymphonyElixir.FieldPolicy do
  @moduledoc """
  Field-level source-of-truth and projection policy for Linear/Symphony/GitHub.
  """

  @config_path Path.expand("../../../config/symphony/field-policy.yml", __DIR__)
  @targets ~w(linear symphony github)
  @miden_private_fields [:planning_notes, :workpad, :agent_memory, :private_comments, :run_metrics]
  @github_capabilities %{
    title: "edit_issues",
    dependencies: "edit_issues",
    validation: "edit_issues",
    public_comments: "comment"
  }

  @type policy :: map()
  @type preview :: %{
          required(:target) => atom(),
          required(:profile) => atom(),
          required(:allowed) => map(),
          required(:rejected) => map()
        }

  @spec load!() :: policy()
  def load! do
    @config_path
    |> YamlElixir.read_from_file!()
    |> atomize_policy()
  end

  @spec field(policy(), atom() | String.t()) :: map() | nil
  def field(policy, field_key) when is_map(policy) do
    get_in(policy, [:fields, normalize_key(field_key)])
  end

  @spec operating_domain_profiles(policy()) :: [atom()]
  def operating_domain_profiles(policy) when is_map(policy) do
    policy
    |> Map.get(:profiles, %{})
    |> Map.keys()
  end

  @spec profiles_for_operating_domains(policy(), map()) :: map()
  def profiles_for_operating_domains(policy, operating_model)
      when is_map(policy) and is_map(operating_model) do
    profile_pairs =
      policy
      |> Map.get(:profiles, %{})
      |> Enum.map(fn {profile_key, profile_config} ->
        operating_domain = Map.get(profile_config, :operating_domain, profile_key |> to_string() |> String.replace("_", "-"))
        {operating_domain, profile_key}
      end)

    operating_model
    |> Map.get("operating_domain_order", [])
    |> Map.new(fn domain_key ->
      profiles =
        profile_pairs
        |> Enum.filter(fn {operating_domain, _profile_key} -> operating_domain == domain_key end)
        |> Enum.map(&elem(&1, 1))

      {domain_key, profiles}
    end)
  end

  @spec preview(atom(), atom(), map()) :: preview()
  def preview(target, profile, values), do: preview(target, profile, values, [])

  @spec preview(atom(), atom(), map(), keyword()) :: preview()
  def preview(target, profile, values, opts)
      when is_atom(target) and is_atom(profile) and is_map(values) and is_list(opts) do
    policy = Keyword.get(opts, :policy, load!())
    approvals = opts |> Keyword.get(:approvals, []) |> MapSet.new(&normalize_key/1)
    capabilities = Keyword.get(opts, :capabilities, %{})

    {allowed, rejected} =
      Enum.reduce(values, {%{}, %{}}, fn {field_key, value}, {allowed, rejected} ->
        normalized_field = normalize_key(field_key)

        case projection_decision(policy, target, profile, normalized_field, capabilities, approvals) do
          {:allow, value_mapper} ->
            {Map.put(allowed, normalized_field, value_mapper.(value)), rejected}

          {:reject, reason} ->
            {allowed, Map.put(rejected, normalized_field, reason)}
        end
      end)

    %{target: target, profile: profile, allowed: allowed, rejected: rejected}
  end

  defp projection_decision(policy, target, profile, field_key, capabilities, approvals) do
    with {:ok, profile_config} <- fetch_profile(policy, profile),
         {:ok, field_config} <- fetch_field(policy, field_key),
         :ok <- capability_allows?(target, field_key, capabilities),
         :ok <- profile_allows?(profile, profile_config, target, field_key, approvals),
         :ok <- target_allowed?(field_config, target) do
      {:allow, value_mapper(field_config, target)}
    else
      {:reject, reason} -> {:reject, reason}
    end
  end

  defp fetch_profile(policy, profile) do
    case get_in(policy, [:profiles, profile]) do
      nil -> {:reject, :unknown_profile}
      profile_config -> {:ok, profile_config}
    end
  end

  defp fetch_field(policy, field_key) do
    case get_in(policy, [:fields, field_key]) do
      nil -> {:reject, :unknown_field}
      field_config -> {:ok, field_config}
    end
  end

  defp target_allowed?(field_config, target) do
    target_value = Map.get(field_config, target)

    cond do
      to_string(target) not in @targets ->
        {:reject, {:unknown_target, target}}

      target_value in [nil, "none", "blocked"] ->
        {:reject, :target_blocks_field}

      true ->
        :ok
    end
  end

  defp profile_allows?(:miden, _profile_config, :github, :title, _approvals) do
    {:reject, :miden_public_issue_body_rewrites_disabled}
  end

  defp profile_allows?(:miden, _profile_config, :github, field_key, _approvals)
       when field_key in @miden_private_fields do
    {:reject, :miden_blocks_private_github_projection}
  end

  defp profile_allows?(profile, profile_config, target, field_key, approvals) do
    approval_required = Map.get(profile_config, :approval_required, [])

    cond do
      target == :github and field_key in Enum.map(approval_required, &normalize_key/1) and
          not MapSet.member?(approvals, field_key) ->
        {:reject, :explicit_approval_required}

      profile == :miden and target == :github and field_key == :public_comments and
          not MapSet.member?(approvals, field_key) ->
        {:reject, :explicit_approval_required}

      true ->
        :ok
    end
  end

  defp capability_allows?(:github, field_key, capabilities) do
    case Map.fetch(@github_capabilities, field_key) do
      {:ok, capability} ->
        if capability_enabled?(capabilities, capability) do
          :ok
        else
          {:reject, {:missing_capability, capability}}
        end

      :error ->
        :ok
    end
  end

  defp capability_allows?(_target, _field_key, _capabilities), do: :ok

  defp capability_enabled?(capabilities, capability) do
    Map.get(capabilities, capability, true) == true
  end

  defp value_mapper(field_config, target) do
    case Map.get(field_config, target) do
      "summary_projection" -> fn _value -> "[summary available]" end
      _mode -> fn value -> value end
    end
  end

  defp atomize_policy(policy) do
    %{
      version: Map.fetch!(policy, "version"),
      default_profile: normalize_key(Map.fetch!(policy, "default_profile")),
      fields: atomize_nested_map(Map.fetch!(policy, "fields")),
      profiles: atomize_nested_map(Map.fetch!(policy, "profiles"))
    }
  end

  defp atomize_nested_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), atomize_value(value)} end)
  end

  defp atomize_value(value) when is_map(value), do: atomize_nested_map(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
end
