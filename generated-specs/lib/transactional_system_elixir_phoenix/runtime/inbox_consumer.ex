defmodule TransactionalSystemElixirPhoenix.Runtime.InboxConsumer do
  @moduledoc """
  Idempotent consumer: the message id is recorded in ghk_inbox in the same transaction as the
  handler, so redeliveries are acknowledged without running the handler twice. A handler error
  rejects the message without requeue, so RabbitMQ dead-letters it to the DLQ.
  """
  alias TransactionalSystemElixirPhoenix.Runtime.{Schema, Telemetry}

  @doc "Processes messages until the queue stays empty for idle_ms; returns how many were processed. handler.(event, meta)"
  def drain(conn, chan, queue, consumer, schema, handler, idle_ms \\ 1000) do
    loop(conn, chan, queue, consumer, Schema.name(schema), handler, idle_ms, System.monotonic_time(:millisecond), 0)
  end

  defp loop(conn, chan, queue, consumer, s, handler, idle_ms, idle_since, processed) do
    if System.monotonic_time(:millisecond) - idle_since >= idle_ms do
      processed
    else
      case AMQP.Basic.get(chan, queue, no_ack: false) do
        {:ok, payload, meta} ->
          process(conn, chan, queue, consumer, s, handler, payload, meta)
          loop(conn, chan, queue, consumer, s, handler, idle_ms, System.monotonic_time(:millisecond), processed + 1)

        {:empty, _} ->
          Process.sleep(50)
          loop(conn, chan, queue, consumer, s, handler, idle_ms, idle_since, processed)
      end
    end
  end

  defp header(meta, name) do
    headers = if is_list(meta.headers), do: meta.headers, else: []

    case List.keyfind(headers, name, 0) do
      {_, _, value} -> value
      _ -> nil
    end
  end

  defp process(conn, chan, queue, consumer, s, handler, payload, meta) do
    {span, _ctx} =
      Telemetry.start_span(Telemetry.context_from(header(meta, "traceparent")), "#{queue} process", :consumer, %{
        "messaging.system" => "rabbitmq",
        "messaging.destination.name" => queue,
        "messaging.message.id" => to_string(meta.message_id)
      })

    try do
      {:ok, _} =
        Postgrex.transaction(conn, fn tx ->
          %{num_rows: first} = Postgrex.query!(tx, "INSERT INTO #{s}.ghk_inbox (consumer, message_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", [consumer, meta.message_id])

          if first == 1 do
            handler.(Jason.decode!(payload), %{message_id: meta.message_id, tenant_id: header(meta, "tenant_id"), event_type: meta.type, conn: tx})
          end
        end)

      AMQP.Basic.ack(chan, meta.delivery_tag)
    rescue
      e ->
        Telemetry.error(span, e)
        AMQP.Basic.reject(chan, meta.delivery_tag, requeue: false)
    after
      :otel_span.end_span(span)
    end
  end
end
