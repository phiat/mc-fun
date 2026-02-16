defmodule McFun.BotBehaviors do
  @moduledoc """
  Behavior modules for mineflayer bots: patrol, follow, guard.

  Each behavior is a GenServer that controls a bot via McFun.Bot commands
  and listens to bot events for reactive behavior.

  ## Usage

      McFun.BotBehaviors.start_patrol("BotName", [{100, 64, 200}, {110, 64, 210}])
      McFun.BotBehaviors.start_follow("BotName", "PlayerName")
      McFun.BotBehaviors.start_guard("BotName", {100, 64, 200}, radius: 10)
      McFun.BotBehaviors.stop("BotName")
  """
  use GenServer
  require Logger

  @tick_interval 1_000
  @follow_distance 3
  @guard_radius 8

  defstruct [
    :bot_name,
    :behavior,
    :params,
    :current_index
  ]

  # Client API

  def start_link(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    GenServer.start_link(__MODULE__, opts, name: via(bot_name))
  end

  @doc "Start a patrol route: bot walks between waypoints in a loop."
  def start_patrol(bot_name, waypoints) when is_list(waypoints) and length(waypoints) >= 2 do
    start_behavior(bot_name,
      bot_name: bot_name,
      behavior: :patrol,
      params: %{waypoints: waypoints}
    )
  end

  @doc "Start following a player: bot moves toward the target player."
  def start_follow(bot_name, target_player) when is_binary(target_player) do
    start_behavior(bot_name,
      bot_name: bot_name,
      behavior: :follow,
      params: %{target: target_player}
    )
  end

  @doc "Start guarding a position: bot stays near a point and alerts on nearby players."
  def start_guard(bot_name, {_x, _y, _z} = pos, opts \\ []) do
    radius = Keyword.get(opts, :radius, @guard_radius)

    start_behavior(bot_name,
      bot_name: bot_name,
      behavior: :guard,
      params: %{position: pos, radius: radius, alerted: MapSet.new()}
    )
  end

  @doc "Stop any active behavior for the bot."
  def stop(bot_name) do
    case Registry.lookup(McFun.BotRegistry, {:behavior, bot_name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(McFun.BotSupervisor, pid)
      [] -> :ok
    end
  end

  @doc "Get the current behavior info."
  def info(bot_name) do
    case Registry.lookup(McFun.BotRegistry, {:behavior, bot_name}) do
      [{_pid, _}] -> GenServer.call(via(bot_name), :info)
      [] -> {:error, :no_behavior}
    end
  end

  defp start_behavior(bot_name, opts) do
    stop(bot_name)

    case DynamicSupervisor.start_child(McFun.BotSupervisor, {__MODULE__, opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        # Race condition: another concurrent start won. Stop that one and retry once.
        stop(bot_name)
        DynamicSupervisor.start_child(McFun.BotSupervisor, {__MODULE__, opts})

      error ->
        error
    end
  end

  defp via(bot_name), do: {:via, Registry, {McFun.BotRegistry, {:behavior, bot_name}}}

  # GenServer callbacks

  @impl true
  def init(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    behavior = Keyword.fetch!(opts, :behavior)
    params = Keyword.fetch!(opts, :params)

    Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot_name}")
    schedule_tick()

    Logger.info("BotBehavior #{behavior} started for #{bot_name}")
    McFun.Bot.chat(bot_name, "Behavior started: #{behavior}")

    {:ok,
     %__MODULE__{
       bot_name: bot_name,
       behavior: behavior,
       params: params,
       current_index: 0
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       bot_name: state.bot_name,
       behavior: state.behavior,
       params: sanitize_params(state.params)
     }, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = execute_behavior(state)
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_info({:bot_event, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Behavior execution

  defp execute_behavior(%{behavior: :patrol} = state) do
    waypoints = state.params.waypoints
    {x, y, z} = Enum.at(waypoints, state.current_index)

    McFun.Bot.send_command(state.bot_name, %{
      action: "goto",
      x: x,
      y: y,
      z: z
    })

    next_index = rem(state.current_index + 1, length(waypoints))
    %{state | current_index: next_index}
  end

  defp execute_behavior(%{behavior: :follow} = state) do
    target = state.params.target

    # Use bot's pathfinder to go to the target player
    McFun.Bot.send_command(state.bot_name, %{
      action: "follow",
      target: target,
      distance: @follow_distance
    })

    state
  end

  defp execute_behavior(%{behavior: :guard} = state) do
    {gx, gy, gz} = state.params.position

    # Move back toward guard position
    McFun.Bot.send_command(state.bot_name, %{
      action: "goto",
      x: gx,
      y: gy,
      z: gz
    })

    state
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp sanitize_params(%{alerted: _} = params), do: Map.delete(params, :alerted)
  defp sanitize_params(params), do: params
end
