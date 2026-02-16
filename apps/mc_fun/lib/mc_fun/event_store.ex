defmodule McFun.EventStore do
  @moduledoc """
  In-memory event store. Keeps the last N events so they survive
  LiveView reconnects / page reloads.
  """
  use GenServer

  @max_events 200

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def push(event) do
    GenServer.cast(__MODULE__, {:push, event})
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  # GenServer

  @impl true
  def init(_), do: {:ok, []}

  @impl true
  def handle_cast({:push, event}, events) do
    {:noreply, [event | Enum.take(events, @max_events - 1)]}
  end

  @impl true
  def handle_call(:list, _from, events) do
    {:reply, events, events}
  end
end
