defmodule TransactionalSystemElixirPhoenixWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TransactionalSystemElixirPhoenixWeb.Layouts, :root}
    plug :protect_from_forgery
  end

  scope "/", TransactionalSystemElixirPhoenixWeb do
    pipe_through :browser
    live "/", OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixLive
  end

  scope "/", TransactionalSystemElixirPhoenixWeb do
    pipe_through :api
    get "/health", OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixController, :health
    post "/api/v1/orquestacion-de-saga-con-gen-server-y-pattern-matching-en-elixir-phoenix/:id/:command", OrquestacionDeSagaConGenServerYPatternMatchingEnElixirPhoenixController, :execute
  end
end
