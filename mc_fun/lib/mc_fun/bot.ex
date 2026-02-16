defmodule McFun.Bot do
  @moduledoc """
  GenServer that manages a mineflayer bot via an Erlang Port.
  Communicates with the Node.js bridge over stdin/stdout using newline-delimited JSON.
  """
  use GenServer
  require Logger

  defstruct [:name, :port, :listeners, :position, :health, :food, :dimension]

  # Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def send_command(bot_name, command) when is_map(command) do
    GenServer.call(via(bot_name), {:command, command})
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
    :exit, _ -> %{position: nil, health: nil, food: nil, dimension: nil}
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

  @doc "Teleport bot to a player via RCON."
  def teleport_to(bot_name, player) do
    McFun.Rcon.command("tp #{bot_name} #{player}")
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
    port_num = Keyword.get(opts, :port, Keyword.get(config, :port, 25565))

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

    # Poll position every 5 seconds
    :timer.send_interval(5_000, self(), :poll_position)

    {:ok, %__MODULE__{name: name, port: port, listeners: []}}
  end

  @impl true
  def handle_call({:command, command}, _from, state) do
    json = Jason.encode!(command) <> "\n"
    Port.command(state.port, json)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       position: state.position,
       health: state.health,
       food: state.food,
       dimension: state.dimension
     }, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
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
    try do
      json = Jason.encode!(%{action: "position"}) <> "\n"
      Port.command(state.port, json)
    rescue
      _ -> :ok
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
    {:stop, {:bridge_exit, status}, state}
  end

  defp update_state_from_event(state, %{"event" => "spawn", "position" => pos} = event) do
    dimension = Map.get(event, "dimension")
    %{state |
      position: {pos["x"], pos["y"], pos["z"]},
      dimension: format_dimension(dimension)
    }
  end

  defp update_state_from_event(state, %{"event" => "health", "health" => health, "food" => food}) do
    %{state | health: health, food: food}
  end

  defp update_state_from_event(state, %{"event" => "position"} = event) do
    dimension = Map.get(event, "dimension")
    new_state = %{state | position: {event["x"], event["y"], event["z"]}}
    if dimension, do: %{new_state | dimension: format_dimension(dimension)}, else: new_state
  end

  defp update_state_from_event(state, _event), do: state

  defp format_dimension(nil), do: nil
  defp format_dimension(dim) when is_binary(dim) do
    dim
    |> String.replace("minecraft:", "")
    |> String.replace("the_", "")
  end
  defp format_dimension(_), do: nil

  defp broadcast(bot_name, event) do
    Phoenix.PubSub.broadcast(McFun.PubSub, "bot:#{bot_name}", {:bot_event, bot_name, event})
  end
end
