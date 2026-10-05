defmodule TransactionalSystemElixirPhoenix.Runtime.Topology do
  @moduledoc "Topic exchange -> consumer queue, which dead-letters rejected messages to a fanout DLX -> DLQ."
  defstruct exchange: "orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix.events", queue: "orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix.consumer", dlx: "orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix.dlx", dlq: "orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix.dlq"

  def for_prefix(prefix), do: %__MODULE__{exchange: "#{prefix}.events", queue: "#{prefix}.consumer", dlx: "#{prefix}.dlx", dlq: "#{prefix}.dlq"}

  def declare(chan, %__MODULE__{} = t) do
    :ok = AMQP.Exchange.declare(chan, t.exchange, :topic, durable: true)
    :ok = AMQP.Exchange.declare(chan, t.dlx, :fanout, durable: true)
    {:ok, _} = AMQP.Queue.declare(chan, t.dlq, durable: true)
    :ok = AMQP.Queue.bind(chan, t.dlq, t.dlx)
    {:ok, _} = AMQP.Queue.declare(chan, t.queue, durable: true, arguments: [{"x-dead-letter-exchange", :longstr, t.dlx}])
    :ok = AMQP.Queue.bind(chan, t.queue, t.exchange, routing_key: "#")
  end
end
