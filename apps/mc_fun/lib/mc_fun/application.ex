defmodule McFun.Application do
  @moduledoc false

  use Application

  alias McFun.Events.Handlers

  @impl true
  def start(_type, _args) do
    :logger.add_handler(:sentry_handler, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    children = [
      {Phoenix.PubSub, name: McFun.PubSub},
      McFun.Rcon.Supervisor,
      McFun.World.Redstone.CircuitRegistry,
      McFun.LLM.ModelCache,
      McFun.CostTracker,
      McFun.ChatLog,
      McFun.EventStore,
      McFun.LogWatcher
    ]

    opts = [strategy: :one_for_one, name: McFun.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register default event handlers after supervision tree is up
    Handlers.register_all()

    result
  end
end
