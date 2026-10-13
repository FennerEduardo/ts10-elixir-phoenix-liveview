defmodule TransactionalSystemElixirPhoenix.Commands do
  @moduledoc "The command port: the runtime kernel's CommandService over the TransactionalSystemElixirPhoenix.DB pool (tests swap it via :command_port)."

  def handle(request), do: impl().handle(request)

  def impl, do: Application.get_env(:transactional_system_elixir_phoenix, :command_port, __MODULE__.Runtime)

  defmodule Runtime do
    @moduledoc false
    def handle(request), do: TransactionalSystemElixirPhoenix.Runtime.CommandService.handle(TransactionalSystemElixirPhoenix.DB, "public", request)
  end
end
