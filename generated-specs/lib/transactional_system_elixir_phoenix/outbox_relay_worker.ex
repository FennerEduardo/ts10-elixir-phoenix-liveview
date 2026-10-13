defmodule TransactionalSystemElixirPhoenix.OutboxRelayWorker do
  @moduledoc "Publishes the outbox every 1000 ms (AMQP_URL); reconnects after broker errors."
  use GenServer
  require Logger

  def start_link(amqp_url), do: GenServer.start_link(__MODULE__, amqp_url, name: __MODULE__)

  @impl true
  def init(amqp_url) do
    send(self(), :connect)
    {:ok, %{url: amqp_url, chan: nil, worker_id: "orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}}
  end

  @impl true
  def handle_info(:connect, state) do
    with {:ok, connection} <- AMQP.Connection.open(state.url),
         {:ok, chan} <- AMQP.Channel.open(connection),
         :ok <- TransactionalSystemElixirPhoenix.Runtime.Topology.declare(chan, %TransactionalSystemElixirPhoenix.Runtime.Topology{}),
         :ok <- TransactionalSystemElixirPhoenix.Runtime.OutboxRelay.prepare(chan) do
      send(self(), :tick)
      {:noreply, %{state | chan: chan}}
    else
      error ->
        Logger.error("outbox relay cannot connect: #{inspect(error)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:tick, %{chan: chan} = state) do
    try do
      TransactionalSystemElixirPhoenix.Runtime.OutboxRelay.publish_batch(TransactionalSystemElixirPhoenix.DB, chan, %TransactionalSystemElixirPhoenix.Runtime.Topology{}.exchange, "public", state.worker_id)
    rescue
      e -> Logger.error("outbox relay failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end
end
