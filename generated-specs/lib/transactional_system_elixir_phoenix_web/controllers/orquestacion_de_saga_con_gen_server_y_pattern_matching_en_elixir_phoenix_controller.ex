defmodule TransactionalSystemElixirPhoenixWeb.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixController do
  use Phoenix.Controller, formats: [:json]

  alias TransactionalSystemElixirPhoenix.Domain.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate

  @commands %{
    "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix" => &OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix/2
  }

  def health(conn, _params), do: json(conn, %{status: "ok"})

  def execute(conn, %{"id" => id, "command" => command} = params) do
    payload = Map.drop(params, ["id", "command"])

    with {:ok, handler} <- Map.fetch(@commands, command),
         {:ok, aggregate} <- OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.new(id),
         {:ok, _aggregate, event} <- handler.(aggregate, %{id: id, payload: payload}) do
      conn |> put_status(:created) |> json(%{type: event.type, aggregateId: event.aggregate_id, version: event.version})
    else
      :error -> conn |> put_status(:not_found) |> json(%{detail: "Unknown command #{command}"})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{detail: reason})
    end
  end
end
