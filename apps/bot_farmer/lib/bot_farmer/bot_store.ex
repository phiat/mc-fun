defmodule BotFarmer.BotStore do
  @moduledoc """
  Persists bot fleet configuration to disk and auto-deploys on startup.

  Stores each bot's name, model, personality, heartbeat/group_chat toggles,
  and active behavior to `priv/bot_fleet.json`. On startup, loads the manifest
  and re-deploys all saved bots after a short delay (giving RCON time to connect).

  Writes are debounced (3s) to avoid excessive disk I/O during rapid changes.
  """

  use GenServer
  require Logger

  @flush_delay_ms 3_000
  @auto_deploy_delay_ms 3_000
  @deploy_stagger_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Save a bot config to the store."
  def save(name, opts) do
    GenServer.cast(__MODULE__, {:save, name, opts})
  end

  @doc "Remove a bot from the store."
  def remove(name) do
    GenServer.cast(__MODULE__, {:remove, name})
  end

  @doc "Update specific fields for a bot."
  def update(name, updates) do
    GenServer.cast(__MODULE__, {:update, name, updates})
  end

  @doc "Get the current fleet manifest."
  def manifest do
    GenServer.call(__MODULE__, :manifest)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    fleet = load_manifest()
    Logger.info("BotStore loaded #{map_size(fleet)} bot(s) from manifest")

    if map_size(fleet) > 0 do
      Process.send_after(self(), :auto_deploy, @auto_deploy_delay_ms)
    end

    {:ok, %{fleet: fleet, flush_ref: nil}}
  end

  @impl true
  def handle_call(:manifest, _from, state) do
    {:reply, state.fleet, state}
  end

  @impl true
  def handle_cast({:save, name, opts}, state) do
    entry = %{
      "name" => name,
      "model" => Keyword.get(opts, :model),
      "personality" => Keyword.get(opts, :personality),
      "heartbeat_enabled" => Keyword.get(opts, :heartbeat_enabled, true),
      "group_chat_enabled" => Keyword.get(opts, :group_chat_enabled, true),
      "behavior" => nil
    }

    fleet = Map.put(state.fleet, name, entry)
    {:noreply, schedule_flush(%{state | fleet: fleet})}
  end

  @impl true
  def handle_cast({:remove, name}, state) do
    fleet = Map.delete(state.fleet, name)
    {:noreply, schedule_flush(%{state | fleet: fleet})}
  end

  @impl true
  def handle_cast({:update, name, updates}, state) do
    case Map.get(state.fleet, name) do
      nil ->
        {:noreply, state}

      entry ->
        entry =
          Enum.reduce(updates, entry, fn
            {:model, v}, acc -> Map.put(acc, "model", v)
            {:personality, v}, acc -> Map.put(acc, "personality", v)
            {:heartbeat_enabled, v}, acc -> Map.put(acc, "heartbeat_enabled", v)
            {:group_chat_enabled, v}, acc -> Map.put(acc, "group_chat_enabled", v)
            {:behavior, v}, acc -> Map.put(acc, "behavior", encode_behavior(v))
            _, acc -> acc
          end)

        fleet = Map.put(state.fleet, name, entry)
        {:noreply, schedule_flush(%{state | fleet: fleet})}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    write_manifest(state.fleet)
    {:noreply, %{state | flush_ref: nil}}
  end

  @impl true
  def handle_info(:auto_deploy, state) do
    Logger.info("BotStore: auto-deploying #{map_size(state.fleet)} bot(s)...")

    state.fleet
    |> Map.values()
    |> Enum.with_index()
    |> Enum.each(fn {entry, idx} ->
      delay = idx * @deploy_stagger_ms
      Process.send_after(self(), {:deploy_one, entry}, delay)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:deploy_one, entry}, state) do
    name = entry["name"]
    Logger.info("BotStore: deploying #{name}")

    try do
      case McFun.BotSupervisor.spawn_bot(name) do
        {:ok, _pid} ->
          # Attach chatbot after bot connects
          Process.send_after(self(), {:attach_chatbot, entry}, 2_000)

        {:error, {:already_started, _}} ->
          Logger.info("BotStore: #{name} already running")

        {:error, reason} ->
          Logger.warning("BotStore: failed to deploy #{name}: #{inspect(reason)}")
      end
    rescue
      e -> Logger.warning("BotStore: deploy error for #{name}: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:attach_chatbot, entry}, state) do
    name = entry["name"]

    opts =
      [bot_name: name]
      |> maybe_put(:model, entry["model"])
      |> maybe_put(:personality, entry["personality"])

    try do
      BotFarmer.attach_chatbot(name, opts)

      if entry["heartbeat_enabled"] == false do
        McFun.ChatBot.toggle_heartbeat(name, false)
      end

      if entry["group_chat_enabled"] == false do
        McFun.ChatBot.toggle_group_chat(name, false)
      end

      # Restore behavior
      restore_behavior(name, entry["behavior"])
    rescue
      e -> Logger.warning("BotStore: chatbot attach error for #{name}: #{Exception.message(e)}")
    catch
      _, reason ->
        Logger.warning("BotStore: chatbot attach error for #{name}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Internal

  defp schedule_flush(state) do
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)
    ref = Process.send_after(self(), :flush, @flush_delay_ms)
    %{state | flush_ref: ref}
  end

  defp manifest_path do
    Path.join(:code.priv_dir(:bot_farmer), "bot_fleet.json")
  end

  defp load_manifest do
    manifest_path()
    |> File.read()
    |> parse_manifest()
  end

  defp parse_manifest({:ok, json}) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Map.new(list, fn entry -> {entry["name"], entry} end)

      {:ok, map} when is_map(map) ->
        map

      _ ->
        Logger.warning("BotStore: invalid manifest format, starting fresh")
        %{}
    end
  end

  defp parse_manifest({:error, :enoent}), do: %{}

  defp parse_manifest({:error, reason}) do
    Logger.warning("BotStore: failed to read manifest: #{inspect(reason)}")
    %{}
  end

  defp write_manifest(fleet) do
    path = manifest_path()
    File.mkdir_p!(Path.dirname(path))
    entries = Map.values(fleet)
    json = Jason.encode!(entries, pretty: true)
    File.write!(path, json)
    Logger.debug("BotStore: wrote #{length(entries)} bot(s) to #{path}")
  end

  defp encode_behavior(nil), do: nil

  defp encode_behavior(%{type: type, params: params}) do
    %{"type" => to_string(type), "params" => encode_params(params)}
  end

  defp encode_behavior(_), do: nil

  defp encode_params(%{waypoints: waypoints}) when is_list(waypoints) do
    %{
      "waypoints" =>
        Enum.map(waypoints, fn
          {x, y, z} -> [x, y, z]
          [_, _, _] = list -> list
        end)
    }
  end

  defp encode_params(%{position: {x, y, z}} = params) do
    params
    |> Map.delete(:position)
    |> Map.put(:x, x)
    |> Map.put(:y, y)
    |> Map.put(:z, z)
    |> encode_map_params()
  end

  defp encode_params(params) when is_map(params), do: encode_map_params(params)
  defp encode_params(_), do: %{}

  defp encode_map_params(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end

  defp restore_behavior(_name, nil), do: :ok

  defp restore_behavior(name, %{"type" => "patrol", "params" => %{"waypoints" => wps}}) do
    tuples = Enum.map(wps, fn [x, y, z] -> {x, y, z} end)

    if length(tuples) >= 2 do
      McFun.BotBehaviors.start_patrol(name, tuples)
    end
  end

  defp restore_behavior(name, %{"type" => "follow", "params" => %{"target" => target}}) do
    McFun.BotBehaviors.start_follow(name, target)
  end

  defp restore_behavior(name, %{
         "type" => "guard",
         "params" => %{"x" => x, "y" => y, "z" => z} = params
       }) do
    radius = params["radius"] || 8
    McFun.BotBehaviors.start_guard(name, {x, y, z}, radius: radius)
  end

  defp restore_behavior(name, %{
         "type" => "mine",
         "params" => %{"block_type" => block_type} = params
       }) do
    opts = [max_distance: params["max_distance"] || 32]

    opts =
      case params["max_count"] do
        nil -> opts
        :infinity -> opts
        "infinity" -> opts
        n when is_integer(n) -> Keyword.put(opts, :max_count, n)
        _ -> opts
      end

    McFun.BotBehaviors.start_mine(name, block_type, opts)
  end

  defp restore_behavior(_name, _), do: :ok

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
