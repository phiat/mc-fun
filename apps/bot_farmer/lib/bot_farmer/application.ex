defmodule BotFarmer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      McFun.BotChat,
      BotFarmer.BotStore,
      {Registry, keys: :unique, name: McFun.BotRegistry},
      {DynamicSupervisor, name: McFun.BotSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: BotFarmer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
