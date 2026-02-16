defmodule McFunWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for MC Fun — bot management, RCON console,
  effects panel, event log, and display tools.

  Inspired by lilbots-01 command center UI.
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
      :timer.send_interval(5_000, self(), :refresh_status)
    end

    models = safe_model_ids()

    socket =
      socket
      |> assign(
        page_title: "MC Fun",
        rcon_input: "",
        rcon_history: [],
        bots: list_bots(),
        bot_statuses: build_bot_statuses(),
        bot_spawn_name: "McFunBot",
        selected_model: Application.get_env(:mc_fun, :groq)[:model] || "openai/gpt-oss-20b",
        selected_preset: nil,
        deploy_personality: default_personality(),
        available_models: models,
        events: McFun.EventStore.list(),
        effect_target: "@a",
        display_text: "",
        display_x: "0",
        display_y: "80",
        display_z: "0",
        display_block: "diamond_block",
        online_players: [],
        player_statuses: %{},
        rcon_status: check_rcon(),
        active_tab: "bots",
        sidebar_open: true,
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

  # --- Model Selection ---

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, selected_model: model)}
  end

  def handle_event("change_bot_model", %{"bot" => bot_name, "model" => model}, socket) do
    McFun.ChatBot.set_model(bot_name, model)

    {:noreply,
     socket
     |> put_flash(:info, "#{bot_name} >> #{model}")
     |> assign(bot_statuses: build_bot_statuses())}
  catch
    _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot_name}")}
  end

  # --- Bot Deploy ---

  def handle_event("deploy_bot", %{"name" => name}, socket) when name != "" do
    model = socket.assigns.selected_model
    personality = socket.assigns.deploy_personality

    if name in socket.assigns.bots do
      # Bot already running — update ChatBot model/personality
      ensure_chatbot(name, model, personality)

      {:noreply,
       socket
       |> put_flash(:info, "#{name} already running — model: #{model}")
       |> assign(bot_statuses: build_bot_statuses())}
    else
      spawn_new_bot(socket, name, model, personality)
    end
  end

  def handle_event("deploy_bot", _, socket), do: {:noreply, socket}

  def handle_event("bot_name_input", %{"name" => val}, socket) do
    {:noreply, assign(socket, bot_spawn_name: val)}
  end

  def handle_event("attach_chatbot", %{"bot" => name}, socket) do
    model = socket.assigns.selected_model
    ensure_chatbot(name, model)

    {:noreply,
     socket
     |> put_flash(:info, "ChatBot >> #{name} [#{model}]")
     |> assign(bot_statuses: build_bot_statuses())}
  end

  def handle_event("teleport_bot", %{"bot" => bot, "player" => player}, socket)
      when player != "" do
    McFun.Bot.teleport_to(bot, player)
    {:noreply, put_flash(socket, :info, "#{bot} >> tp to #{player}")}
  end

  def handle_event("teleport_bot", _, socket), do: {:noreply, socket}

  def handle_event("stop_bot", %{"name" => name}, socket) do
    stop_chatbot(name)
    McFun.BotSupervisor.stop_bot(name)
    # Optimistically remove the bot; schedule a refresh to catch async cleanup
    bots = Enum.reject(socket.assigns.bots, &(&1 == name))
    statuses = Map.delete(socket.assigns.bot_statuses, name)
    Process.send_after(self(), :refresh_bots, 200)
    {:noreply, assign(socket, bots: bots, bot_statuses: statuses)}
  end

  def handle_event("stop_all_bots", _params, socket) do
    for bot <- socket.assigns.bots do
      stop_chatbot(bot)
      McFun.BotSupervisor.stop_bot(bot)
    end

    # Optimistically clear; schedule a refresh to catch async cleanup
    Process.send_after(self(), :refresh_bots, 200)
    {:noreply, assign(socket, bots: [], bot_statuses: %{})}
  end

  # --- Bot Config Modal ---

  def handle_event("open_bot_config", %{"bot" => bot}, socket) do
    {:noreply, assign(socket, selected_bot: bot, modal_tab: "llm")}
  end

  def handle_event("close_bot_config", _params, socket) do
    {:noreply, assign(socket, selected_bot: nil)}
  end

  def handle_event("switch_modal_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, modal_tab: tab)}
  end

  def handle_event("save_personality", %{"bot" => bot, "personality" => personality}, socket) do
    McFun.ChatBot.set_personality(bot, personality)

    {:noreply,
     socket
     |> put_flash(:info, "#{bot} personality updated")
     |> assign(bot_statuses: build_bot_statuses())}
  catch
    _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot}")}
  end

  def handle_event("clear_conversation", %{"bot" => bot}, socket) do
    # Send reset command through the bot's chat
    # Clear all conversations by iterating known players
    info = McFun.ChatBot.info(bot)

    for _player <- info[:conversation_players] || [] do
      McFun.ChatBot.set_personality(bot, info[:personality] || default_personality())
    end

    McFun.Bot.chat(bot, "Memory cleared!")

    {:noreply,
     socket
     |> put_flash(:info, "#{bot} conversations cleared")
     |> assign(bot_statuses: build_bot_statuses())}
  catch
    _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot}")}
  end

  # --- Preset Selection ---

  def handle_event("select_preset", %{"preset" => "custom"}, socket) do
    {:noreply, assign(socket, selected_preset: nil, deploy_personality: default_personality())}
  end

  def handle_event("select_preset", %{"preset" => preset_id}, socket) do
    preset_atom =
      try do
        String.to_existing_atom(preset_id)
      rescue
        ArgumentError -> nil
      end

    case preset_atom && McFun.Presets.get(preset_atom) do
      {:ok, preset} ->
        combined =
          String.trim(default_personality()) <> "\n\n" <> String.trim(preset.system_prompt)

        {:noreply,
         assign(socket,
           selected_preset: preset_id,
           deploy_personality: combined
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Preset not found: #{preset_id}")}
    end
  end

  def handle_event("update_deploy_personality", %{"personality" => p}, socket) do
    {:noreply, assign(socket, deploy_personality: p)}
  end

  def handle_event("apply_preset_to_bot", %{"bot" => bot, "preset" => preset_id}, socket) do
    preset_atom =
      try do
        String.to_existing_atom(preset_id)
      rescue
        ArgumentError -> nil
      end

    case preset_atom && McFun.Presets.get(preset_atom) do
      {:ok, preset} ->
        # Append preset personality onto the base MC personality
        combined =
          String.trim(default_personality()) <> "\n\n" <> String.trim(preset.system_prompt)

        try do
          McFun.ChatBot.set_personality(bot, combined)

          {:noreply,
           socket
           |> put_flash(:info, "#{bot} >> #{preset.name}")
           |> assign(bot_statuses: build_bot_statuses())}
        catch
          _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot}")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Preset not found: #{preset_id}")}
    end
  end

  # --- Bot Actions ---

  def handle_event("bot_action_chat", %{"bot" => bot, "message" => msg}, socket) when msg != "" do
    McFun.Bot.chat(bot, msg)
    {:noreply, put_flash(socket, :info, "#{bot}: #{msg}")}
  end

  def handle_event("bot_action_chat", _, socket), do: {:noreply, socket}

  def handle_event("bot_action_goto", params, socket) do
    bot = params["bot"]
    x = safe_int(params["x"])
    y = safe_int(params["y"])
    z = safe_int(params["z"])
    McFun.Bot.send_command(bot, %{action: "goto", x: x, y: y, z: z})
    {:noreply, put_flash(socket, :info, "#{bot} >> goto #{x},#{y},#{z}")}
  end

  def handle_event("bot_action_jump", %{"bot" => bot}, socket) do
    McFun.Bot.send_command(bot, %{action: "jump"})
    {:noreply, socket}
  end

  def handle_event("bot_action_sneak", %{"bot" => bot}, socket) do
    McFun.Bot.send_command(bot, %{action: "sneak"})
    {:noreply, socket}
  end

  def handle_event("bot_action_attack", %{"bot" => bot}, socket) do
    McFun.Bot.send_command(bot, %{action: "attack"})
    {:noreply, socket}
  end

  # --- Behavior Controls ---

  def handle_event("start_behavior_patrol", %{"bot" => bot, "waypoints" => wp_json}, socket) do
    case Jason.decode(wp_json) do
      {:ok, waypoints} when is_list(waypoints) ->
        tuples = Enum.map(waypoints, fn [x, y, z] -> {x, y, z} end)
        McFun.BotBehaviors.start_patrol(bot, tuples)

        {:noreply,
         socket
         |> put_flash(:info, "#{bot} patrol started (#{length(tuples)} waypoints)")
         |> assign(bot_statuses: build_bot_statuses())}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid waypoints JSON. Use [[x,y,z], ...]")}
    end
  end

  def handle_event("start_behavior_follow", params, socket) do
    bot = params["bot"]
    target = params["target"]

    if target && target != "" do
      McFun.BotBehaviors.start_follow(bot, target)

      {:noreply,
       socket
       |> put_flash(:info, "#{bot} following #{target}")
       |> assign(bot_statuses: build_bot_statuses())}
    else
      {:noreply, put_flash(socket, :error, "Select a player to follow")}
    end
  end

  def handle_event("start_behavior_guard", params, socket) do
    bot = params["bot"]
    x = safe_int(params["x"])
    y = safe_int(params["y"])
    z = safe_int(params["z"])
    radius = safe_int(params["radius"] || "8")
    McFun.BotBehaviors.start_guard(bot, {x, y, z}, radius: radius)

    {:noreply,
     socket
     |> put_flash(:info, "#{bot} guarding #{x},#{y},#{z} (r=#{radius})")
     |> assign(bot_statuses: build_bot_statuses())}
  end

  def handle_event("stop_behavior", %{"bot" => bot}, socket) do
    McFun.BotBehaviors.stop(bot)

    {:noreply,
     socket
     |> put_flash(:info, "#{bot} behavior stopped")
     |> assign(bot_statuses: build_bot_statuses())}
  end

  # --- RCON Console ---

  def handle_event("rcon_submit", %{"command" => cmd}, socket) when cmd != "" do
    lv = self()

    Task.start(fn ->
      result =
        case McFun.Rcon.command(cmd) do
          {:ok, response} -> response
          {:error, reason} -> "ERR: #{inspect(reason)}"
        end

      send(lv, {:rcon_result, cmd, result})
    end)

    {:noreply, assign(socket, rcon_input: "")}
  end

  def handle_event("rcon_submit", _, socket), do: {:noreply, socket}

  def handle_event("rcon_input", %{"command" => val}, socket) do
    {:noreply, assign(socket, rcon_input: val)}
  end

  # --- Effects ---

  def handle_event("fire_effect", %{"effect" => effect}, socket) do
    target = socket.assigns.effect_target

    Task.start(fn ->
      case effect do
        "celebration" -> McFun.Effects.celebration(target)
        "welcome" -> McFun.Effects.welcome(target)
        "death" -> McFun.Effects.death_effect(target)
        "achievement" -> McFun.Effects.achievement_fanfare(target)
        "firework" -> McFun.Effects.firework(target)
        _ -> :ok
      end
    end)

    {:noreply, put_flash(socket, :info, "FX #{effect} >> #{target}")}
  end

  def handle_event("set_effect_target", %{"target" => target}, socket) do
    {:noreply, assign(socket, effect_target: target)}
  end

  # --- Display ---

  def handle_event("place_text", params, socket) do
    text = Map.get(params, "text", "")
    x = safe_int(Map.get(params, "x", "0"))
    y = safe_int(Map.get(params, "y", "80"))
    z = safe_int(Map.get(params, "z", "0"))
    block = Map.get(params, "block", "diamond_block")

    if text != "" do
      Task.start(fn -> McFun.Display.write(text, {x, y, z}, block: block) end)
      {:noreply, put_flash(socket, :info, "Placing '#{text}' at #{x},#{y},#{z}")}
    else
      {:noreply, socket}
    end
  end

  # --- Handles ---

  @impl true
  def handle_info(:refresh_bots, socket) do
    {:noreply, assign(socket, bots: list_bots(), bot_statuses: build_bot_statuses())}
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
    # Refresh bots list (detects new/removed bots) but do NOT rebuild bot_statuses —
    # those are updated incrementally via PubSub :bot_event messages.
    current_bots = list_bots()
    # Subscribe to any new bots we haven't seen yet
    known = socket.assigns.bots

    for bot <- current_bots, bot not in known do
      Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
    end

    {:noreply,
     assign(socket,
       bots: current_bots,
       rcon_status: check_rcon(),
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
    entry = %{cmd: cmd, result: result, at: DateTime.utc_now()}
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

    # Incrementally update bot_statuses from PubSub events
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
  def handle_info(_, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp spawn_new_bot(socket, name, model, personality) do
    case McFun.BotSupervisor.spawn_bot(name) do
      {:ok, pid} ->
        Process.monitor(pid)
        Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{name}")
        schedule_chatbot_attach(name, model, personality)

        {:noreply,
         socket
         |> put_flash(:info, "Deploying #{name} [#{model}]...")
         |> assign(bots: list_bots(), bot_statuses: build_bot_statuses(), bot_spawn_name: "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Deploy failed: #{inspect(reason)}")}
    end
  end

  defp schedule_chatbot_attach(name, model, personality) do
    lv = self()

    Task.start(fn ->
      Process.sleep(2_000)
      ensure_chatbot(name, model, personality)
      send(lv, :refresh_bots)
    end)
  end

  defp list_bots do
    McFun.BotSupervisor.list_bots()
  rescue
    _ -> []
  end

  defp check_rcon do
    if Process.whereis(McFun.Rcon), do: :connected, else: :disconnected
  end

  defp safe_model_ids do
    ModelCache.model_ids()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp safe_int(val) when is_integer(val), do: val

  defp safe_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp safe_int(_), do: 0

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
      chatbot_running? = Registry.lookup(McFun.BotRegistry, {:chat_bot, bot}) != []
      chatbot_info = if chatbot_running?, do: try_chatbot_info(bot), else: nil
      behavior_info = try_behavior_info(bot)
      bot_status = try_bot_status(bot)

      {bot,
       %{
         chatbot: chatbot_running?,
         model: chatbot_info && chatbot_info[:model],
         personality: chatbot_info && chatbot_info[:personality],
         conversations: chatbot_info && chatbot_info[:conversations],
         conversation_players: chatbot_info && chatbot_info[:conversation_players],
         behavior: behavior_info,
         position: bot_status[:position],
         health: bot_status[:health],
         food: bot_status[:food],
         dimension: bot_status[:dimension]
       }}
    end
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

  defp ensure_chatbot(name, model, personality \\ nil) do
    opts = [bot_name: name, model: model]
    opts = if personality, do: Keyword.put(opts, :personality, personality), else: opts
    spec = {McFun.ChatBot, opts}

    case DynamicSupervisor.start_child(McFun.BotSupervisor, spec) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        # Update model/personality on existing ChatBot
        try do
          McFun.ChatBot.set_model(name, model)
          if personality, do: McFun.ChatBot.set_personality(name, personality)
        catch
          _, _ -> :ok
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
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

  defp default_personality do
    "You are a friendly Minecraft bot. Keep responses to 1-2 sentences. No markdown."
  end

  defp stop_chatbot(name) do
    case Registry.lookup(McFun.BotRegistry, {:chat_bot, name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(McFun.BotSupervisor, pid)
      [] -> :ok
    end
  end

  # --- Render Helpers (used by dashboard_live.html.heex) ---

  defp event_color(:player_join), do: "text-[#00ff88]"
  defp event_color(:player_leave), do: "text-[#ffaa00]"
  defp event_color(:player_death), do: "text-[#ff4444]"
  defp event_color(:player_chat), do: "text-[#00ffff]"
  defp event_color(:player_advancement), do: "text-[#aa66ff]"
  defp event_color(:bot_chat), do: "text-[#00ffff]"
  defp event_color(:bot_whisper), do: "text-[#ff66aa]"
  defp event_color(:bot_spawn), do: "text-[#00ff88]"
  defp event_color(:bot_llm_response), do: "text-[#ffcc00]"
  defp event_color(_), do: "text-[#666]"

  defp format_event_data(data) when is_map(data) do
    data
    |> Map.drop([:raw_line, :timestamp])
    |> Map.drop(["raw_line", "timestamp"])
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_value(v)}" end)
  end

  defp format_event_data(data), do: inspect(data)

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp format_value(v) when is_map(v), do: inspect(v)
  defp format_value(v) when is_list(v), do: inspect(v)
  defp format_value(v), do: to_string(v)
end
