# language: es
Característica: Orquestación de Saga con GenServer y Pattern Matching en Elixir Phoenix

  Escenario: Procesamiento de Evento de Pedido con Ecto.Multi y LiveView Update
    Dado que un usuario realiza una acción en Phoenix LiveView enviando `phx-submit="create_order"`
    Cuando el GenServer de la Saga recibe el comando y ejecuta `Ecto.Multi.new()`
    Entonces el pedido y el evento Outbox son insertados atómicamente en PostgreSQL
    Y Phoenix PubSub transmite el evento `{:order_created, order}` al proceso de LiveView
    Y la prueba `mix test` verifica la ejecución sin errores de Pattern Matching o GenServer exit
