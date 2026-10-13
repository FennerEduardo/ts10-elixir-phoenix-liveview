defmodule TransactionalSystemElixirPhoenixWeb.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixHttpIntegrationTest do
  @moduledoc "HTTP contract of the application layer against PostgreSQL (needs DATABASE_URL)."
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias TransactionalSystemElixirPhoenix.JwtTenant

  @moduletag :integration
  @endpoint TransactionalSystemElixirPhoenixWeb.Endpoint
  @secret "integration-test-secret-with-32-chars!"

  setup do
    System.put_env("JWT_SECRET", @secret)
    Application.delete_env(:transactional_system_elixir_phoenix, :command_port)
    TransactionalSystemElixirPhoenix.Runtime.Schema.migrate(TransactionalSystemElixirPhoenix.DB)
    on_exit(fn -> System.delete_env("JWT_SECRET") end)
  end

  test "runs a command into the outbox for the token tenant, idempotently" do
    tenant = "tenant-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    id = "agg-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    path = "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/" <> id <> "/process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix"
    send_cmd = fn headers -> Enum.reduce(headers, put_req_header(build_conn(), "content-type", "application/json"), fn {k, v}, c -> put_req_header(c, k, v) end) |> post(path, "{}") end

    assert json_response(send_cmd.([{"x-tenant-id", tenant}]), 401)
    headers = [{"authorization", "Bearer " <> JwtTenant.sign(%{JwtTenant.tenant_claim() => tenant}, @secret)}, {"idempotency-key", id}, {"x-tenant-id", "someone-else"}]
    assert json_response(send_cmd.(headers), 202)
    assert json_response(send_cmd.(headers), 200)["status"] == "replayed"
    assert %{rows: [[^tenant]]} = Postgrex.query!(TransactionalSystemElixirPhoenix.DB, "SELECT tenant_id FROM ghk_outbox WHERE aggregate_id = $1", [id])
  end
end
