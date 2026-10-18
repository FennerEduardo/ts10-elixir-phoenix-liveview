defmodule TransactionalSystemElixirPhoenix.Runtime.Topology do
  @moduledoc "Event bus destinations: publish to exchange (topic), consume from queue (subscription); dead letters go to dlx, read from dlq."
  defstruct exchange: "transactional-system-elixir-phoenix.events", queue: "transactional-system-elixir-phoenix.consumer", dlx: "transactional-system-elixir-phoenix.dlx", dlq: "transactional-system-elixir-phoenix.dlq"

  def for_prefix(prefix), do: %__MODULE__{exchange: "#{prefix}.events", queue: "#{prefix}.consumer", dlx: "#{prefix}.dlx", dlq: "#{prefix}.dlq"}
end
