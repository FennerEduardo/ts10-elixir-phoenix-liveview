defmodule TransactionalSystemElixirPhoenixWeb.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixLiveTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint TransactionalSystemElixirPhoenixWeb.Endpoint

  test "executes a command and lists the resulting event" do
    {:ok, view, _html} = live(build_conn(), "/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix")

    view |> form("#aggregate-form", %{aggregate_id: "agg-1"}) |> render_change()
    html = view |> element("#cmd-process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix") |> render_click()

    assert html =~ "PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql v1"
  end

  test "disables commands until an aggregate id is entered" do
    {:ok, view, _html} = live(build_conn(), "/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix")
    assert has_element?(view, "#cmd-process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix[disabled]")
  end
end
