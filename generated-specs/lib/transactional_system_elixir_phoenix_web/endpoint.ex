defmodule TransactionalSystemElixirPhoenixWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :transactional_system_elixir_phoenix

  @session_options [store: :cookie, key: "_transactional_system_elixir_phoenix_key", signing_salt: "session-salt", same_site: "Lax"]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Phoenix.json_library()
  plug Plug.Session, @session_options
  plug TransactionalSystemElixirPhoenixWeb.Router
end
