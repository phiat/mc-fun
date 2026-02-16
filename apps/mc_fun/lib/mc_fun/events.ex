defmodule McFun.Events do
  @moduledoc """
  Event hub for Minecraft server events.

  Wraps Phoenix.PubSub to provide typed event dispatch and subscription.
  Events broadcast to both type-specific topics and an `:all` topic.

  ## Event types

  - `:player_join` — player joined the server
  - `:player_leave` — player left the server
  - `:player_death` — player died
  - `:player_chat` — player sent a chat message
  - `:player_advancement` — player earned an advancement
  - `:server_started` — server finished starting
  - `:webhook_received` — external webhook received
  - `:custom` — user-defined event

  ## Usage

      McFun.Events.subscribe(:player_join)
      McFun.Events.dispatch(:player_join, %{username: "Steve"})
      # Process receives: {:mc_event, :player_join, %{username: "Steve"}}

      # Callback-based subscription (spawns handler process)
      McFun.Events.subscribe(:player_join, fn _type, data ->
        IO.inspect(data)
      end)
  """

  alias McFun.Events.CallbackHandler

  require Logger

  @type event_type ::
          :player_join
          | :player_leave
          | :player_death
          | :player_chat
          | :player_advancement
          | :server_started
          | :webhook_received
          | :custom

  @event_types [
    :player_join,
    :player_leave,
    :player_death,
    :player_chat,
    :player_advancement,
    :server_started,
    :webhook_received,
    :custom
  ]

  @spec event_types() :: [event_type()]
  def event_types, do: @event_types

  @doc "Dispatch an event to all subscribers of the given type and the `:all` topic."
  @spec dispatch(event_type(), map()) :: :ok | {:error, term()}
  def dispatch(event_type, data \\ %{}) when event_type in @event_types do
    message = {:mc_event, event_type, data}

    with :ok <- Phoenix.PubSub.broadcast(McFun.PubSub, "mc_events:#{event_type}", message),
         :ok <- Phoenix.PubSub.broadcast(McFun.PubSub, "mc_events:all", message) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to dispatch event #{event_type}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Subscribe the calling process to events of the given type.

  Use `:all` to receive every event type.
  Messages arrive as `{:mc_event, event_type, data}`.
  """
  @spec subscribe(event_type() | :all) :: :ok | {:error, term()}
  def subscribe(event_type) when event_type in @event_types or event_type == :all do
    Phoenix.PubSub.subscribe(McFun.PubSub, "mc_events:#{event_type}")
  end

  @doc """
  Subscribe with a callback function. Spawns a handler process that
  invokes `callback.(event_type, data)` for each event.

  Returns `{:ok, pid}` of the handler.
  """
  @spec subscribe(event_type() | :all, (event_type(), map() -> any())) ::
          {:ok, pid()} | {:error, term()}
  def subscribe(event_type, callback)
      when (event_type in @event_types or event_type == :all) and is_function(callback, 2) do
    CallbackHandler.start_link(
      event_type: event_type,
      callback: callback
    )
  end
end
