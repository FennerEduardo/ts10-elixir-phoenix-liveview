defmodule TransactionalSystemElixirPhoenix.Domain.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregateTest do
  use ExUnit.Case, async: true

  alias TransactionalSystemElixirPhoenix.Domain.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate

  test "starts in the initial state with no events" do
    assert {:ok, aggregate} = OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.new("agg-1")
    assert aggregate.state == "PENDING"
    assert aggregate.version == 0
    assert aggregate.pending_events == []
  end

  test "rejects an aggregate without id" do
    assert {:error, _} = OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.new("")
  end

  test "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix records PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql and bumps the version" do
    {:ok, aggregate} = OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.new("agg-1")
    assert {:ok, updated, event} = OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix(aggregate, %{id: "agg-1"})
    assert event.type == "PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql"
    assert event.version == 1
    assert updated.version == 1
    assert updated.pending_events == [event]
  end

  test "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix rejects a command without id" do
    {:ok, aggregate} = OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.new("agg-1")
    assert {:error, _} = OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix(aggregate, %{id: ""})
  end
end
