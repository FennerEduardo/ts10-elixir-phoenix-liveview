defmodule TransactionalSystemElixirPhoenix.Runtime.CommandService do
  @moduledoc """
  Executes a command in one transaction: idempotency claim, aggregate load (FOR UPDATE), domain
  logic, aggregate save and outbox insert. A domain error rolls back everything.
  """
  alias TransactionalSystemElixirPhoenix.Runtime.{Schema, Telemetry}

  @default_aggregate "OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenix"
  # Every aggregate of the service: aggregate module and command functions.
  @aggregates %{
    "OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenix" => {TransactionalSystemElixirPhoenix.Domain.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate, %{
      "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix" => &TransactionalSystemElixirPhoenix.Domain.OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixAggregate.process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix/2
    }}
  }

  def default_aggregate, do: @default_aggregate

  defmodule DomainError do
    defexception [:message]
  end

  @doc """
  request: %{tenant_id, aggregate_id, command, payload, idempotency_key, traceparent}.
  Returns %{status: "created" | "replayed" | "in-progress", aggregate_id, event_type, version}.
  """
  def handle(conn, schema, request) do
    s = Schema.name(schema)
    if (request[:tenant_id] || "") == "", do: raise(DomainError, "tenant_id is required")
    request = Map.put(request, :aggregate_type, request[:aggregate_type] || @default_aggregate)
    unless Map.has_key?(@aggregates, request.aggregate_type), do: raise(DomainError, "Unknown aggregate type #{request.aggregate_type}")

    {span, ctx} =
      Telemetry.start_span(Telemetry.context_from(request[:traceparent]), "#{request.aggregate_type}.#{request.command}", :internal, %{
        "tenant.id" => request.tenant_id,
        "aggregate.id" => request.aggregate_id
      })

    try do
      case Postgrex.transaction(conn, fn tx -> execute(tx, s, request, Telemetry.traceparent_of(ctx)) end) do
        {:ok, result} -> result
        {:error, reason} -> raise DomainError, inspect(reason)
      end
    rescue
      e ->
        Telemetry.error(span, e)
        reraise e, __STACKTRACE__
    after
      :otel_span.end_span(span)
    end
  end

  defp execute(tx, s, req, traceparent) do
    key = req[:idempotency_key]

    case claim(tx, s, req.tenant_id, key) do
      {:replay, result} -> result
      :claimed -> apply_command(tx, s, req, key, traceparent)
    end
  end

  defp claim(_tx, _s, _tenant, nil), do: :claimed

  defp claim(tx, s, tenant, key) do
    %{num_rows: inserted} = Postgrex.query!(tx, "INSERT INTO #{s}.ghk_idempotency (tenant_id, key, status) VALUES ($1, $2, 'PROCESSING') ON CONFLICT DO NOTHING", [tenant, key])

    if inserted == 1 do
      :claimed
    else
      case Postgrex.query!(tx, "SELECT status, response FROM #{s}.ghk_idempotency WHERE tenant_id = $1 AND key = $2", [tenant, key]).rows do
        [["COMPLETED", response]] -> {:replay, response |> Jason.decode!(keys: :atoms) |> Map.put(:status, "replayed")}
        _ -> {:replay, %{status: "in-progress", aggregate_id: nil, event_type: nil, version: nil}}
      end
    end
  end

  defp apply_command(tx, s, req, key, traceparent) do
    {module, commands} = Map.fetch!(@aggregates, req.aggregate_type)

    aggregate =
      case Postgrex.query!(tx, "SELECT state, version FROM #{s}.ghk_aggregates WHERE tenant_id = $1 AND aggregate_type = $2 AND id = $3 FOR UPDATE",
             [req.tenant_id, req.aggregate_type, req.aggregate_id]).rows do
        [[state, version]] -> module.restore(req.aggregate_id, state, version)
        [] -> unwrap(module.new(req.aggregate_id))
      end

    handler = Map.get(commands, req.command) || raise(DomainError, "Unknown command #{req.command}")
    {updated, event} = unwrap(handler.(aggregate, %{id: req.aggregate_id, payload: req[:payload] || %{}}))

    Postgrex.query!(
      tx,
      "INSERT INTO #{s}.ghk_aggregates (tenant_id, aggregate_type, id, state, version) VALUES ($1, $2, $3, $4, $5) " <>
        "ON CONFLICT (tenant_id, aggregate_type, id) DO UPDATE SET state = EXCLUDED.state, version = EXCLUDED.version, updated_at = now()",
      [req.tenant_id, req.aggregate_type, req.aggregate_id, updated.state, updated.version]
    )

    Postgrex.query!(tx, "INSERT INTO #{s}.ghk_outbox (id, tenant_id, aggregate_id, event_type, payload, traceparent) VALUES ($1, $2, $3, $4, $5, $6)", [
      uuid(),
      req.tenant_id,
      req.aggregate_id,
      event.type,
      Jason.encode!(event),
      traceparent
    ])

    result = %{status: "created", aggregate_id: req.aggregate_id, event_type: event.type, version: event.version}

    if key do
      Postgrex.query!(tx, "UPDATE #{s}.ghk_idempotency SET status = 'COMPLETED', response = $3 WHERE tenant_id = $1 AND key = $2", [req.tenant_id, key, Jason.encode!(result)])
    end

    result
  end

  defp unwrap({:ok, aggregate}), do: aggregate
  defp unwrap({:ok, aggregate, event}), do: {aggregate, event}
  defp unwrap({:error, reason}), do: raise(DomainError, reason)

  @doc "The aggregate as the tenant sees it (nil for other tenants' aggregates)."
  def load(conn, schema, tenant_id, aggregate_id, aggregate_type \\ @default_aggregate) do
    case Postgrex.query!(conn, "SELECT state, version FROM #{Schema.name(schema)}.ghk_aggregates WHERE tenant_id = $1 AND aggregate_type = $2 AND id = $3",
           [tenant_id, aggregate_type, aggregate_id]).rows do
      [[state, version]] -> %{state: state, version: version}
      [] -> nil
    end
  end

  def uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::62>> = :crypto.strong_rand_bytes(16)
    <<a::32, b::16, 4::4, c::12, 2::2, d::62>> |> Base.encode16(case: :lower) |> then(fn h ->
      String.slice(h, 0, 8) <> "-" <> String.slice(h, 8, 4) <> "-" <> String.slice(h, 12, 4) <> "-" <> String.slice(h, 16, 4) <> "-" <> String.slice(h, 20, 12)
    end)
  end
end
