import Config

config :transactional_system_elixir_phoenix, TransactionalSystemElixirPhoenixWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))],
  server: config_env() != :test,
  secret_key_base: System.get_env("SECRET_KEY_BASE", String.duplicate("dev-secret-change-me-", 4)),
  render_errors: [formats: [json: TransactionalSystemElixirPhoenixWeb.ErrorJSON], layout: false],
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT", "lv-salt-change-me")]

config :phoenix, :json_library, Jason
config :logger, level: if(config_env() == :test, do: :warning, else: :info)
