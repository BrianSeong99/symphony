defmodule SymphonyElixir.ProjectionTemplates do
  @moduledoc """
  Workspace-specific private/public projection templates.

  Templates define the payload surfaces that sit above the Linear adapter and
  relay: Linear cockpit views, GitHub issues, PR context, comment bodies, run
  summaries, checkpoint requests, and Symphony-private runtime state.
  """

  alias SymphonyElixir.FieldPolicy

  @config_path Path.expand("../../../config/symphony/projection-templates.yml", __DIR__)
  @required_templates [:homelab, :personal, :miden, :chainless, :wprc, :symphony]
  @required_surfaces [
    :linear,
    :github_issue,
    :github_pr,
    :linear_comment,
    :github_comment,
    :run_summary,
    :checkpoint_request,
    :symphony
  ]
  @targets [:linear, :symphony, :github]

  @type config :: map()
  @type surface_preview :: %{
          required(:surface) => atom(),
          required(:target) => atom() | nil,
          required(:visibility) => atom() | nil,
          required(:status) => :ready | :disabled,
          required(:allowed) => map(),
          required(:rejected) => map(),
          required(:redacted) => map(),
          required(:metadata) => map()
        }

  @spec load!() :: config()
  def load! do
    case load_file(@config_path) do
      {:ok, config} -> config
      {:error, errors} -> raise ArgumentError, "invalid projection templates: #{Enum.join(errors, "; ")}"
    end
  end

  @spec load_file(Path.t()) :: {:ok, config()} | {:error, [String.t()]}
  def load_file(path) do
    config =
      path
      |> YamlElixir.read_from_file!()
      |> atomize_config()

    case validate(config) do
      :ok -> {:ok, config}
      {:error, errors} -> {:error, errors}
    end
  end

  @spec validate(config()) :: :ok | {:error, [String.t()]}
  def validate(config) when is_map(config) do
    field_policy = FieldPolicy.load!()
    fields = field_policy |> Map.fetch!(:fields) |> Map.keys() |> MapSet.new()
    profiles = field_policy |> Map.fetch!(:profiles) |> Map.keys() |> MapSet.new()
    templates = Map.get(config, :templates, %{})

    errors =
      []
      |> require_keys(config, [:version, :default_template, :templates], "config")
      |> validate_required_templates(templates)
      |> validate_default_template(config, templates)
      |> validate_templates(templates, fields, profiles)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  @spec template(config(), atom() | String.t()) :: map() | nil
  def template(config, key) when is_map(config) do
    get_in(config, [:templates, normalize_key(key)])
  end

  @spec surface(config(), atom() | String.t(), atom() | String.t()) :: map() | nil
  def surface(config, template_key, surface_key) do
    get_in(config, [:templates, normalize_key(template_key), :surfaces, normalize_key(surface_key)])
  end

  @spec preview(atom() | String.t(), map()) :: map()
  def preview(template_key, values), do: preview(template_key, values, [])

  @spec preview(atom() | String.t(), map(), keyword()) :: map()
  def preview(template_key, values, opts)
      when is_map(values) and is_list(opts) do
    config = Keyword.get(opts, :config, load!())
    template_key = normalize_key(template_key)
    template = Map.fetch!(config.templates, template_key)
    mode_key = opts |> Keyword.get(:mode, template.default_mode) |> normalize_key()
    mode = Map.fetch!(template.modes, mode_key)
    disabled_surfaces = mode |> Map.get(:disabled_surfaces, []) |> MapSet.new(&normalize_key/1)

    surfaces =
      Map.new(template.surfaces, fn {surface_key, surface_config} ->
        {surface_key,
         preview_surface(
           surface_key,
           surface_config,
           template,
           values,
           mode_key,
           disabled_surfaces,
           opts
         )}
      end)

    %{
      template: template_key,
      profile: template.profile,
      operating_domain: template.operating_domain,
      mode: mode_key,
      sync_strategy: mode.sync_strategy,
      surfaces: surfaces
    }
  end

  @spec preview_surface(atom() | String.t(), atom() | String.t(), map()) :: surface_preview()
  def preview_surface(template_key, surface_key, values), do: preview_surface(template_key, surface_key, values, [])

  @spec preview_surface(atom() | String.t(), atom() | String.t(), map(), keyword()) :: surface_preview()
  def preview_surface(template_key, surface_key, values, opts)
      when is_map(values) and is_list(opts) do
    config = Keyword.get(opts, :config, load!())
    template_key = normalize_key(template_key)
    surface_key = normalize_key(surface_key)
    template = Map.fetch!(config.templates, template_key)
    mode_key = opts |> Keyword.get(:mode, template.default_mode) |> normalize_key()
    mode = Map.fetch!(template.modes, mode_key)
    disabled_surfaces = mode |> Map.get(:disabled_surfaces, []) |> MapSet.new(&normalize_key/1)
    surface_config = Map.fetch!(template.surfaces, surface_key)

    preview_surface(surface_key, surface_config, template, values, mode_key, disabled_surfaces, opts)
  end

  defp preview_surface(surface_key, surface_config, template, values, mode_key, disabled_surfaces, opts) do
    metadata = surface_metadata(surface_config)
    target = normalize_key(surface_config.target)
    visibility = normalize_key(surface_config.visibility)

    if MapSet.member?(disabled_surfaces, surface_key) do
      %{
        surface: surface_key,
        target: target,
        visibility: visibility,
        surface_mode: normalize_key(surface_config.mode),
        status: :disabled,
        reason: {:mode_disables_surface, mode_key},
        allowed: %{},
        rejected: %{},
        redacted: %{},
        metadata: metadata
      }
    else
      config = Keyword.get(opts, :config, load!())
      field_policy = Keyword.get(opts, :field_policy, FieldPolicy.load!())
      values_for_surface = select_surface_values(values, surface_config.fields)

      {redacted_values, redactions} =
        redact_values(values_for_surface, visibility, Map.get(config, :redaction_rules, %{}))

      field_preview =
        FieldPolicy.preview(target, template.profile, redacted_values,
          policy: field_policy,
          approvals: Keyword.get(opts, :approvals, []),
          capabilities: Keyword.get(opts, :capabilities, %{})
        )

      %{
        surface: surface_key,
        target: target,
        visibility: visibility,
        surface_mode: normalize_key(surface_config.mode),
        status: :ready,
        allowed: field_preview.allowed,
        rejected: field_preview.rejected,
        redacted: redactions,
        metadata: metadata
      }
    end
  end

  defp select_surface_values(values, fields) do
    normalized_values = Map.new(values, fn {key, value} -> {normalize_key(key), value} end)

    fields
    |> Enum.map(&normalize_key/1)
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.fetch(normalized_values, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp redact_values(values, visibility, rules) do
    if public_visibility?(visibility) do
      redact_public_values(values, rules)
    else
      {values, %{}}
    end
  end

  defp redact_public_values(values, rules) do
    Enum.reduce(values, {%{}, %{}}, fn field_value, acc ->
      apply_redaction_decision(field_value, acc, rules)
    end)
  end

  defp apply_redaction_decision({field, value}, {projected, redactions}, rules) do
    case redaction_decision(field, value, rules) do
      {:drop, reason} ->
        {projected, Map.put(redactions, field, %{action: :drop, reason: reason})}

      {:replace, replacement, reason} ->
        {Map.put(projected, field, replacement), Map.put(redactions, field, %{action: :replace, reason: reason})}

      :keep ->
        {Map.put(projected, field, value), redactions}
    end
  end

  defp redaction_decision(field, value, rules) do
    rules
    |> Enum.find_value(:keep, fn {_rule_key, rule} ->
      redaction_for_rule(field, value, rule)
    end)
  end

  defp redaction_for_rule(field, value, rule) do
    rule_fields = Enum.map(Map.get(rule, :fields, []), &normalize_key/1)

    cond do
      field not in rule_fields -> nil
      not rule_applies?(rule, value) -> nil
      true -> redaction_action(rule)
    end
  end

  defp redaction_action(rule) do
    case normalize_key(rule.public_action) do
      :drop -> {:drop, normalize_key(rule.reason)}
      :replace -> {:replace, Map.fetch!(rule, :replacement), normalize_key(rule.reason)}
      _other -> nil
    end
  end

  defp rule_applies?(rule, value) do
    case Map.get(rule, :markers, []) do
      [] -> true
      markers -> Enum.any?(markers, &value_contains_marker?(value, &1))
    end
  end

  defp value_contains_marker?(value, marker) when is_binary(value), do: String.contains?(value, marker)

  defp value_contains_marker?(value, marker) when is_list(value) do
    Enum.any?(value, &value_contains_marker?(&1, marker))
  end

  defp value_contains_marker?(value, marker) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&value_contains_marker?(&1, marker))
  end

  defp value_contains_marker?(_value, _marker), do: false

  defp public_visibility?(visibility), do: normalize_key(visibility) == :public

  defp surface_metadata(surface_config) do
    surface_config
    |> Map.drop([:target, :visibility, :mode, :fields])
    |> Map.new(fn {key, value} -> {key, value} end)
  end

  defp validate_templates(errors, templates, fields, profiles) do
    Enum.reduce(templates, errors, fn {template_key, template}, acc ->
      acc
      |> require_keys(template, [:profile, :operating_domain, :default_mode, :modes, :surfaces], "templates.#{template_key}")
      |> validate_template_profile(template_key, template, profiles)
      |> validate_template_default_mode(template_key, template)
      |> validate_template_surfaces(template_key, template, fields)
    end)
  end

  defp validate_required_templates(errors, templates) do
    missing = @required_templates -- Map.keys(templates)

    Enum.reduce(missing, errors, fn template, acc ->
      ["templates.#{template} is required" | acc]
    end)
  end

  defp validate_default_template(errors, config, templates) do
    default_template = Map.get(config, :default_template)

    if default_template && not Map.has_key?(templates, default_template) do
      ["default_template references unknown template #{default_template}" | errors]
    else
      errors
    end
  end

  defp validate_template_profile(errors, template_key, template, profiles) do
    if Map.get(template, :profile) in profiles do
      errors
    else
      ["templates.#{template_key}.profile references unknown field policy profile #{inspect(Map.get(template, :profile))}" | errors]
    end
  end

  defp validate_template_default_mode(errors, template_key, template) do
    default_mode = Map.get(template, :default_mode)

    if is_map(Map.get(template, :modes)) && Map.has_key?(template.modes, default_mode) do
      errors
    else
      ["templates.#{template_key}.default_mode references unknown mode #{inspect(default_mode)}" | errors]
    end
  end

  defp validate_template_surfaces(errors, template_key, template, fields) do
    surfaces = Map.get(template, :surfaces, %{})

    errors =
      Enum.reduce(@required_surfaces -- Map.keys(surfaces), errors, fn surface, acc ->
        ["templates.#{template_key}.surfaces.#{surface} is required" | acc]
      end)

    errors =
      Enum.reduce(surfaces, errors, fn {surface_key, surface}, acc ->
        acc
        |> require_keys(surface, [:target, :visibility, :mode, :fields], "templates.#{template_key}.surfaces.#{surface_key}")
        |> validate_surface_target(template_key, surface_key, surface)
        |> validate_surface_fields(template_key, surface_key, surface, fields)
      end)

    validate_disabled_surfaces(errors, template_key, template)
  end

  defp validate_surface_target(errors, template_key, surface_key, surface) do
    target = Map.get(surface, :target)

    if target in @targets do
      errors
    else
      ["templates.#{template_key}.surfaces.#{surface_key}.target is invalid: #{inspect(target)}" | errors]
    end
  end

  defp validate_surface_fields(errors, template_key, surface_key, surface, fields) do
    surface_fields = surface |> Map.get(:fields, []) |> Enum.map(&normalize_key/1)
    unknown_fields = Enum.reject(surface_fields, &MapSet.member?(fields, &1))

    Enum.reduce(unknown_fields, errors, fn field, acc ->
      ["templates.#{template_key}.surfaces.#{surface_key}.fields includes unknown field #{field}" | acc]
    end)
  end

  defp validate_disabled_surfaces(errors, template_key, template) do
    surface_keys = template |> Map.get(:surfaces, %{}) |> Map.keys() |> MapSet.new()

    template
    |> Map.get(:modes, %{})
    |> Enum.reduce(errors, fn {mode_key, mode}, acc ->
      mode
      |> Map.get(:disabled_surfaces, [])
      |> Enum.map(&normalize_key/1)
      |> Enum.reject(&MapSet.member?(surface_keys, &1))
      |> Enum.reduce(acc, fn surface, mode_acc ->
        ["templates.#{template_key}.modes.#{mode_key}.disabled_surfaces references unknown surface #{surface}" | mode_acc]
      end)
    end)
  end

  defp require_keys(errors, map, keys, path) do
    Enum.reduce(keys, errors, fn key, acc ->
      if Map.has_key?(map, key), do: acc, else: ["#{path}.#{key} is required" | acc]
    end)
  end

  defp atomize_config(config) do
    %{
      version: Map.fetch!(config, "version"),
      default_template: normalize_key(Map.fetch!(config, "default_template")),
      redaction_rules: config |> Map.get("redaction_rules", %{}) |> atomize_nested_map() |> normalize_redaction_rules(),
      templates: config |> Map.fetch!("templates") |> atomize_nested_map() |> normalize_templates()
    }
  end

  defp normalize_templates(templates) do
    Map.new(templates, fn {template_key, template} ->
      normalized_template =
        template
        |> update_existing(:profile, &normalize_key/1)
        |> update_existing(:default_mode, &normalize_key/1)
        |> update_existing(:modes, &normalize_modes/1)
        |> update_existing(:surfaces, &normalize_surfaces/1)

      {template_key, normalized_template}
    end)
  end

  defp normalize_modes(modes) do
    Map.new(modes, fn {mode_key, mode} ->
      {mode_key, update_existing(mode, :disabled_surfaces, &Enum.map(&1, fn surface -> normalize_key(surface) end))}
    end)
  end

  defp normalize_surfaces(surfaces) do
    Map.new(surfaces, fn {surface_key, surface} ->
      normalized_surface =
        surface
        |> update_existing(:target, &normalize_key/1)
        |> update_existing(:visibility, &normalize_key/1)
        |> update_existing(:mode, &normalize_key/1)
        |> update_existing(:fields, &Enum.map(&1, fn field -> normalize_key(field) end))

      {surface_key, normalized_surface}
    end)
  end

  defp normalize_redaction_rules(rules) do
    Map.new(rules, fn {rule_key, rule} ->
      normalized_rule =
        rule
        |> update_existing(:fields, &Enum.map(&1, fn field -> normalize_key(field) end))
        |> update_existing(:public_action, &normalize_key/1)
        |> update_existing(:reason, &normalize_key/1)

      {rule_key, normalized_rule}
    end)
  end

  defp update_existing(map, key, fun) do
    if Map.has_key?(map, key), do: Map.update!(map, key, fun), else: map
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
