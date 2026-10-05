defmodule TransactionalSystemElixirPhoenix.Runtime.IntegrationTest do
  @moduledoc "Runtime integration tests (docs/RUNTIME-KERNEL.md, IT1-IT7). Requires DATABASE_URL and AMQP_URL."
  use ExUnit.Case, async: false
  require Record

  @moduletag :integration

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  alias TransactionalSystemElixirPhoenix.Runtime.{CommandService, InboxConsumer, OutboxRelay, Saga, Schema, Topology}

  @command "process_orquestacion_de_saga_con_gen_server_y_pattern_matching_en_elixir_phoenix"
  @event "PedidoYEventoOutboxSonInsertadosAtmicamenteEnPostgreSql"

  setup_all do
    database_url = System.get_env("DATABASE_URL") || flunk("Integration tests need DATABASE_URL and AMQP_URL (see docs/RUNTIME-KERNEL.md).")
    amqp_url = System.get_env("AMQP_URL") || flunk("Integration tests need DATABASE_URL and AMQP_URL (see docs/RUNTIME-KERNEL.md).")
    {:ok, conn} = Postgrex.start_link(Schema.connection_opts(database_url) ++ [pool_size: 10])
    %{conn: conn, amqp_url: amqp_url}
  end

  setup %{conn: conn} do
    uid = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    schema = "it_#{uid}"
    Schema.migrate(conn, schema)
    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(Schema.connection_opts(System.get_env("DATABASE_URL")))
      Postgrex.query!(c, "DROP SCHEMA IF EXISTS #{schema} CASCADE", [])
    end)
    %{schema: schema, topology: Topology.for_prefix("it-#{uid}")}
  end

  defp count(conn, schema, table, where \\ "true", params \\ []) do
    %{rows: [[n]]} = Postgrex.query!(conn, "SELECT count(*) FROM #{schema}.#{table} WHERE #{where}", params)
    n
  end

  defp channel(url) do
    {:ok, connection} = AMQP.Connection.open(url)
    {:ok, chan} = AMQP.Channel.open(connection)
    {connection, chan}
  end

  defp drain_queue(chan, queue) do
    case AMQP.Basic.get(chan, queue, no_ack: true) do
      {:ok, _payload, meta} -> [meta | drain_queue(chan, queue)]
      {:empty, _} -> []
    end
  end

  defp wait_for(fun, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("timed out waiting for condition")
      true -> Process.sleep(50) && wait_for(fun, deadline)
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

  test "IT3 two concurrent relays publish every outbox event exactly once", %{conn: conn, schema: schema, topology: t, amqp_url: url} do
    for i <- 0..19, do: CommandService.handle(conn, schema, request("t1", "agg-#{i}"))
    {setup_connection, setup} = channel(url)
    Topology.declare(setup, t)

    totals =
      ["relay-a", "relay-b"]
      |> Enum.map(fn worker ->
        Task.async(fn ->
          {connection, chan} = channel(url)
          :ok = OutboxRelay.prepare(chan)
          total = Stream.repeatedly(fn -> OutboxRelay.publish_batch(conn, chan, t.exchange, schema, worker, 3) end) |> Enum.take_while(&(&1 > 0)) |> Enum.sum()
          AMQP.Connection.close(connection)
          total
        end)
      end)
      |> Task.await_many(60_000)

    assert Enum.sum(totals) == 20
    assert count(conn, schema, "ghk_outbox", "published_at IS NULL") == 0
    wait_for(fn -> AMQP.Queue.message_count(setup, t.queue) == 20 end)
    assert drain_queue(setup, t.queue) |> Enum.map(& &1.message_id) |> Enum.uniq() |> length() == 20
    AMQP.Connection.close(setup_connection)
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

  test "IT6 a redelivered message is handled once and a failing message is dead-lettered", %{conn: conn, schema: schema, topology: t, amqp_url: url} do
    {connection, chan} = channel(url)
    Topology.declare(chan, t)
    {:ok, handled} = Agent.start_link(fn -> [] end)

    for {id, body} <- [{"m-1", ~s({"ok": true})}, {"m-1", ~s({"ok": true})}, {"m-poison", ~s({"poison": true})}] do
      :ok = AMQP.Basic.publish(chan, t.exchange, "Test", body, message_id: id, headers: [{"tenant_id", :longstr, "t1"}])
    end

    InboxConsumer.drain(conn, chan, t.queue, "it-consumer", schema, fn event, meta ->
      if event["poison"], do: raise("cannot process")
      Agent.update(handled, &(&1 ++ [meta.message_id]))
    end)

    assert Agent.get(handled, & &1) == ["m-1"]
    assert count(conn, schema, "ghk_inbox", "consumer = $1", ["it-consumer"]) == 1
    wait_for(fn -> AMQP.Queue.message_count(chan, t.dlq) == 1 end)
    assert drain_queue(chan, t.dlq) |> Enum.map(& &1.message_id) == ["m-poison"]
    AMQP.Connection.close(connection)
  end

  test "IT7 the incoming trace context flows through command, outbox, publish and consume spans", %{conn: conn, schema: schema, topology: t, amqp_url: url} do
    # The test env uses otel_simple_processor (config/config.exs); route its exports to this process.
    # Restarting the SDK is not an option: tracers are cached with their processors in persistent_term.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    # set_exporter is asynchronous: wait until a probe span arrives before producing real spans.
    await_exporter()

    CommandService.handle(conn, schema, request("t1", "agg-1", %{traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}))
    %{rows: [[stored]]} = Postgrex.query!(conn, "SELECT traceparent FROM #{schema}.ghk_outbox", [])
    assert stored =~ "4bf92f3577b34da6a3ce929d0e0e4736"

    {connection, chan} = channel(url)
    Topology.declare(chan, t)
    :ok = OutboxRelay.prepare(chan)
    assert OutboxRelay.publish_batch(conn, chan, t.exchange, schema, "relay", 10) == 1
    {:ok, received} = Agent.start_link(fn -> 0 end)
    InboxConsumer.drain(conn, chan, t.queue, "trace-consumer", schema, fn _event, _meta -> Agent.update(received, &(&1 + 1)) end)
    assert Agent.get(received, & &1) == 1
    AMQP.Connection.close(connection)

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
