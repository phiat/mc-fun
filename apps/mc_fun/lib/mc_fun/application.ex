defmodule McFun.Application do
  @moduledoc false

  use Application

  alias McFun.Events.Handlers

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: McFun.PubSub},
      McFun.Rcon,
      McFun.Redstone.CircuitRegistry,
      McFun.LLM.ModelCache,
      McFun.EventStore,
      McFun.LogWatcher,
      {Registry, keys: :unique, name: McFun.BotRegistry},
      {DynamicSupervisor, name: McFun.BotSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: McFun.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register default event handlers after supervision tree is up
    Handlers.register_all()

    result
  end
end
