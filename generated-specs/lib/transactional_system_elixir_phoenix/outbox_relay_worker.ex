defmodule TransactionalSystemElixirPhoenix.OutboxRelayWorker do
  @moduledoc "Publishes the outbox every 1000 ms through the configured broker (Runtime.Broker); reconnects after broker errors."
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :connect)
    {:ok, %{publisher: nil, worker_id: "orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}}
  end

  @impl true
  def handle_info(:connect, state) do
    try do
      broker = TransactionalSystemElixirPhoenix.Runtime.Broker.connect()
      :ok = TransactionalSystemElixirPhoenix.Runtime.Broker.declare(broker, %TransactionalSystemElixirPhoenix.Runtime.Topology{})
      send(self(), :tick)
      {:noreply, %{state | publisher: TransactionalSystemElixirPhoenix.Runtime.Broker.publisher(broker, %TransactionalSystemElixirPhoenix.Runtime.Topology{}.exchange)}}
    rescue
      e ->
        Logger.error("outbox relay cannot connect: #{Exception.message(e)}")
        Process.send_after(self(), :connect, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:tick, %{publisher: publisher} = state) do
    try do
      TransactionalSystemElixirPhoenix.Runtime.OutboxRelay.publish_batch(TransactionalSystemElixirPhoenix.DB, publisher, "public", state.worker_id)
    rescue
      e -> Logger.error("outbox relay failed: #{Exception.message(e)}")
    end

    Process.send_after(self(), :tick, 1000)
    {:noreply, state}
  end
end
