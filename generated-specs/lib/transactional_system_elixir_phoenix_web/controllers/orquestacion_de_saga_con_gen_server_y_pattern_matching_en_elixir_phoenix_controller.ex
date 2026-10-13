defmodule TransactionalSystemElixirPhoenixWeb.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixController do
  @moduledoc "POST /api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/:id/:command (process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix)."
  # ghk:implements OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenix
  use Phoenix.Controller, formats: [:json]

  alias TransactionalSystemElixirPhoenix.Runtime.CommandService.DomainError

  @status %{"created" => :accepted, "replayed" => :ok, "in-progress" => :conflict}

  def health(conn, _params), do: json(conn, %{status: "ok"})

  def execute(conn, %{"id" => id, "command" => command} = params) do
    case TransactionalSystemElixirPhoenix.JwtTenant.tenant_from(conn |> Plug.Conn.get_req_header("authorization") |> List.first()) do
      nil ->
        conn |> put_status(:unauthorized) |> json(%{detail: "A valid bearer token with a tenant is required"})

      tenant ->
        request = %{
          tenant_id: tenant,
          aggregate_type: "OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenix",
          aggregate_id: id,
          command: command,
          payload: Map.drop(params, ["id", "command"]),
          idempotency_key: conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first(),
          traceparent: conn |> Plug.Conn.get_req_header("traceparent") |> List.first()
        }

        try do
          result = TransactionalSystemElixirPhoenix.Commands.handle(request)
          conn |> put_status(Map.get(@status, result.status, :ok)) |> json(result)
        rescue
          e in DomainError -> conn |> put_status(:unprocessable_entity) |> json(%{detail: e.message})
        end
    end
  end
end
