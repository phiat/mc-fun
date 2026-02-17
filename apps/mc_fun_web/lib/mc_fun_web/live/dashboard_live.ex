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

  @valid_tabs ~w(bots players rcon effects display events chat)

  @impl true
  def mount(_params, _session, socket) do
    initial_bots = BotFarmer.list_bots()

    if connected?(socket) do
      McFun.Events.subscribe(:all)

      for bot <- initial_bots do
        Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
      end

      Phoenix.PubSub.subscribe(McFun.PubSub, "player_statuses")
      Phoenix.PubSub.subscribe(McFun.PubSub, "costs")
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot_chat")
      Phoenix.PubSub.subscribe(McFun.PubSub, "chat_log")
      :timer.send_interval(3_000, self(), :refresh_status)
    end

    models = safe_model_ids()

    socket =
      socket
      |> assign(
        page_title: "MC Fun",
        rcon_history: [],
        bots: BotFarmer.list_bots(),
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
        subscribed_bots: MapSet.new(initial_bots),
        cost_summary: McFun.CostTracker.get_global_cost(),
        bot_chat_status: safe_bot_chat_status(BotFarmer.bot_chat_status()),
        server_health: server_health(),
        chat_entries: safe_chat_entries(),
        failed_bots: %{},
        # Bot config modal
        selected_bot: nil,
        modal_tab: "llm"
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "bots"
    tab = if tab in @valid_tabs, do: tab, else: "bots"
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> clear_flash() |> push_patch(to: ~p"/dashboard?tab=#{tab}")}
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
    BotFarmer.stop_all()
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
    {:noreply, assign(socket, bots: BotFarmer.list_bots(), bot_statuses: build_bot_statuses())}
  end

  @impl true
  def handle_info(:refresh_bot_statuses, socket) do
    {:noreply, assign(socket, bot_statuses: build_bot_statuses())}
  end

  @impl true
  def handle_info({:clear_failed, bot_name}, socket) do
    {:noreply, assign(socket, failed_bots: Map.delete(socket.assigns.failed_bots, bot_name))}
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
    current_bots = BotFarmer.list_bots()
    current_set = MapSet.new(current_bots)
    subscribed = socket.assigns.subscribed_bots

    # Subscribe to new bots
    for bot <- MapSet.difference(current_set, subscribed) do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    # Unsubscribe from dead bots
    for bot <- MapSet.difference(subscribed, current_set) do
      Phoenix.PubSub.unsubscribe(McFun.PubSub, "bot:#{bot}")
    end

    {:noreply,
     assign(socket,
       bots: current_bots,
       subscribed_bots: current_set,
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
  def handle_info(
        {:bot_event, bot_name, %{"event" => "kicked", "reason" => reason} = event_data},
        socket
      ) do
    event = %{
      type: :bot_kicked,
      data: Map.put(event_data, "bot", bot_name),
      at: DateTime.utc_now()
    }

    McFun.EventStore.push(event)
    events = [event | Enum.take(socket.assigns.events, 199)]

    failed = Map.put(socket.assigns.failed_bots, bot_name, reason)

    {:noreply,
     socket
     |> assign(events: events, failed_bots: failed)
     |> put_flash(:error, "#{bot_name} kicked: #{reason}")}
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
     |> assign(bots: BotFarmer.list_bots(), bot_statuses: build_bot_statuses())}
  end

  @impl true
  def handle_info({:bot_chat_updated, status}, socket) do
    {:noreply, assign(socket, bot_chat_status: status)}
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
  def handle_info({:new_chat_entry, entry}, socket) do
    entries = [entry | Enum.take(socket.assigns.chat_entries, 499)]
    {:noreply, assign(socket, chat_entries: entries)}
  end

  @impl true
  def handle_info(:chat_log_cleared, socket) do
    {:noreply, assign(socket, chat_entries: [])}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # --- Helpers ---

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
    for bot <- BotFarmer.list_bots(), into: %{} do
      {bot, BotFarmer.bot_status(bot)}
    end
  end

  defp server_health do
    rcon_up = Process.whereis(McFun.Rcon.Supervisor) != nil

    cond do
      not rcon_up -> :error
      :erlang.memory(:total) > 500 * 1_024 * 1_024 -> :degraded
      true -> :healthy
    end
  end

  defp safe_chat_entries do
    McFun.ChatLog.list()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp safe_bot_chat_status(status) when is_map(status), do: status
  defp safe_bot_chat_status(_), do: %{enabled: false, pairs: %{}, config: %{}}
end
