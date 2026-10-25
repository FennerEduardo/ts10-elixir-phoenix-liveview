defmodule TransactionalSystemElixirPhoenix.Runtime.Schema do
  @moduledoc "Runtime tables (docs/RUNTIME-KERNEL.md)."

  @statements [
    "DO $$ BEGIN PERFORM pg_advisory_xact_lock(hashtext('ghk_runtime_schema')); CREATE SCHEMA IF NOT EXISTS __SCHEMA__; CREATE TABLE IF NOT EXISTS __SCHEMA__.ghk_aggregates (tenant_id TEXT NOT NULL, aggregate_type TEXT NOT NULL, id TEXT NOT NULL, state TEXT NOT NULL, version INT NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, aggregate_type, id)); CREATE TABLE IF NOT EXISTS __SCHEMA__.ghk_outbox (id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, aggregate_id TEXT NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL, traceparent TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(), claimed_by TEXT, claimed_until TIMESTAMPTZ, published_at TIMESTAMPTZ, attempts INT NOT NULL DEFAULT 0, last_error TEXT, failed_at TIMESTAMPTZ); CREATE INDEX IF NOT EXISTS ghk_outbox_pending ON __SCHEMA__.ghk_outbox (created_at) WHERE published_at IS NULL AND failed_at IS NULL; CREATE TABLE IF NOT EXISTS __SCHEMA__.ghk_idempotency (tenant_id TEXT NOT NULL, key TEXT NOT NULL, status TEXT NOT NULL, response TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (tenant_id, key)); CREATE TABLE IF NOT EXISTS __SCHEMA__.ghk_inbox (consumer TEXT NOT NULL, message_id TEXT NOT NULL, processed_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (consumer, message_id)); CREATE TABLE IF NOT EXISTS __SCHEMA__.ghk_sagas (id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, status TEXT NOT NULL, completed_steps TEXT NOT NULL DEFAULT '', updated_at TIMESTAMPTZ NOT NULL DEFAULT now()); END $$"
  ]

  # Defense in depth (optional): enforce tenant isolation in PostgreSQL as well.
  # ALTER TABLE ghk_aggregates ENABLE ROW LEVEL SECURITY;
  # CREATE POLICY tenant_isolation ON ghk_aggregates USING (tenant_id = current_setting('app.tenant_id'));
  # and run SET LOCAL app.tenant_id = '<tenant>' at the start of each transaction.

  @doc "Validated schema identifier."
  def name(schema \\ "public") do
    if Regex.match?(~r/^[a-z_][a-z0-9_]*$/, schema), do: schema, else: raise(ArgumentError, "Invalid schema name: #{schema}")
  end

  @doc "Postgrex options from a libpq-style URL: postgres://user:password@host:5432/database[?sslmode=require]"
  def connection_opts(database_url) do
    uri = URI.parse(database_url)
    {user, password} =
      case String.split(uri.userinfo || "", ":", parts: 2) do
        [u, p] -> {URI.decode(u), URI.decode(p)}
        [u] -> {URI.decode(u), nil}
      end

    [hostname: uri.host, port: uri.port || 5432, database: String.trim_leading(uri.path || "", "/"), username: user, password: password] ++
      tls_opts(uri.host, URI.decode_query(uri.query || ""))
  end

  # libpq TLS parameters: sslmode=require encrypts without verifying (as in libpq); verify-ca checks the chain and
  # verify-full also the host name, against sslrootcert or the system CAs.
  defp tls_opts(host, %{"sslmode" => mode} = query) when mode in ["require", "verify-ca", "verify-full"] do
    cas = if query["sslrootcert"], do: [cacertfile: query["sslrootcert"]], else: [cacerts: :public_key.cacerts_get()]

    case mode do
      "require" -> [ssl: [verify: :verify_none]]
      "verify-ca" -> [ssl: [verify: :verify_peer, server_name_indication: :disable] ++ cas]
      "verify-full" -> [ssl: [verify: :verify_peer, server_name_indication: String.to_charlist(host), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]] ++ cas]
    end
  end

  defp tls_opts(_host, _query), do: []

  @doc "Creates the runtime tables (idempotent)."
  def migrate(conn, schema \\ "public") do
    s = name(schema)
    Enum.each(@statements, &Postgrex.query!(conn, String.replace(&1, "__SCHEMA__", s), []))
  end
end
