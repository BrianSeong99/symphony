import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, ecto_repos: [SymphonyElixir.Repo]

config :symphony_elixir, SymphonyElixir.Repo,
  adapter: Ecto.Adapters.Postgres,
  username: System.get_env("SYMPHONY_DB_USER", "symphony"),
  password: System.get_env("SYMPHONY_DB_PASSWORD", "symphony"),
  hostname: System.get_env("SYMPHONY_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("SYMPHONY_DB_PORT", "5432")),
  database: System.get_env("SYMPHONY_DB_NAME", "symphony_#{config_env()}"),
  pool_size: String.to_integer(System.get_env("SYMPHONY_DB_POOL_SIZE", "10")),
  stacktrace: config_env() in [:dev, :test],
  show_sensitive_data_on_connection_error: config_env() in [:dev, :test]

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false
