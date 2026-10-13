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

# The outbox relay runs in the application (DATABASE_URL + AMQP_URL); off in tests, where its publish
# spans would mix with the runtime tests' trace assertions.
config :transactional_system_elixir_phoenix, :outbox_relay, config_env() != :test

# OpenTelemetry: no exporter unless configured (e.g. opentelemetry_exporter with OTEL_EXPORTER_OTLP_ENDPOINT).
config :opentelemetry, traces_exporter: :none

# Tests export spans synchronously so the runtime integration test can assert trace propagation.
if config_env() == :test do
  config :opentelemetry, processors: [{:otel_simple_processor, %{}}]
end
