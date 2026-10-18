defmodule TransactionalSystemElixirPhoenix.Runtime.IntegrationTest do
  @moduledoc """
  Runtime integration tests (docs/RUNTIME-KERNEL.md, IT1-IT7). Requires DATABASE_URL and the selected broker
  (GHK_BROKER: rabbitmq with AMQP_URL, pubsub with PUBSUB_PROJECT_ID [+ PUBSUB_EMULATOR_HOST]).
  """
  use ExUnit.Case, async: false
  require Record

  @moduletag :integration

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias TransactionalSystemElixirPhoenix.Runtime.{Broker, CommandService, InboxConsumer, OutboxRelay, Saga, Schema, Topology}

  @command "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix"
  @event "PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql"

  setup_all do
    database_url = System.get_env("DATABASE_URL") || flunk("Integration tests need DATABASE_URL and the broker variables (see docs/RUNTIME-KERNEL.md).")
    unless Broker.configured?(), do: flunk("Integration tests need the broker variables (see docs/RUNTIME-KERNEL.md).")
    {:ok, conn} = Postgrex.start_link(Schema.connection_opts(database_url) ++ [pool_size: 10])
    %{conn: conn}
  end

  setup %{conn: conn} do
    uid = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    schema = "it_#{uid}"
    Schema.migrate(conn, schema)
    broker = Broker.connect()
    topology = Topology.for_prefix("it-#{uid}")
    :ok = Broker.declare(broker, topology)
    on_exit(fn ->
      Broker.close(broker)
      {:ok, c} = Postgrex.start_link(Schema.connection_opts(System.get_env("DATABASE_URL")))
      Postgrex.query!(c, "DROP SCHEMA IF EXISTS #{schema} CASCADE", [])
    end)
    %{schema: schema, topology: topology, broker: broker}
  end

  defp count(conn, schema, table, where \\ "true", params \\ []) do
    %{rows: [[n]]} = Postgrex.query!(conn, "SELECT count(*) FROM #{schema}.#{table} WHERE #{where}", params)
    n
  end

  # Receives and acknowledges messages until expected arrived and the source stays quiet for 500 ms (10 s at most).
  defp receive_messages(broker, t, source, expected) do
    subscription = Broker.subscribe(broker, source, t)
    deadline = System.monotonic_time(:millisecond) + 10_000
    messages = receive_loop(subscription, expected, deadline, System.monotonic_time(:millisecond), [])
    Broker.close_subscription(subscription)
    messages
  end

  defp receive_loop(subscription, expected, deadline, quiet_since, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline or (length(acc) >= expected and now - quiet_since >= 500) do
      Enum.reverse(acc)
    else
      case Broker.poll(subscription) do
        nil ->
          Process.sleep(50)
          receive_loop(subscription, expected, deadline, quiet_since, acc)

        delivery ->
          delivery.ack.()
          receive_loop(subscription, expected, deadline, System.monotonic_time(:millisecond), [delivery.message | acc])
      end
    end
  end

  defp request(tenant, id, extra \\ %{}), do: Map.merge(%{tenant_id: tenant, aggregate_id: id, command: @command}, extra)

  test "IT1 persists the aggregate and one outbox row atomically; a domain error persists nothing", %{conn: conn, schema: schema} do
    result = CommandService.handle(conn, schema, request("t1", "agg-1"))
    assert {result.status, result.event_type, result.version} == {"created", @event, 1}
    assert CommandService.load(conn, schema, "t1", "agg-1").version == 1
    assert count(conn, schema, "ghk_outbox", "aggregate_id = $1", ["agg-1"]) == 1

    assert_raise CommandService.DomainError, ~r/Unknown command/, fn ->
      CommandService.handle(conn, schema, request("t1", "agg-2", %{command: "no_such_command", idempotency_key: "k-fail"}))
    end

    assert CommandService.load(conn, schema, "t1", "agg-2") == nil
    assert count(conn, schema, "ghk_outbox", "aggregate_id = $1", ["agg-2"]) == 0
    assert count(conn, schema, "ghk_idempotency", "key = $1", ["k-fail"]) == 0
  end

  test "IT2 five concurrent requests with one idempotency key produce one effect and identical responses", %{conn: conn, schema: schema} do
    results =
      1..5
      |> Enum.map(fn _ -> Task.async(fn -> CommandService.handle(conn, schema, request("t1", "agg-1", %{idempotency_key: "key-1"})) end) end)
      |> Task.await_many(30_000)

    assert count(conn, schema, "ghk_outbox") == 1
    assert CommandService.load(conn, schema, "t1", "agg-1").version == 1
    assert Enum.count(results, &(&1.status == "created")) == 1
    assert Enum.uniq(Enum.map(results, &{&1.event_type, &1.version})) == [{@event, 1}]
  end

  test "IT3 two concurrent relays publish every outbox event exactly once", %{conn: conn, schema: schema, topology: t, broker: broker} do
    for i <- 0..19, do: CommandService.handle(conn, schema, request("t1", "agg-#{i}"))

    totals =
      ["relay-a", "relay-b"]
      |> Enum.map(fn worker ->
        Task.async(fn ->
          publisher = Broker.publisher(broker, t.exchange)
          total = Stream.repeatedly(fn -> OutboxRelay.publish_batch(conn, publisher, schema, worker, 3) end) |> Enum.take_while(&(&1 > 0)) |> Enum.sum()
          Broker.close_publisher(publisher)
          total
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.sum(totals) == 20
    assert count(conn, schema, "ghk_outbox", "published_at IS NULL") == 0
    received = receive_messages(broker, t, t.queue, 20)
    assert length(received) == 20
    assert received |> Enum.map(& &1.message_id) |> Enum.uniq() |> length() == 20
  end

  test "IT4 tenants cannot read or change each other's aggregates", %{conn: conn, schema: schema} do
    CommandService.handle(conn, schema, request("tenant-a", "shared-id"))
    assert CommandService.load(conn, schema, "tenant-b", "shared-id") == nil
    CommandService.handle(conn, schema, request("tenant-b", "shared-id"))
    assert CommandService.load(conn, schema, "tenant-a", "shared-id").version == 1
    assert CommandService.load(conn, schema, "tenant-b", "shared-id").version == 1
    assert count(conn, schema, "ghk_outbox", "tenant_id = $1", ["tenant-a"]) == 1
  end

  test "IT5 a failing saga step compensates the completed steps in reverse order", %{conn: conn, schema: schema} do
    {:ok, log} = Agent.start_link(fn -> [] end)
    record = fn entry -> Agent.update(log, &(&1 ++ [entry])) end

    step = fn name, fail ->
      %{name: name, action: fn -> if fail, do: raise("#{name} failed"), else: record.("do:#{name}") end, compensate: fn -> record.("undo:#{name}") end}
    end

    assert Saga.run(conn, schema, "saga-1", "t1", [step.("reserve", false), step.("charge", false), step.("ship", true)]) == "COMPENSATED"
    assert Agent.get(log, & &1) == ["do:reserve", "do:charge", "undo:charge", "undo:reserve"]
    assert Saga.status(conn, schema, "saga-1") == %{status: "COMPENSATED", completed_steps: []}
    assert Saga.run(conn, schema, "saga-2", "t1", [step.("reserve", false), step.("charge", false)]) == "COMPLETED"
  end

  test "IT6 a redelivered message is handled once and a failing message is dead-lettered", %{conn: conn, schema: schema, topology: t, broker: broker} do
    {:ok, handled} = Agent.start_link(fn -> [] end)
    publisher = Broker.publisher(broker, t.exchange)

    for {id, body} <- [{"m-1", ~s({"ok": true})}, {"m-1", ~s({"ok": true})}, {"m-poison", ~s({"poison": true})}] do
      :ok = Broker.publish(publisher, %{message_id: id, event_type: "Test", tenant_id: "t1", traceparent: nil, body: body})
    end

    Broker.close_publisher(publisher)
    subscription = Broker.subscribe(broker, t.queue, t)

    InboxConsumer.drain(conn, subscription, "it-consumer", schema, fn event, meta ->
      if event["poison"], do: raise("cannot process")
      Agent.update(handled, &(&1 ++ [meta.message_id]))
    end)

    Broker.close_subscription(subscription)
    assert Agent.get(handled, & &1) == ["m-1"]
    assert count(conn, schema, "ghk_inbox", "consumer = $1", ["it-consumer"]) == 1
    assert receive_messages(broker, t, t.dlq, 1) |> Enum.map(& &1.message_id) == ["m-poison"]
  end

  test "IT7 the incoming trace context flows through command, outbox, publish and consume spans", %{conn: conn, schema: schema, topology: t, broker: broker} do
    # The test env uses otel_simple_processor (config/config.exs); route its exports to this process.
    # Restarting the SDK is not an option: tracers are cached with their processors in persistent_term.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    # set_exporter is asynchronous: wait until a probe span arrives before producing real spans.
    await_exporter()

    CommandService.handle(conn, schema, request("t1", "agg-1", %{traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}))
    %{rows: [[stored]]} = Postgrex.query!(conn, "SELECT traceparent FROM #{schema}.ghk_outbox", [])
    assert stored =~ "4bf92f3577b34da6a3ce929d0e0e4736"

    publisher = Broker.publisher(broker, t.exchange)
    assert OutboxRelay.publish_batch(conn, publisher, schema, "relay", 10) == 1
    Broker.close_publisher(publisher)
    {:ok, received} = Agent.start_link(fn -> 0 end)
    subscription = Broker.subscribe(broker, t.queue, t)
    InboxConsumer.drain(conn, subscription, "trace-consumer", schema, fn _event, _meta -> Agent.update(received, &(&1 + 1)) end)
    Broker.close_subscription(subscription)
    assert Agent.get(received, & &1) == 1

    hex = fn id, size -> id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(size, "0") end
    command_name = "OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenix.#{@command}"
    publish_name = "#{t.exchange} publish"
    process_name = "#{t.queue} process"
    assert_receive {:span, span(name: ^command_name, kind: :internal) = command}, 5_000
    assert_receive {:span, span(name: ^publish_name, kind: :producer) = producer}, 5_000
    assert_receive {:span, span(name: ^process_name, kind: :consumer) = consumer}, 5_000
    assert hex.(span(command, :trace_id), 32) == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert hex.(span(command, :parent_span_id), 16) == "00f067aa0ba902b7"
    assert hex.(span(producer, :trace_id), 32) == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert hex.(span(consumer, :trace_id), 32) == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert span(consumer, :parent_span_id) == span(producer, :span_id)
  end

  defp await_exporter(attempts \\ 50) do
    {probe, _} = TransactionalSystemElixirPhoenix.Runtime.Telemetry.start_span(:otel_ctx.new(), "exporter-probe", :internal, %{})
    :otel_span.end_span(probe)

    receive do
      {:span, span(name: "exporter-probe")} -> :ok
    after
      100 -> if attempts > 0, do: await_exporter(attempts - 1), else: flunk("span exporter did not start")
    end
  end
end
