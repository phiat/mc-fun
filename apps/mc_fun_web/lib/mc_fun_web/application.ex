defmodule McFunWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      McFunWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:mc_fun, :dns_cluster_query) || :ignore},
      McFunWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: McFunWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    McFunWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
