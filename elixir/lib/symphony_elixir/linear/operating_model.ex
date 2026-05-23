defmodule SymphonyElixir.Linear.OperatingModel do
  @moduledoc """
  Parser and validator for the Linear operating-domain and outcome-project model.
  """

  @required_domain_keys ["homelab-personal", "miden", "chainless", "wprc", "symphony"]
  @sync_profiles ["native-full-sync", "relay-full-sync", "relay-pr-only", "relay-context-only", "no-github"]

  @type model :: map()
  @type validation_result :: :ok | {:error, [String.t()]}

  @spec load_file(Path.t()) :: {:ok, model()} | {:error, [String.t()]}
  def load_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- YamlElixir.read_from_string(contents) do
      model = normalize(decoded)

      case validate(model) do
        :ok -> {:ok, model}
        {:error, errors} -> {:error, errors}
      end
    else
      {:error, %File.Error{} = error} -> {:error, [Exception.message(error)]}
      {:error, error} when is_binary(error) -> {:error, [error]}
      {:error, error} -> {:error, [inspect(error)]}
    end
  end

  @spec validate(model()) :: validation_result()
  def validate(model) when is_map(model) do
    errors =
      []
      |> validate_version(model)
      |> validate_sync_profiles(model)
      |> validate_project_policy(model)
      |> validate_domains(model)
      |> validate_projects(model)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @spec operating_domain_keys(model()) :: [String.t()]
  def operating_domain_keys(model), do: Map.get(model, "operating_domain_order", [])

  @spec outcome_project_keys(model()) :: [String.t()]
  def outcome_project_keys(model), do: Map.get(model, "outcome_project_order", [])

  @spec sync_profiles(model()) :: [String.t()]
  def sync_profiles(model), do: Map.get(model, "sync_profiles", [])

  @spec default_project_unit(model()) :: String.t() | nil
  def default_project_unit(model), do: get_in(model, ["project_policy", "default_project_unit"])

  @spec repo_as_default_project_unit?(model()) :: boolean()
  def repo_as_default_project_unit?(model), do: default_project_unit(model) == "repo"

  @spec outcome_project!(model(), String.t()) :: map()
  def outcome_project!(model, key), do: get_in(model, ["outcome_projects", key]) || raise(KeyError, key: key)

  @spec checkpoint_cadence(model(), String.t()) :: String.t() | nil
  def checkpoint_cadence(model, project_key) do
    get_in(model, ["checkpoint_cadence", "project_overrides", project_key]) ||
      get_in(model, ["checkpoint_cadence", "default"])
  end

  @spec validate_project_sync_profile(model(), String.t(), String.t()) :: validation_result()
  def validate_project_sync_profile(model, project_key, sync_profile) do
    project = outcome_project!(model, project_key)
    operating_domain = Map.fetch!(project, "operating_domain")
    validate_sync_profile_for_domain(model, project_key, operating_domain, sync_profile)
  end

  defp normalize(model) when is_map(model) do
    model
    |> normalize_collection("operating_domains", "operating_domain_order")
    |> normalize_collection("outcome_projects", "outcome_project_order")
  end

  defp normalize(model), do: model

  defp normalize_collection(model, collection_key, order_key) do
    case Map.get(model, collection_key) do
      values when is_list(values) ->
        keyed =
          values
          |> Enum.filter(&is_map/1)
          |> Map.new(fn item -> {Map.get(item, "key"), Map.delete(item, "key")} end)

        order =
          values
          |> Enum.filter(&is_map/1)
          |> Enum.map(&Map.get(&1, "key"))
          |> Enum.reject(&is_nil/1)

        model
        |> Map.put(collection_key, keyed)
        |> Map.put(order_key, order)

      _other ->
        model
    end
  end

  defp validate_version(errors, %{"version" => 1}), do: errors
  defp validate_version(errors, _model), do: ["version must be 1" | errors]

  defp validate_sync_profiles(errors, model) do
    if Map.get(model, "sync_profiles") == @sync_profiles do
      errors
    else
      ["sync_profiles must match supported Linear sync profiles" | errors]
    end
  end

  defp validate_project_policy(errors, model) do
    if default_project_unit(model) == "outcome" do
      errors
    else
      ["project_policy.default_project_unit must be outcome" | errors]
    end
  end

  defp validate_domains(errors, model) do
    domain_keys = operating_domain_keys(model)

    errors =
      if domain_keys == @required_domain_keys do
        errors
      else
        ["operating_domains must include Brian's required domains in canonical order" | errors]
      end

    model
    |> Map.get("operating_domains", %{})
    |> Enum.reduce(errors, fn {domain_key, domain}, acc ->
      validate_domain(domain_key, domain, acc)
    end)
  end

  defp validate_domain(domain_key, domain, errors) do
    allowed_profiles = Map.get(domain, "allowed_sync_profiles", [])
    unknown_profiles = allowed_profiles -- @sync_profiles

    errors =
      if unknown_profiles == [] do
        errors
      else
        ["operating_domains.#{domain_key}.allowed_sync_profiles includes unsupported profiles" | errors]
      end

    if domain_key == "homelab-personal" and native_allowed?(domain) do
      errors
    else
      if domain_key == "homelab-personal" do
        ["operating_domains.homelab-personal.github_issue_sync.native_allowed must be true" | errors]
      else
        errors
      end
    end
  end

  defp validate_projects(errors, model) do
    model
    |> Map.get("outcome_projects", %{})
    |> Enum.reduce(errors, fn {project_key, project}, acc ->
      acc
      |> validate_project_domain(model, project_key, project)
      |> validate_project_sync_profile(model, project_key, project)
      |> validate_project_repo_metadata(project_key, project)
    end)
  end

  defp validate_project_domain(errors, model, project_key, project) do
    operating_domain = Map.get(project, "operating_domain")

    if Map.has_key?(Map.get(model, "operating_domains", %{}), operating_domain) do
      errors
    else
      [
        "outcome_projects.#{project_key}.operating_domain references unknown domain #{operating_domain}"
        | errors
      ]
    end
  end

  defp validate_project_sync_profile(errors, model, project_key, project) do
    sync_profile = Map.get(project, "sync_profile")
    operating_domain = Map.get(project, "operating_domain")

    case validate_sync_profile_for_domain(model, project_key, operating_domain, sync_profile) do
      :ok -> errors
      {:error, sync_errors} -> sync_errors ++ errors
    end
  end

  defp validate_sync_profile_for_domain(model, project_key, operating_domain, sync_profile) do
    domain = get_in(model, ["operating_domains", operating_domain])
    allowed_profiles = if is_map(domain), do: Map.get(domain, "allowed_sync_profiles", []), else: []

    cond do
      sync_profile not in @sync_profiles ->
        {:error, ["outcome_projects.#{project_key}.sync_profile is unsupported"]}

      operating_domain == "miden" and native_github_issue_sync?(sync_profile) ->
        {:error, ["outcome_projects.#{project_key}.sync_profile cannot use native GitHub issue sync for Miden"]}

      sync_profile not in allowed_profiles ->
        {:error, ["outcome_projects.#{project_key}.sync_profile is not allowed for #{operating_domain}"]}

      true ->
        :ok
    end
  end

  defp validate_project_repo_metadata(errors, project_key, project) do
    representation = get_in(project, ["repo_metadata", "representation"])

    if representation in ["metadata", "label", "custom_field"] do
      errors
    else
      ["outcome_projects.#{project_key}.repo_metadata.representation must not make repos the project unit" | errors]
    end
  end

  defp native_allowed?(domain), do: get_in(domain, ["github_issue_sync", "native_allowed"]) == true

  defp native_github_issue_sync?("native-full-sync"), do: true
  defp native_github_issue_sync?(_sync_profile), do: false
end
