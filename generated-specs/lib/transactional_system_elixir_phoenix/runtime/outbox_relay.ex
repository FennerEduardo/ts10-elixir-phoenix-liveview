defmodule TransactionalSystemElixirPhoenix.Runtime.OutboxRelay do
  @moduledoc """
  Publishes pending outbox rows. Rows are claimed with FOR UPDATE SKIP LOCKED and a lease, so
  concurrent relays never publish the same row; the publisher returns only once the broker has
  accepted the message (RabbitMQ confirms, Pub/Sub publish), before a row is marked published.
  Use one relay (and publisher, from Broker.publisher/2) per process.
  """
  alias TransactionalSystemElixirPhoenix.Runtime.{Broker, Schema, Telemetry}

  @lease_seconds 30
  @max_attempts 5

  def publish_batch(conn, publisher, schema, worker_id, limit \\ 50) do
    s = Schema.name(schema)

    %{rows: rows} =
      Postgrex.query!(
        conn,
        "UPDATE #{s}.ghk_outbox SET claimed_by = $1, claimed_until = now() + make_interval(secs => $2), attempts = attempts + 1 " <>
          "WHERE id IN (SELECT id FROM #{s}.ghk_outbox WHERE published_at IS NULL AND failed_at IS NULL AND (claimed_until IS NULL OR claimed_until < now()) " <>
          "ORDER BY created_at LIMIT $3 FOR UPDATE SKIP LOCKED) RETURNING id, tenant_id, event_type, payload, traceparent",
        [worker_id, @lease_seconds * 1.0, limit]
      )

    Enum.count(rows, fn row -> publish(conn, publisher, s, worker_id, row) end)
  end

  defp publish(conn, publisher, s, worker_id, [id, tenant, event_type, payload, traceparent]) do
    destination = publisher.destination

    {span, ctx} =
      Telemetry.start_span(Telemetry.context_from(traceparent), "#{destination} publish", :producer, %{
        "messaging.system" => Broker.system(Map.get(publisher, :broker, publisher)),
        "messaging.destination.name" => destination,
        "messaging.message.id" => id,
        "tenant.id" => tenant
      })

    try do
      :ok = Broker.publish(publisher, %{message_id: id, event_type: event_type, tenant_id: tenant, traceparent: Telemetry.traceparent_of(ctx), body: payload})
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
