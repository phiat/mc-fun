defmodule McFun.BotBehaviors do
  @moduledoc """
  Behavior modules for mineflayer bots: patrol, follow, guard, mine.

  Each behavior is a GenServer that controls a bot via McFun.Bot commands
  and listens to bot events for reactive behavior.

  ## Usage

      McFun.BotBehaviors.start_patrol("BotName", [{100, 64, 200}, {110, 64, 210}])
      McFun.BotBehaviors.start_follow("BotName", "PlayerName")
      McFun.BotBehaviors.start_guard("BotName", {100, 64, 200}, radius: 10)
      McFun.BotBehaviors.start_mine("BotName", "iron_ore", max_count: 64)
      McFun.BotBehaviors.stop("BotName")
  """
  use GenServer, restart: :temporary
  require Logger

  @tick_interval 1_000
  @follow_distance 3
  @guard_radius 8
  @mine_max_distance 32
  @stop_poll_attempts 10
  @stop_poll_interval 20

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

  @doc "Start mining: bot finds and digs blocks of the given type."
  def start_mine(bot_name, block_type, opts \\ []) when is_binary(block_type) do
    max_distance = Keyword.get(opts, :max_distance, @mine_max_distance)
    max_count = Keyword.get(opts, :max_count, :infinity)

    start_behavior(bot_name,
      bot_name: bot_name,
      behavior: :mine,
      params: %{
        block_type: block_type,
        max_distance: max_distance,
        max_count: max_count,
        mined: 0
      }
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
        # Race condition: stop and poll until Registry clears
        stop(bot_name)
        await_stopped(bot_name)
        DynamicSupervisor.start_child(McFun.BotSupervisor, {__MODULE__, opts})

      error ->
        error
    end
  end

  defp via(bot_name), do: {:via, Registry, {McFun.BotRegistry, {:behavior, bot_name}}}

  defp await_stopped(bot_name, attempt \\ 0)
  defp await_stopped(_bot_name, @stop_poll_attempts), do: :ok

  defp await_stopped(bot_name, attempt) do
    case Registry.lookup(McFun.BotRegistry, {:behavior, bot_name}) do
      [] ->
        :ok

      _ ->
        Process.sleep(@stop_poll_interval)
        await_stopped(bot_name, attempt + 1)
    end
  end

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
    case McFun.Bot.current_action(state.bot_name) do
      %{source: :tool} ->
        # Tool action active — skip this tick, don't interfere
        schedule_tick()
        {:noreply, state}

      _ ->
        state = execute_behavior(state)
        schedule_tick()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:bot_event, _bot_name, %{"event" => "find_and_dig_done"}},
        %{behavior: :mine} = state
      ) do
    mined = state.params.mined + 1
    {:noreply, put_in(state.params.mined, mined)}
  end

  @impl true
  def handle_info({:bot_event, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:stop_self, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Behavior execution

  defp execute_behavior(%{behavior: :patrol} = state) do
    waypoints = state.params.waypoints
    {x, y, z} = Enum.at(waypoints, state.current_index)

    McFun.Bot.send_command(
      state.bot_name,
      %{action: "goto", x: x, y: y, z: z},
      source: :behavior
    )

    next_index = rem(state.current_index + 1, length(waypoints))
    %{state | current_index: next_index}
  end

  defp execute_behavior(%{behavior: :follow} = state) do
    target = state.params.target

    McFun.Bot.send_command(
      state.bot_name,
      %{action: "follow", target: target, distance: @follow_distance},
      source: :behavior
    )

    state
  end

  defp execute_behavior(%{behavior: :guard} = state) do
    {gx, gy, gz} = state.params.position

    McFun.Bot.send_command(
      state.bot_name,
      %{action: "goto", x: gx, y: gy, z: gz},
      source: :behavior
    )

    state
  end

  defp execute_behavior(%{behavior: :mine} = state) do
    %{block_type: block_type, max_distance: max_distance, max_count: max_count, mined: mined} =
      state.params

    if max_count != :infinity and mined >= max_count do
      Logger.info("Mine behavior complete for #{state.bot_name}: mined #{mined}/#{max_count}")
      McFun.Bot.chat(state.bot_name, "Mining complete! Mined #{mined} blocks.")
      # Stop self — DynamicSupervisor will clean up
      send(self(), :stop_self)
      state
    else
      McFun.Bot.send_command(
        state.bot_name,
        %{action: "find_and_dig", block_type: block_type, max_distance: max_distance},
        source: :behavior
      )

      state
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval)
  end

  defp sanitize_params(%{alerted: _} = params), do: Map.delete(params, :alerted)
  defp sanitize_params(params), do: params
end
