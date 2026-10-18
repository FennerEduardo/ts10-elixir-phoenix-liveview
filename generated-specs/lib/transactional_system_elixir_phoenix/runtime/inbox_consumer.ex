defmodule TransactionalSystemElixirPhoenix.Runtime.InboxConsumer do
  @moduledoc """
  Idempotent consumer: the message id is recorded in ghk_inbox in the same transaction as the
  handler, so redeliveries are acknowledged without running the handler twice. A handler error
  dead-letters the message (RabbitMQ DLX, Pub/Sub dead-letter topic): it is not redelivered.
  """
  alias TransactionalSystemElixirPhoenix.Runtime.{Broker, Schema, Telemetry}

  @doc "Processes messages until the subscription stays empty for idle_ms; returns how many were processed. handler.(event, meta)"
  def drain(conn, subscription, consumer, schema, handler, idle_ms \\ 1000) do
    loop(conn, subscription, consumer, Schema.name(schema), handler, idle_ms, System.monotonic_time(:millisecond), 0)
  end

  defp loop(conn, subscription, consumer, s, handler, idle_ms, idle_since, processed) do
    if System.monotonic_time(:millisecond) - idle_since >= idle_ms do
      processed
    else
      case Broker.poll(subscription) do
        nil ->
          Process.sleep(50)
          loop(conn, subscription, consumer, s, handler, idle_ms, idle_since, processed)

        delivery ->
          process(conn, subscription, consumer, s, handler, delivery)
          loop(conn, subscription, consumer, s, handler, idle_ms, System.monotonic_time(:millisecond), processed + 1)
      end
    end
  end

  defp process(conn, subscription, consumer, s, handler, %{message: m} = delivery) do
    {span, _ctx} =
      Telemetry.start_span(Telemetry.context_from(m.traceparent), "#{subscription.source} process", :consumer, %{
        "messaging.system" => Broker.system(Map.get(subscription, :broker, subscription)),
        "messaging.destination.name" => subscription.source,
        "messaging.message.id" => to_string(m.message_id)
      })

    try do
      {:ok, _} =
        Postgrex.transaction(conn, fn tx ->
          %{num_rows: first} = Postgrex.query!(tx, "INSERT INTO #{s}.ghk_inbox (consumer, message_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", [consumer, m.message_id])

          if first == 1 do
            handler.(Jason.decode!(m.body), %{message_id: m.message_id, tenant_id: m.tenant_id, event_type: m.event_type, conn: tx})
          end
        end)

      delivery.ack.()
    rescue
      e ->
        Telemetry.error(span, e)
        delivery.dead_letter.()
    after
      :otel_span.end_span(span)
    end
  end
end
