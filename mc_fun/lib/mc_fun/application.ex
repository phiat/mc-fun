defmodule McFun.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias McFun.Events.Handlers

  @impl true
  def start(_type, _args) do
    children = [
      McFunWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:mc_fun, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: McFun.PubSub},
      McFun.Rcon,
      McFun.Redstone.CircuitRegistry,
      McFun.LLM.ModelCache,
      McFun.EventStore,
      McFun.LogWatcher,
      {Registry, keys: :unique, name: McFun.BotRegistry},
      {DynamicSupervisor, name: McFun.BotSupervisor, strategy: :one_for_one},
      # Start to serve requests, typically the last entry
      McFunWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: McFun.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register default event handlers after supervision tree is up
    Handlers.register_all()

    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    McFunWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
