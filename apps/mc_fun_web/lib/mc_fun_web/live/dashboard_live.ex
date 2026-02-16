defmodule McFunWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for MC Fun — bot management, RCON console,
  effects panel, event log, and display tools.

  Tab content is delegated to LiveComponents:
  - UnitsPanelLive, RconConsoleLive, EventStreamLive,
    EffectsPanelLive, DisplayPanelLive, BotConfigModalLive
  """
  use McFunWeb, :live_view

  alias McFun.LLM.ModelCache

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      McFun.Events.subscribe(:all)

      for bot <- list_bots() do
        Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
      end

      Phoenix.PubSub.subscribe(McFun.PubSub, "player_statuses")
      Phoenix.PubSub.subscribe(McFun.PubSub, "costs")
      :timer.send_interval(3_000, self(), :refresh_status)
    end

    models = safe_model_ids()

    socket =
      socket
      |> assign(
        page_title: "MC Fun",
        rcon_history: [],
        bots: list_bots(),
        bot_statuses: build_bot_statuses(),
        available_models: models,
        events: McFun.EventStore.list(),
        effect_target: "@a",
        display_x: "0",
        display_y: "80",
        display_z: "0",
        online_players: [],
        player_statuses: %{},
        rcon_status: check_rcon(),
        active_tab: "bots",
        sidebar_open: true,
        cost_summary: McFun.CostTracker.get_global_cost(),
        server_health: server_health(),
        # Bot config modal
        selected_bot: nil,
        modal_tab: "llm"
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> clear_flash() |> assign(active_tab: tab)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  # --- Bot Config Modal ---

  def handle_event("open_bot_config", %{"bot" => bot}, socket) do
    {:noreply, assign(socket, selected_bot: bot, modal_tab: "llm")}
  end

  def handle_event("close_bot_config", _params, socket) do
    {:noreply, assign(socket, selected_bot: nil)}
  end

  # --- Nav Bar Actions ---

  def handle_event("stop_all_bots", _params, socket) do
    for bot <- socket.assigns.bots do
      stop_chatbot(bot)
      McFun.BotSupervisor.stop_bot(bot)
    end

    Process.send_after(self(), :refresh_bots, 200)
    {:noreply, assign(socket, bots: [], bot_statuses: %{})}
  end

  # --- Coord Sharing ---

  def handle_event("use_coords", %{"x" => x, "y" => y, "z" => z, "name" => name}, socket) do
    send_update(McFunWeb.EffectsPanelLive, id: "effects-panel", effect_target: name)

    {:noreply,
     assign(socket,
       display_x: x,
       display_y: y,
       display_z: z,
       effect_target: name
     )}
  end

  # --- Handles ---

  @impl true
  def handle_info(:refresh_bots, socket) do
    {:noreply, assign(socket, bots: list_bots(), bot_statuses: build_bot_statuses())}
  end

  @impl true
  def handle_info(:refresh_bot_statuses, socket) do
    {:noreply, assign(socket, bot_statuses: build_bot_statuses())}
  end

  @impl true
  def handle_info(:close_bot_config, socket) do
    {:noreply, assign(socket, selected_bot: nil)}
  end

  @impl true
  def handle_info({:open_bot_config, bot}, socket) do
    {:noreply, assign(socket, selected_bot: bot, modal_tab: "llm")}
  end

  @impl true
  def handle_info({:use_coords, %{"x" => x, "y" => y, "z" => z, "name" => name}}, socket) do
    send_update(McFunWeb.EffectsPanelLive, id: "effects-panel", effect_target: name)

    {:noreply,
     assign(socket,
       display_x: x,
       display_y: y,
       display_z: z,
       effect_target: name
     )}
  end

  @impl true
  def handle_info({:flash, level, message}, socket) do
    {:noreply, put_flash(socket, level, message)}
  end

  @impl true
  def handle_info(:refresh_status, socket) do
    lv = self()

    Task.start(fn ->
      players =
        try do
          McFun.LogWatcher.online_players()
        catch
          _, _ -> []
        end

      player_data =
        try do
          McFun.LogWatcher.player_statuses()
        catch
          _, _ -> %{}
        end

      send(lv, {:status_update, players, player_data})
    end)

    models = safe_model_ids()
    current_bots = list_bots()
    known = socket.assigns.bots

    for bot <- current_bots, bot not in known do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    {:noreply,
     assign(socket,
       bots: current_bots,
       bot_statuses: build_bot_statuses(),
       rcon_status: check_rcon(),
       server_health: server_health(),
       available_models: if(models != [], do: models, else: socket.assigns.available_models)
     )}
  end

  @impl true
  def handle_info({:status_update, players, player_data}, socket) do
    {:noreply, assign(socket, online_players: players, player_statuses: player_data)}
  end

  @impl true
  def handle_info(:player_statuses_updated, socket) do
    player_data =
      try do
        McFun.LogWatcher.player_statuses()
      catch
        _, _ -> %{}
      end

    {:noreply, assign(socket, player_statuses: player_data)}
  end

  @impl true
  def handle_info({:rcon_result, cmd, result}, socket) do
    entry = %{cmd: cmd, result: strip_mc_formatting(result), at: DateTime.utc_now()}
    history = [entry | Enum.take(socket.assigns.rcon_history, 49)]
    {:noreply, assign(socket, rcon_history: history)}
  end

  @impl true
  def handle_info({:bot_event, bot_name, event_data}, socket) do
    event_type = Map.get(event_data, "event", "unknown")

    event = %{
      type: :"bot_#{event_type}",
      data: Map.put(event_data, "bot", bot_name),
      at: DateTime.utc_now()
    }

    McFun.EventStore.push(event)
    events = [event | Enum.take(socket.assigns.events, 199)]

    statuses = apply_bot_event(socket.assigns.bot_statuses, bot_name, event_type, event_data)
    {:noreply, assign(socket, events: events, bot_statuses: statuses)}
  end

  @impl true
  def handle_info({:mc_event, type, data}, socket) do
    event = %{type: type, data: data, at: DateTime.utc_now()}
    McFun.EventStore.push(event)
    events = [event | Enum.take(socket.assigns.events, 199)]
    {:noreply, assign(socket, events: events)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) when reason != :normal do
    {:noreply,
     socket
     |> put_flash(:error, "Unit crashed: #{inspect(reason)}")
     |> assign(bots: list_bots(), bot_statuses: build_bot_statuses())}
  end

  @impl true
  def handle_info({:cost_updated, summary}, socket) do
    {:noreply, assign(socket, cost_summary: summary)}
  end

  @impl true
  def handle_info({:cost_event, _bot_name, _metrics}, socket) do
    # Handled by CostTracker GenServer; ignore in LiveView
    {:noreply, socket}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp list_bots do
    McFun.BotSupervisor.list_bots()
  rescue
    _ -> []
  end

  defp check_rcon do
    if Process.whereis(McFun.Rcon.Supervisor), do: :connected, else: :disconnected
  end

  defp strip_mc_formatting(text) when is_binary(text) do
    String.replace(text, ~r/§[0-9a-fk-or]/i, "")
  end

  defp strip_mc_formatting(text), do: text

  defp safe_model_ids do
    ModelCache.model_ids()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp update_bot_status(statuses, bot_name, updates) when is_map(updates) do
    case Map.get(statuses, bot_name) do
      nil -> statuses
      existing -> Map.put(statuses, bot_name, Map.merge(existing, updates))
    end
  end

  defp apply_bot_event(statuses, bot_name, "health", %{"health" => health, "food" => food}) do
    update_bot_status(statuses, bot_name, %{health: health, food: food})
  end

  defp apply_bot_event(statuses, bot_name, "position", event_data) do
    updates = %{position: {event_data["x"], event_data["y"], event_data["z"]}}

    updates =
      case Map.get(event_data, "dimension") do
        nil ->
          updates

        dim ->
          Map.put(
            updates,
            :dimension,
            dim |> String.replace("minecraft:", "") |> String.replace("the_", "")
          )
      end

    update_bot_status(statuses, bot_name, updates)
  end

  defp apply_bot_event(statuses, bot_name, "spawn", %{"position" => pos} = event_data) do
    updates = %{position: {pos["x"], pos["y"], pos["z"]}}

    updates =
      case Map.get(event_data, "dimension") do
        nil ->
          updates

        dim ->
          Map.put(
            updates,
            :dimension,
            dim |> String.replace("minecraft:", "") |> String.replace("the_", "")
          )
      end

    update_bot_status(statuses, bot_name, updates)
  end

  defp apply_bot_event(statuses, _bot_name, _event_type, _event_data), do: statuses

  defp build_bot_statuses do
    for bot <- list_bots(), into: %{} do
      {bot, build_single_bot_status(bot)}
    end
  end

  defp build_single_bot_status(bot) do
    chatbot_running? = Registry.lookup(McFun.BotRegistry, {:chat_bot, bot}) != []
    chatbot_info = if chatbot_running?, do: try_chatbot_info(bot), else: nil
    behavior_info = try_behavior_info(bot)
    bot_status = try_bot_status(bot)

    %{
      chatbot: chatbot_running?,
      model: chatbot_info && chatbot_info[:model],
      personality: chatbot_info && chatbot_info[:personality],
      conversations: chatbot_info && chatbot_info[:conversations],
      conversation_players: chatbot_info && chatbot_info[:conversation_players],
      heartbeat_enabled: chatbot_info && chatbot_info[:heartbeat_enabled],
      last_message: chatbot_info && chatbot_info[:last_message],
      behavior: behavior_info,
      position: bot_status[:position],
      health: bot_status[:health],
      food: bot_status[:food],
      dimension: bot_status[:dimension],
      inventory: bot_status[:inventory] || [],
      cost: McFun.CostTracker.get_bot_cost(bot)
    }
  end

  defp try_bot_status(bot_name) do
    case McFun.Bot.status(bot_name) do
      {:error, :not_found} -> %{position: nil, health: nil, food: nil, dimension: nil}
      status when is_map(status) -> status
    end
  catch
    _, _ -> %{position: nil, health: nil, food: nil, dimension: nil}
  end

  defp try_chatbot_info(bot_name) do
    McFun.ChatBot.info(bot_name)
  catch
    _, _ -> nil
  end

  defp try_behavior_info(bot_name) do
    case McFun.BotBehaviors.info(bot_name) do
      {:error, :no_behavior} -> nil
      info when is_map(info) -> info
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp server_health do
    rcon_up = Process.whereis(McFun.Rcon.Supervisor) != nil

    cond do
      not rcon_up -> :error
      :erlang.memory(:total) > 500 * 1_024 * 1_024 -> :degraded
      true -> :healthy
    end
  end

  defp stop_chatbot(name) do
    case Registry.lookup(McFun.BotRegistry, {:chat_bot, name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(McFun.BotSupervisor, pid)
      [] -> :ok
    end
  end
end
