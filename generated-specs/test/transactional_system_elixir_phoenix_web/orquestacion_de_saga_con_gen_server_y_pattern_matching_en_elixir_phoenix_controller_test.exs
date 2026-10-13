defmodule TransactionalSystemElixirPhoenixWeb.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixControllerTest do
  # Not async: the command port and JWT_SECRET are global.
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  alias TransactionalSystemElixirPhoenix.JwtTenant

  @endpoint TransactionalSystemElixirPhoenixWeb.Endpoint
  @secret "unit-test-secret-with-at-least-32-chars"

  defmodule FakeCommands do
    def handle(%{command: "does_not_exist"}), do: raise(TransactionalSystemElixirPhoenix.Runtime.CommandService.DomainError, "Unknown command")

    def handle(request) do
      send(self(), {:handled, request})
      %{status: if(request.idempotency_key == "seen", do: "replayed", else: "created"), aggregate_id: request.aggregate_id, event_type: "PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql", version: 1}
    end
  end

  setup do
    previous = System.get_env("JWT_SECRET")
    System.put_env("JWT_SECRET", @secret)
    Application.put_env(:transactional_system_elixir_phoenix, :command_port, FakeCommands)

    on_exit(fn ->
      Application.delete_env(:transactional_system_elixir_phoenix, :command_port)
      if previous, do: System.put_env("JWT_SECRET", previous), else: System.delete_env("JWT_SECRET")
    end)
  end

  defp bearer(claims, secret \\ @secret), do: "Bearer " <> JwtTenant.sign(claims, secret)

  defp post_json(headers, path) do
    Enum.reduce(headers, put_req_header(build_conn(), "content-type", "application/json"), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> post(path, Jason.encode!(%{source: "api-test"}))
  end

  test "reports health" do
    assert json_response(get(build_conn(), "/health"), 200) == %{"status" => "ok"}
  end

  test "runs a command for the token tenant" do
    conn = post_json([{"authorization", bearer(%{JwtTenant.tenant_claim() => "acme"})}, {"x-tenant-id", "someone-else"}], "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/agg-api/process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix")
    assert json_response(conn, 202)["status"] == "created"
    assert_received {:handled, %{tenant_id: "acme", command: "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix", payload: %{"source" => "api-test"}}}
  end

  test "returns 200 for an idempotent replay" do
    conn = post_json([{"authorization", bearer(%{JwtTenant.tenant_claim() => "acme"})}, {"idempotency-key", "seen"}], "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/agg-api/process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix")
    assert json_response(conn, 200)
  end

  test "rejects missing or invalid tokens and X-Tenant-Id" do
    for headers <- [[], [{"x-tenant-id", "acme"}], [{"authorization", bearer(%{"sub" => "u1"})}], [{"authorization", bearer(%{JwtTenant.tenant_claim() => "acme"}, "wrong")}]] do
      assert json_response(post_json(headers, "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/agg-api/process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix"), 401)
    end
  end

  test "maps domain validation errors to 422" do
    conn = post_json([{"authorization", bearer(%{JwtTenant.tenant_claim() => "acme"})}], "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/agg-api/does_not_exist")
    assert json_response(conn, 422)
  end
end
