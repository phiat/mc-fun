defmodule McFun.Bot do
  @moduledoc """
  GenServer that manages a mineflayer bot via an Erlang Port.
  Communicates with the Node.js bridge over stdin/stdout using newline-delimited JSON.
  """
  use GenServer
  require Logger

  defstruct [
    :name,
    :port,
    :listeners,
    :position,
    :health,
    :food,
    :dimension,
    :current_action,
    inventory: [],
    timers: []
  ]

  # Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def send_command(bot_name, command) when is_map(command) do
    GenServer.call(via(bot_name), {:command, command})
  end

  @doc "Send a command with source tracking (:tool or :behavior)."
  def send_command(bot_name, command, opts) when is_map(command) and is_list(opts) do
    GenServer.call(via(bot_name), {:command, command, opts})
  end

  @doc "Get the current active action (nil if idle)."
  def current_action(bot_name) do
    GenServer.call(via(bot_name), :current_action)
  catch
    :exit, _ -> nil
  end

  @doc "Stop the current action and clear action state."
  def stop_action(bot_name) do
    GenServer.call(via(bot_name), :stop_action)
  catch
    :exit, _ -> {:error, :not_found}
  end

  def chat(bot_name, message) do
    send_command(bot_name, %{action: "chat", message: message})
  end

  def whisper(bot_name, target, message) do
    send_command(bot_name, %{action: "whisper", target: target, message: message})
  end

  def position(bot_name) do
    send_command(bot_name, %{action: "position"})
  end

  def inventory(bot_name) do
    send_command(bot_name, %{action: "inventory"})
  end

  def players(bot_name) do
    send_command(bot_name, %{action: "players"})
  end

  def quit(bot_name) do
    send_command(bot_name, %{action: "quit"})
  end

  @doc "Returns the bot's current status: position, health, food, dimension."
  def status(bot_name) do
    GenServer.call(via(bot_name), :status)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Dig a block at the given coordinates."
  def dig(bot_name, x, y, z) do
    send_command(bot_name, %{action: "dig", x: x, y: y, z: z})
  end

  @doc "Place a block against the reference block at {x, y, z} on the given face."
  def place(bot_name, x, y, z, face \\ "top") do
    send_command(bot_name, %{action: "place", x: x, y: y, z: z, face: face})
  end

  @doc "Equip an item by name to the given destination (hand, head, torso, legs, feet, off-hand)."
  def equip(bot_name, item_name, destination \\ "hand") do
    send_command(bot_name, %{action: "equip", item_name: item_name, destination: destination})
  end

  @doc "Craft an item by name. Requires ingredients in inventory."
  def craft(bot_name, item_name, count \\ 1) do
    send_command(bot_name, %{action: "craft", item_name: item_name, count: count})
  end

  @doc "Drop the currently held item stack."
  def drop(bot_name) do
    send_command(bot_name, %{action: "drop"})
  end

  @doc "Activate a block (buttons, levers, chests, doors) at the given coordinates."
  def activate_block(bot_name, x, y, z) do
    send_command(bot_name, %{action: "activate_block", x: x, y: y, z: z})
  end

  @doc "Use the currently held item (eat food, throw, etc.)."
  def use_item(bot_name) do
    send_command(bot_name, %{action: "use_item"})
  end

  @doc "Stop using the currently held item."
  def deactivate_item(bot_name) do
    send_command(bot_name, %{action: "deactivate_item"})
  end

  @doc "Sleep in a nearby bed (within 4 blocks)."
  def sleep(bot_name) do
    send_command(bot_name, %{action: "sleep"})
  end

  @doc "Wake up from a bed."
  def wake(bot_name) do
    send_command(bot_name, %{action: "wake"})
  end

  @doc "Get bridge-side bot status (pathfinder, queue, digging state)."
  def bot_status(bot_name) do
    send_command(bot_name, %{action: "status"})
  end

  @doc "Teleport bot to a player via RCON."
  def teleport_to(bot_name, player) do
    McFun.Rcon.command("tp #{bot_name} #{player}")
  end

  @doc "Get a survey of the bot's surroundings (blocks, inventory, entities)."
  def survey(bot_name) do
    GenServer.call(via(bot_name), {:survey}, 10_000)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Find and dig the nearest block of a given type."
  def find_and_dig(bot_name, block_type) do
    send_command(bot_name, %{action: "find_and_dig", block_type: block_type})
  end

  @doc "Dig a rectangular area. Args: width, height, depth (uses bot's current position as origin)."
  def dig_area(bot_name, args, opts \\ []) when is_map(args) do
    # Get bot's current position for the origin
    case status(bot_name) do
      %{position: {x, y, z}} when is_number(x) ->
        cmd = %{
          action: "dig_area",
          x: trunc(x),
          y: trunc(y),
          z: trunc(z),
          width: args["width"] || 5,
          height: args["height"] || 3,
          depth: args["depth"] || 5
        }

        if opts == [] do
          send_command(bot_name, cmd)
        else
          send_command(bot_name, cmd, opts)
        end

      _ ->
        Logger.warning("Bot #{bot_name}: can't dig_area, no position")
    end
  end

  @doc "Subscribe the calling process to events from this bot."
  def subscribe(bot_name) do
    Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot_name}")
  end

  defp via(name), do: {:via, Registry, {McFun.BotRegistry, name}}

  # GenServer callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Application.get_env(:mc_fun, :minecraft, [])
    host = Keyword.get(opts, :host, Keyword.get(config, :host, "localhost"))
    port_num = Keyword.get(opts, :port, Keyword.get(config, :port, 25_565))

    bridge_path = Path.join(:code.priv_dir(:mc_fun), "mineflayer/bridge.js")

    # Merge with existing env so Node.js keeps PATH, NODE_PATH, etc.
    base_env =
      System.get_env()
      |> Map.merge(%{
        "MC_HOST" => host,
        "MC_PORT" => to_string(port_num),
        "BOT_USERNAME" => name
      })
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("node")},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, [bridge_path]},
          {:env, base_env},
          {:cd, to_charlist(Path.dirname(bridge_path))},
          {:line, 16_384}
        ]
      )

    Logger.info("Bot #{name} starting, bridge port opened")

    # Poll position every 3 seconds, inventory every 5 seconds (port commands, no RCON cost)
    {:ok, pos_timer} = :timer.send_interval(3_000, self(), :poll_position)
    {:ok, inv_timer} = :timer.send_interval(5_000, self(), :poll_inventory)

    {:ok, %__MODULE__{name: name, port: port, listeners: [], timers: [pos_timer, inv_timer]}}
  end

  @impl true
  def handle_call({:command, command}, _from, state) do
    if state.port && Port.info(state.port) do
      json = Jason.encode!(command) <> "\n"
      Port.command(state.port, json)
      {:reply, :ok, state}
    else
      Logger.warning("Bot #{state.name}: port dead, can't send command")
      {:reply, {:error, :port_dead}, state}
    end
  end

  @impl true
  def handle_call({:command, command, opts}, _from, state) do
    source = Keyword.get(opts, :source, :unknown)
    {:reply, :ok, send_sourced_command(state, command, source)}
  end

  @impl true
  def handle_call(:current_action, _from, state) do
    {:reply, state.current_action, state}
  end

  @impl true
  def handle_call(:stop_action, _from, state) do
    if state.port && Port.info(state.port) do
      json = Jason.encode!(%{action: "stop"}) <> "\n"
      Port.command(state.port, json)
      {:reply, :ok, clear_action(state)}
    else
      {:reply, {:error, :port_dead}, state}
    end
  end

  @impl true
  def handle_call({:survey}, from, state) do
    if state.port && Port.info(state.port) do
      json = Jason.encode!(%{action: "survey"}) <> "\n"
      Port.command(state.port, json)
      {:noreply, %{state | listeners: [{:survey, from} | state.listeners]}}
    else
      {:reply, {:error, :port_dead}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       position: state.position,
       health: state.health,
       food: state.food,
       dimension: state.dimension,
       inventory: state.inventory
     }, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"event" => "survey"} = event} ->
        # Reply to waiting survey caller
        {survey_listeners, rest} =
          Enum.split_with(state.listeners, fn {type, _} -> type == :survey end)

        for {:survey, from} <- survey_listeners do
          GenServer.reply(from, {:ok, event})
        end

        {:noreply, %{state | listeners: rest}}

      {:ok, event} ->
        broadcast(state.name, event)
        {:noreply, update_state_from_event(state, event)}

      {:error, _} ->
        Logger.debug("Bot #{state.name}: #{line}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:poll_position, state) do
    if Port.info(state.port) do
      json = Jason.encode!(%{action: "position"}) <> "\n"
      Port.command(state.port, json)
      {:noreply, state}
    else
      Logger.warning("Bot #{state.name} port is dead, stopping GenServer")
      {:stop, :port_dead, state}
    end
  end

  @impl true
  def handle_info(:poll_inventory, state) do
    if Port.info(state.port) do
      json = Jason.encode!(%{action: "inventory"}) <> "\n"
      Port.command(state.port, json)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, _partial}}}, %{port: port} = state) do
    # partial line, ignore (will come as eol eventually)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("Bot #{state.name} bridge exited with status #{status}")
    {:stop, {:bridge_exit, status}, %{state | port: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    for timer <- state.timers, do: :timer.cancel(timer)
    if state.port && Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp update_state_from_event(state, %{"event" => "spawn", "position" => pos} = event) do
    dimension = Map.get(event, "dimension")
    %{state | position: {pos["x"], pos["y"], pos["z"]}, dimension: format_dimension(dimension)}
  end

  defp update_state_from_event(state, %{"event" => "health", "health" => health, "food" => food}) do
    %{state | health: health, food: food}
  end

  defp update_state_from_event(state, %{"event" => "inventory", "items" => items})
       when is_list(items) do
    %{state | inventory: items}
  end

  defp update_state_from_event(state, %{"event" => "position"} = event) do
    dimension = Map.get(event, "dimension")
    new_state = %{state | position: {event["x"], event["y"], event["z"]}}
    if dimension, do: %{new_state | dimension: format_dimension(dimension)}, else: new_state
  end

  # Action completion events — clear current_action
  defp update_state_from_event(state, %{"event" => event})
       when event in [
              "goto_done",
              "dig_done",
              "dig_area_done",
              "dig_area_cancelled",
              "find_and_dig_done",
              "stopped"
            ] do
    Logger.info("Bot #{state.name}: action completed (#{event})")
    broadcast_action_change(state.name, nil)
    clear_action(state)
  end

  defp update_state_from_event(state, %{"event" => event})
       when event in ["find_and_dig_error"] do
    Logger.warning("Bot #{state.name}: action error (#{event})")
    broadcast_action_change(state.name, nil)
    clear_action(state)
  end

  defp update_state_from_event(state, %{"event" => "disconnected", "reason" => reason}) do
    Logger.warning("Bot #{state.name}: disconnected (#{reason}), waiting for reconnect...")
    state
  end

  defp update_state_from_event(state, %{"event" => "reconnecting", "attempt" => attempt}) do
    Logger.info("Bot #{state.name}: reconnect attempt #{attempt}")
    state
  end

  defp update_state_from_event(state, _event), do: state

  defp format_dimension(nil), do: nil

  defp format_dimension(dim) when is_binary(dim) do
    dim
    |> String.replace("minecraft:", "")
    |> String.replace("the_", "")
  end

  defp format_dimension(_), do: nil

  defp send_sourced_command(state, command, :behavior) when state.current_action != nil do
    if state.current_action.source == :tool, do: state, else: do_send(state, command, :behavior)
  end

  defp send_sourced_command(state, command, source) do
    do_send(state, command, source)
  end

  defp do_send(state, command, source) do
    if state.port && Port.info(state.port) do
      json = Jason.encode!(command) <> "\n"
      Port.command(state.port, json)
      if source == :tool, do: set_action(state, action_atom(command), source), else: state
    else
      Logger.warning("Bot #{state.name}: port dead, can't send command")
      state
    end
  end

  defp broadcast(bot_name, event) do
    Phoenix.PubSub.broadcast(McFun.PubSub, "bot:#{bot_name}", {:bot_event, bot_name, event})
  end

  defp broadcast_action_change(bot_name, action) do
    Phoenix.PubSub.broadcast(
      McFun.PubSub,
      "bot:#{bot_name}",
      {:bot_event, bot_name, %{"event" => "action_change", "action" => action}}
    )
  end

  defp set_action(state, action_name, source) do
    action = %{action: action_name, source: source, started_at: DateTime.utc_now()}
    broadcast_action_change(state.name, action)
    %{state | current_action: action}
  end

  defp clear_action(state), do: %{state | current_action: nil}

  defp action_atom(%{action: action}) when is_binary(action), do: String.to_atom(action)
  defp action_atom(%{"action" => action}) when is_binary(action), do: String.to_atom(action)
  defp action_atom(_), do: :unknown
end
