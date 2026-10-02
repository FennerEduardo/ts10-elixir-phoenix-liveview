defmodule TransactionalSystemElixirPhoenixWeb.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixControllerTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint TransactionalSystemElixirPhoenixWeb.Endpoint

  test "reports health" do
    conn = get(build_conn(), "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "executes a domain command and returns the event" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/agg-api/process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix", Jason.encode!(%{source: "api-test"}))

    assert json_response(conn, 201) == %{"type" => "PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql", "aggregateId" => "agg-api", "version" => 1}
  end

  test "returns 404 for unknown commands" do
    conn = post(build_conn(), "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/agg-api/does_not_exist")
    assert json_response(conn, 404)
  end
end
