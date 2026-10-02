defmodule TransactionalSystemElixirPhoenixWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Orquestación de Saga con GenServer y Pattern Matching en Elixir Phoenix</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
