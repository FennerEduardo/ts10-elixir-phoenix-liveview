defmodule TransactionalSystemElixirPhoenix.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    database_url = System.get_env("DATABASE_URL")
    # The command service needs DATABASE_URL; the relay also needs a broker (AMQP_URL or PUBSUB_*; off in tests: config :outbox_relay).
    # Children start in order: the kernel's tables exist before the relay and the endpoint start.
    children =
      if(database_url,
        do: [
          {Postgrex, TransactionalSystemElixirPhoenix.Runtime.Schema.connection_opts(database_url) ++ [name: TransactionalSystemElixirPhoenix.DB, pool_size: 10]},
          %{id: :ghk_runtime_schema, start: {__MODULE__, :migrate, []}, restart: :temporary}
        ],
        else: []
      ) ++
        if(database_url && TransactionalSystemElixirPhoenix.Runtime.Broker.configured?() && Application.get_env(:transactional_system_elixir_phoenix, :outbox_relay, true), do: [{TransactionalSystemElixirPhoenix.OutboxRelayWorker, []}], else: []) ++
        [TransactionalSystemElixirPhoenixWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: TransactionalSystemElixirPhoenix.Supervisor)
  end

  @doc "Creates the runtime kernel's tables (idempotent, serialized across replicas). GHK_MIGRATE=false when a migration job owns them."
  def migrate do
    if System.get_env("GHK_MIGRATE") != "false", do: TransactionalSystemElixirPhoenix.Runtime.Schema.migrate(TransactionalSystemElixirPhoenix.DB)
    :ignore
  end
end
