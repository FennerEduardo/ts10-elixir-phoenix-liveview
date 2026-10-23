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

# OpenTelemetry: with OTEL_EXPORTER_OTLP_ENDPOINT set, spans go over OTLP/HTTP to that collector (service.name from
# OTEL_SERVICE_NAME); without it nothing is exported and nothing connects.
if config_env() != :test and System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "") != "" do
  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    resource: [service: [name: System.get_env("OTEL_SERVICE_NAME", "transactional-system-elixir-phoenix")]]

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
else
  config :opentelemetry, traces_exporter: :none
end

# Tests export spans synchronously so the runtime integration test can assert trace propagation.
if config_env() == :test do
  config :opentelemetry, processors: [{:otel_simple_processor, %{}}]
end
