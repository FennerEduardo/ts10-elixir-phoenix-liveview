defmodule TransactionalSystemElixirPhoenix.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([TransactionalSystemElixirPhoenixWeb.Endpoint], strategy: :one_for_one, name: TransactionalSystemElixirPhoenix.Supervisor)
  end
end
