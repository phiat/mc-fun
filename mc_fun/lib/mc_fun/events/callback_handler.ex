defmodule McFun.Events.CallbackHandler do
  @moduledoc """
  GenServer that subscribes to an event topic and invokes a callback
  for each received event. Started by `McFun.Events.subscribe/2`.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    event_type = Keyword.fetch!(opts, :event_type)
    callback = Keyword.fetch!(opts, :callback)

    Phoenix.PubSub.subscribe(McFun.PubSub, "mc_events:#{event_type}")

    {:ok, %{event_type: event_type, callback: callback}}
  end

  @impl true
  def handle_info({:mc_event, event_type, data}, state) do
    try do
      state.callback.(event_type, data)
    rescue
      e ->
        Logger.warning(
          "Event callback error for #{event_type}: #{Exception.message(e)}"
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
