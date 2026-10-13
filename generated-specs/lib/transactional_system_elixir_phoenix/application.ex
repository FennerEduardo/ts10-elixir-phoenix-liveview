defmodule TransactionalSystemElixirPhoenix.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    database_url = System.get_env("DATABASE_URL")
    amqp_url = System.get_env("AMQP_URL")

    # The command service needs DATABASE_URL; the relay also needs AMQP_URL (off in tests: config :outbox_relay).
    children =
      if(database_url, do: [{Postgrex, TransactionalSystemElixirPhoenix.Runtime.Schema.connection_opts(database_url) ++ [name: TransactionalSystemElixirPhoenix.DB, pool_size: 10]}], else: []) ++
        if(database_url && amqp_url && Application.get_env(:transactional_system_elixir_phoenix, :outbox_relay, true), do: [{TransactionalSystemElixirPhoenix.OutboxRelayWorker, amqp_url}], else: []) ++
        [TransactionalSystemElixirPhoenixWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: TransactionalSystemElixirPhoenix.Supervisor)
  end
end
