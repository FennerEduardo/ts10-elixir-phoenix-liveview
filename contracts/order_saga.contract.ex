defmodule TransactionalSystem.Contracts.OrderSagaContract do
  @moduledoc """
  Contrato de Dominio para la Saga de Pedidos en Elixir.
  """

  defstruct [
    :order_id,
    :customer_id,
    :total_amount,
    :currency,
    :idempotency_key,
    :status
  ]

  @type t :: %__MODULE__{
          order_id: String.t(),
          customer_id: String.t(),
          total_amount: Decimal.t(),
          currency: String.t(),
          idempotency_key: String.t(),
          status: String.t()
        }

  @callback execute_saga(params :: map()) :: {:ok, t()} | {:error, term()}
  @callback validate_idempotency(key :: String.t()) :: {:ok, boolean()} | {:error, term()}
end
