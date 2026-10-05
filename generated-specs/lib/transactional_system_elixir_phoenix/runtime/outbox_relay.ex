defmodule TransactionalSystemElixirPhoenix.Runtime.OutboxRelay do
  @moduledoc """
  Publishes pending outbox rows. Rows are claimed with FOR UPDATE SKIP LOCKED and a lease, so
  concurrent relays never publish the same row; publisher confirms guarantee delivery to the
  broker before a row is marked published. Use one relay (and channel) per process.
  """
  alias TransactionalSystemElixirPhoenix.Runtime.{Schema, Telemetry}

  @lease_seconds 30
  @max_attempts 5

  @doc "Puts the channel in confirm mode; call once per channel."
  def prepare(chan), do: AMQP.Confirm.select(chan)

  def publish_batch(conn, chan, exchange, schema, worker_id, limit \\ 50) do
    s = Schema.name(schema)

    %{rows: rows} =
      Postgrex.query!(
        conn,
        "UPDATE #{s}.ghk_outbox SET claimed_by = $1, claimed_until = now() + make_interval(secs => $2), attempts = attempts + 1 " <>
          "WHERE id IN (SELECT id FROM #{s}.ghk_outbox WHERE published_at IS NULL AND failed_at IS NULL AND (claimed_until IS NULL OR claimed_until < now()) " <>
          "ORDER BY created_at LIMIT $3 FOR UPDATE SKIP LOCKED) RETURNING id, tenant_id, event_type, payload, traceparent",
        [worker_id, @lease_seconds * 1.0, limit]
      )

    Enum.count(rows, fn row -> publish(conn, chan, exchange, s, worker_id, row) end)
  end

  defp publish(conn, chan, exchange, s, worker_id, [id, tenant, event_type, payload, traceparent]) do
    {span, ctx} =
      Telemetry.start_span(Telemetry.context_from(traceparent), "#{exchange} publish", :producer, %{
        "messaging.system" => "rabbitmq",
        "messaging.destination.name" => exchange,
        "messaging.message.id" => id,
        "tenant.id" => tenant
      })

    headers = [{"tenant_id", :longstr, tenant}] ++ Enum.map(List.wrap(Telemetry.traceparent_of(ctx)), &{"traceparent", :longstr, &1})

    try do
      :ok = AMQP.Basic.publish(chan, exchange, event_type, payload, message_id: id, persistent: true, content_type: "application/json", type: event_type, headers: headers)
      true = AMQP.Confirm.wait_for_confirms(chan, 10_000)
      Postgrex.query!(conn, "UPDATE #{s}.ghk_outbox SET published_at = now(), claimed_until = NULL WHERE id = $1 AND claimed_by = $2", [id, worker_id])
      true
    rescue
      e ->
        Telemetry.error(span, e)
        Postgrex.query!(conn, "UPDATE #{s}.ghk_outbox SET claimed_until = NULL, last_error = $2, failed_at = CASE WHEN attempts >= $3 THEN now() ELSE NULL END WHERE id = $1", [
          id,
          Exception.message(e),
          @max_attempts
        ])

        false
    after
      :otel_span.end_span(span)
    end
  end
end
