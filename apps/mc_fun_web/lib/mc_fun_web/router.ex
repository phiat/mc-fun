defmodule McFunWeb.Router do
  use McFunWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {McFunWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", McFunWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/dashboard", DashboardLive
  end

  scope "/api", McFunWeb do
    pipe_through :api

    post "/webhooks/:action", WebhookController, :handle
  end
end
