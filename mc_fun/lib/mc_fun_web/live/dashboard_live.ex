defmodule McFunWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard for MC Fun — bot management, RCON console,
  effects panel, event log, and display tools.

  Inspired by lilbots-01 command center UI.
  """
  use McFunWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      McFun.Events.subscribe(:all)
      for bot <- list_bots() do
        Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{bot}")
      end
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
        bot_spawn_name: "",
        selected_model: "openai/gpt-oss-20b",
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
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_open: !socket.assigns.sidebar_open)}
  end

  # --- Quick Launch ---

  def handle_event("quick_launch", _params, socket) do
    model = socket.assigns.selected_model
    personality = socket.assigns.deploy_personality
    name = "McFunBot"

    if name in socket.assigns.bots do
      ensure_chatbot(name, model, personality)
      {:noreply, put_flash(socket, :info, "McFunBot already running, ChatBot attached")}
    else
      case McFun.BotSupervisor.spawn_bot(name) do
        {:ok, pid} ->
          Process.monitor(pid)
          Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{name}")

          lv = self()
          Task.start(fn ->
            Process.sleep(2_000)
            ensure_chatbot(name, model, personality)
            send(lv, :refresh_bots)
          end)

          {:noreply,
           socket
           |> put_flash(:info, "Deploying McFunBot [#{model}]...")
           |> assign(bots: list_bots(), bot_statuses: build_bot_statuses())}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Deploy failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    {:noreply,
     socket
     |> assign(selected_model: model)
     |> put_flash(:info, "Deploy model: #{model}")}
  end

  def handle_event("change_bot_model", %{"bot" => bot_name, "model" => model}, socket) do
    try do
      McFun.ChatBot.set_model(bot_name, model)
      {:noreply,
       socket
       |> put_flash(:info, "#{bot_name} >> #{model}")
       |> assign(bot_statuses: build_bot_statuses())}
    catch
      _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot_name}")}
    end
  end

  # --- Custom Bot Spawn ---

  def handle_event("spawn_custom_bot", %{"name" => name}, socket) when name != "" do
    case McFun.BotSupervisor.spawn_bot(name) do
      {:ok, pid} ->
        Process.monitor(pid)
        Phoenix.PubSub.subscribe(McFun.PubSub, "bot:#{name}")
        {:noreply,
         socket
         |> put_flash(:info, "Deploying #{name}...")
         |> assign(bots: list_bots(), bot_statuses: build_bot_statuses(), bot_spawn_name: "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def handle_event("spawn_custom_bot", _, socket), do: {:noreply, socket}

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

  def handle_event("teleport_bot", %{"bot" => bot, "player" => player}, socket) when player != "" do
    McFun.Bot.teleport_to(bot, player)
    {:noreply, put_flash(socket, :info, "#{bot} >> tp to #{player}")}
  end

  def handle_event("teleport_bot", _, socket), do: {:noreply, socket}

  def handle_event("stop_bot", %{"name" => name}, socket) do
    stop_chatbot(name)
    McFun.BotSupervisor.stop_bot(name)
    {:noreply, assign(socket, bots: list_bots(), bot_statuses: build_bot_statuses())}
  end

  def handle_event("stop_all_bots", _params, socket) do
    for bot <- socket.assigns.bots do
      stop_chatbot(bot)
      McFun.BotSupervisor.stop_bot(bot)
    end
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
    try do
      McFun.ChatBot.set_personality(bot, personality)
      {:noreply,
       socket
       |> put_flash(:info, "#{bot} personality updated")
       |> assign(bot_statuses: build_bot_statuses())}
    catch
      _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot}")}
    end
  end

  def handle_event("clear_conversation", %{"bot" => bot}, socket) do
    # Send reset command through the bot's chat
    try do
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
        {:noreply,
         assign(socket,
           selected_preset: preset_id,
           deploy_personality: String.trim(preset.system_prompt)
         )}

      _ ->
        {:noreply, socket}
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
        try do
          McFun.ChatBot.set_personality(bot, String.trim(preset.system_prompt))
          {:noreply,
           socket
           |> put_flash(:info, "#{bot} >> #{preset.name}")
           |> assign(bot_statuses: build_bot_statuses())}
        catch
          _, _ -> {:noreply, put_flash(socket, :error, "ChatBot not active for #{bot}")}
        end

      _ ->
        {:noreply, socket}
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
      players = try do McFun.LogWatcher.online_players() catch _, _ -> [] end
      send(lv, {:status_update, players})
    end)
    models = safe_model_ids()
    {:noreply, assign(socket,
      bots: list_bots(),
      bot_statuses: build_bot_statuses(),
      rcon_status: check_rcon(),
      available_models: if(models != [], do: models, else: socket.assigns.available_models)
    )}
  end

  @impl true
  def handle_info({:status_update, players}, socket) do
    {:noreply, assign(socket, online_players: players)}
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
    event = %{type: :"bot_#{event_type}", data: Map.put(event_data, "bot", bot_name), at: DateTime.utc_now()}
    McFun.EventStore.push(event)
    events = [event | Enum.take(socket.assigns.events, 199)]
    {:noreply, assign(socket, events: events)}
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

  defp list_bots do
    McFun.BotSupervisor.list_bots()
  rescue
    _ -> []
  end

  defp check_rcon do
    if Process.whereis(McFun.Rcon), do: :connected, else: :disconnected
  end

  defp safe_model_ids do
    McFun.LLM.ModelCache.model_ids()
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

  defp build_bot_statuses do
    for bot <- list_bots(), into: %{} do
      chatbot_running? = Registry.lookup(McFun.BotRegistry, {:chat_bot, bot}) != []
      chatbot_info = if chatbot_running?, do: try_chatbot_info(bot), else: nil
      behavior_info = try_behavior_info(bot)

      {bot, %{
        chatbot: chatbot_running?,
        model: chatbot_info && chatbot_info[:model],
        personality: chatbot_info && chatbot_info[:personality],
        conversations: chatbot_info && chatbot_info[:conversations],
        conversation_players: chatbot_info && chatbot_info[:conversation_players],
        behavior: behavior_info
      }}
    end
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
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
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
    """
    You are a friendly Minecraft bot. You chat with players in-game.
    Keep responses SHORT (1-2 sentences max). Be fun, helpful, and in-character.
    You live in the Minecraft world. You can see, mine, build, and fight.
    Don't use markdown formatting. Just plain text suitable for Minecraft chat.
    """
  end

  defp format_behavior(nil), do: "NONE"
  defp format_behavior(%{behavior: :patrol}), do: "PATROL"
  defp format_behavior(%{behavior: :follow, params: %{target: t}}), do: "FOLLOW #{t}"
  defp format_behavior(%{behavior: :guard}), do: "GUARD"
  defp format_behavior(_), do: "ACTIVE"

  defp stop_chatbot(name) do
    case Registry.lookup(McFun.BotRegistry, {:chat_bot, name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(McFun.BotSupervisor, pid)
      [] -> :ok
    end
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#0a0a0f] text-[#e0e0e0] font-mono">
      <%!-- Scanline overlay --%>
      <div class="pointer-events-none fixed inset-0 z-50 opacity-[0.03]" style="background: repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(255,255,255,0.03) 2px, rgba(255,255,255,0.03) 4px)" />

      <%!-- Header --%>
      <header class="sticky top-0 z-40 border-b-2 border-[#00ffff]/30 bg-[#0a0a0f]/95 backdrop-blur px-4 py-2">
        <div class="flex items-center justify-between max-w-7xl mx-auto">
          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2">
              <div class={"w-2 h-2 #{if @rcon_status == :connected, do: "bg-[#00ff88] shadow-[0_0_6px_#00ff88]", else: "bg-[#ff4444] shadow-[0_0_6px_#ff4444]"}"} />
              <span class="text-[#00ffff] font-bold tracking-widest text-sm">MC FUN</span>
            </div>
            <span class="text-[10px] text-[#666] tracking-wider">
              RCON {if @rcon_status == :connected, do: "ONLINE", else: "OFFLINE"}
            </span>
          </div>

          <div class="flex items-center gap-4 text-[10px] tracking-wider text-[#888]">
            <span :if={@online_players != []}>
              PLAYERS: <span class="text-[#00ff88]">{Enum.join(@online_players, ", ")}</span>
            </span>
            <span>UNITS: <span class="text-[#00ffff]">{length(@bots)}</span></span>
          </div>
        </div>
      </header>

      <%!-- Status bar + nav --%>
      <div class="border-b border-[#222] px-4 py-1.5 bg-[#0d0d14]">
        <div class="max-w-7xl mx-auto flex items-center justify-between">
          <div class="flex gap-1">
            <button
              :for={{id, label} <- [{"bots", "UNITS"}, {"rcon", "RCON"}, {"effects", "FX"}, {"display", "DISPLAY"}, {"events", "EVENTS"}]}
              class={"px-3 py-1 text-[10px] tracking-widest border transition-all " <>
                if(@active_tab == id,
                  do: "border-[#00ffff] text-[#00ffff] bg-[#00ffff]/10",
                  else: "border-[#333] text-[#666] hover:border-[#555] hover:text-[#aaa]")}
              phx-click="switch_tab"
              phx-value-tab={id}
            >
              {label}
            </button>
          </div>

          <%!-- Quick actions --%>
          <div class="flex items-center gap-2">
            <button
              phx-click="quick_launch"
              class="px-3 py-1 text-[10px] tracking-widest border border-[#00ff88] text-[#00ff88] hover:bg-[#00ff88]/10 transition-all"
            >
              [+] DEPLOY
            </button>
            <button
              :if={@bots != []}
              phx-click="stop_all_bots"
              data-confirm="Terminate all units?"
              class="px-3 py-1 text-[10px] tracking-widest border border-[#ff4444] text-[#ff4444] hover:bg-[#ff4444]/10 transition-all"
            >
              [X] PURGE ALL
            </button>
          </div>
        </div>
      </div>

      <div class="max-w-7xl mx-auto p-4">
        <%!-- ==================== UNITS TAB ==================== --%>
        <div :if={@active_tab == "bots"} class="space-y-4">

          <%!-- Deploy Panel --%>
          <div class="border-2 border-[#00ffff]/20 bg-[#0d0d14] p-4">
            <div class="text-[10px] tracking-widest text-[#00ffff]/60 mb-3">DEPLOY CONFIGURATION</div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <%!-- Model selector --%>
              <div>
                <label class="text-[10px] tracking-wider text-[#888] block mb-1">MODEL</label>
                <select
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none focus:shadow-[0_0_8px_rgba(0,255,255,0.2)]"
                  phx-change="select_model"
                  name="model"
                >
                  <option
                    :for={model <- @available_models}
                    value={model}
                    selected={model == @selected_model}
                  >
                    {model}
                  </option>
                  <option :if={@available_models == []} value={@selected_model}>
                    {@selected_model} (loading...)
                  </option>
                </select>
              </div>

              <%!-- Preset selector --%>
              <div>
                <label class="text-[10px] tracking-wider text-[#888] block mb-1">PRESET</label>
                <select
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none focus:shadow-[0_0_8px_rgba(0,255,255,0.2)]"
                  phx-change="select_preset"
                  name="preset"
                >
                  <option value="custom" selected={@selected_preset == nil}>Custom</option>
                  <%= for {category, presets} <- McFun.Presets.by_category() do %>
                    <optgroup label={category |> to_string() |> String.upcase()}>
                      <option
                        :for={preset <- presets}
                        value={preset.id}
                        selected={to_string(preset.id) == @selected_preset}
                      >
                        {preset.name}
                      </option>
                    </optgroup>
                  <% end %>
                </select>
              </div>

              <%!-- Launch button --%>
              <div class="flex items-end">
                <button
                  phx-click="quick_launch"
                  class="w-full py-2 px-4 border-2 border-[#00ff88] text-[#00ff88] font-bold text-xs tracking-widest hover:bg-[#00ff88] hover:text-[#0a0a0f] transition-all"
                >
                  DEPLOY McFunBot
                </button>
              </div>
            </div>

            <%!-- Personality textarea --%>
            <div class="mt-3">
              <label class="text-[10px] tracking-wider text-[#888] block mb-1">PERSONALITY</label>
              <textarea
                phx-change="update_deploy_personality"
                name="personality"
                rows="3"
                class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none resize-y placeholder:text-[#444]"
              >{@deploy_personality}</textarea>
            </div>

            <%!-- Custom spawn --%>
            <div class="mt-3 pt-3 border-t border-[#222]">
              <form phx-submit="spawn_custom_bot" class="flex gap-2">
                <input
                  type="text"
                  name="name"
                  value={@bot_spawn_name}
                  phx-change="bot_name_input"
                  placeholder="custom unit name..."
                  class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
                />
                <button type="submit" class="px-4 py-1.5 border border-[#00ffff] text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10">
                  SPAWN
                </button>
              </form>
              <div class="text-[10px] text-[#444] mt-1">whitelist first: /whitelist add BotName</div>
            </div>
          </div>

          <%!-- Active Units --%>
          <div class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
            <div class="flex items-center justify-between mb-3">
              <div class="text-[10px] tracking-widest text-[#888]">
                ACTIVE UNITS <span class="text-[#00ffff]">[{length(@bots)}]</span>
              </div>
            </div>

            <div :if={@bots == []} class="text-center py-8 text-[#333] text-xs">
              NO UNITS DEPLOYED
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <div :for={bot <- @bots} class="border border-[#333] bg-[#111] p-3 hover:border-[#00ffff]/40 transition-all group">
                <%!-- Unit header --%>
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <div class={"w-1.5 h-1.5 " <>
                      if(@bot_statuses[bot] && @bot_statuses[bot].chatbot,
                        do: "bg-[#00ff88] shadow-[0_0_4px_#00ff88]",
                        else: "bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]")} />
                    <span class="text-sm font-bold text-[#e0e0e0]">{bot}</span>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="open_bot_config"
                      phx-value-bot={bot}
                      class="text-[#00ffff]/50 hover:text-[#00ffff] text-[10px] tracking-widest opacity-0 group-hover:opacity-100 transition-opacity"
                    >
                      [CFG]
                    </button>
                    <button
                      phx-click="stop_bot"
                      phx-value-name={bot}
                      class="text-[#ff4444]/50 hover:text-[#ff4444] text-xs opacity-0 group-hover:opacity-100 transition-opacity"
                    >
                      [X]
                    </button>
                  </div>
                </div>

                <%!-- Unit details --%>
                <div class="text-[10px] tracking-wider space-y-1 text-[#888]">
                  <%= if status = @bot_statuses[bot] do %>
                    <%= if status.chatbot do %>
                      <div class="flex justify-between">
                        <span>STATUS</span>
                        <span class="text-[#00ff88]">CHAT ACTIVE</span>
                      </div>
                      <div class="flex justify-between">
                        <span>MODEL</span>
                        <span class="text-[#00ffff]">{status.model || "default"}</span>
                      </div>
                      <div class="flex justify-between">
                        <span>BEHAVIOR</span>
                        <span class="text-[#aa66ff]">{format_behavior(status.behavior)}</span>
                      </div>
                      <%!-- Model switcher --%>
                      <div class="pt-1">
                        <select
                          id={"model-select-#{bot}"}
                          class="w-full bg-[#0a0a0f] border border-[#333] text-[#aaa] px-2 py-1 text-[10px] focus:border-[#00ffff] focus:outline-none"
                          phx-change="change_bot_model"
                          name="model"
                          phx-value-bot={bot}
                        >
                          <option
                            :for={model <- @available_models}
                            value={model}
                            selected={model == status.model}
                          >
                            {model}
                          </option>
                        </select>
                      </div>
                      <%!-- Actions row --%>
                      <div class="pt-1 flex gap-1">
                        <button
                          :for={player <- @online_players}
                          phx-click="teleport_bot"
                          phx-value-bot={bot}
                          phx-value-player={player}
                          class="flex-1 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                        >
                          TP {player}
                        </button>
                      </div>
                      <div class="pt-1">
                        <button
                          phx-click="open_bot_config"
                          phx-value-bot={bot}
                          class="w-full py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10"
                        >
                          CONFIGURE
                        </button>
                      </div>
                    <% else %>
                      <div class="flex justify-between">
                        <span>STATUS</span>
                        <span class="text-[#ffaa00]">NO CHAT</span>
                      </div>
                      <button
                        phx-click="attach_chatbot"
                        phx-value-bot={bot}
                        class="w-full mt-1 py-1 border border-[#00ff88]/50 text-[#00ff88] text-[10px] tracking-widest hover:bg-[#00ff88]/10"
                      >
                        ATTACH CHATBOT
                      </button>
                    <% end %>
                  <% end %>
                </div>
              </div>
            </div>
          </div>

          <%!-- Commands reference --%>
          <div class="border border-[#222] bg-[#0d0d14] p-4">
            <div class="text-[10px] tracking-widest text-[#666] mb-2">COMMAND REFERENCE</div>
            <div class="grid grid-cols-2 md:grid-cols-3 gap-x-6 gap-y-1 text-[11px]">
              <div><span class="text-[#00ffff]">!ask</span> <span class="text-[#666]">&lt;question&gt;</span></div>
              <div><span class="text-[#00ffff]">/msg Bot</span> <span class="text-[#666]">&lt;text&gt;</span></div>
              <div><span class="text-[#00ffff]">!models</span> <span class="text-[#666]">list models</span></div>
              <div><span class="text-[#00ffff]">!model</span> <span class="text-[#666]">&lt;id&gt;</span></div>
              <div><span class="text-[#00ffff]">!personality</span> <span class="text-[#666]">&lt;text&gt;</span></div>
              <div><span class="text-[#00ffff]">!reset</span> <span class="text-[#666]">clear history</span></div>
            </div>
          </div>
        </div>

        <%!-- ==================== BOT CONFIG MODAL ==================== --%>
        <%= if @selected_bot do %>
          <% bot = @selected_bot %>
          <% status = @bot_statuses[bot] %>
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/70" phx-click="close_bot_config">
            <div class="w-full max-w-2xl max-h-[85vh] overflow-y-auto bg-[#0d0d14] border-2 border-[#00ffff]/40 shadow-[0_0_30px_rgba(0,255,255,0.15)]" phx-click-away="close_bot_config">
              <%!-- Modal header --%>
              <div class="flex items-center justify-between px-4 py-3 border-b border-[#222]">
                <div class="flex items-center gap-2">
                  <div class={"w-2 h-2 " <> if(status && status.chatbot, do: "bg-[#00ff88] shadow-[0_0_4px_#00ff88]", else: "bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]")} />
                  <span class="text-sm font-bold text-[#e0e0e0] tracking-wider">{bot}</span>
                  <span class="text-[10px] text-[#666] tracking-wider">CONFIG</span>
                </div>
                <button phx-click="close_bot_config" class="text-[#666] hover:text-[#e0e0e0] text-sm">[X]</button>
              </div>

              <%!-- Modal tabs --%>
              <div class="flex border-b border-[#222]">
                <button
                  :for={{id, label} <- [{"llm", "LLM"}, {"behavior", "BEHAVIOR"}, {"actions", "ACTIONS"}]}
                  class={"px-4 py-2 text-[10px] tracking-widest border-b-2 transition-all " <>
                    if(@modal_tab == id,
                      do: "border-[#00ffff] text-[#00ffff]",
                      else: "border-transparent text-[#666] hover:text-[#aaa]")}
                  phx-click="switch_modal_tab"
                  phx-value-tab={id}
                >
                  {label}
                </button>
              </div>

              <div class="p-4">
                <%!-- === LLM TAB === --%>
                <div :if={@modal_tab == "llm"} class="space-y-4">
                  <%!-- Model --%>
                  <div>
                    <label class="text-[10px] tracking-wider text-[#888] block mb-1">MODEL</label>
                    <select
                      id={"modal-model-#{bot}"}
                      class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none"
                      phx-change="change_bot_model"
                      name="model"
                      phx-value-bot={bot}
                    >
                      <option
                        :for={model <- @available_models}
                        value={model}
                        selected={model == (status && status.model)}
                      >
                        {model}
                      </option>
                    </select>
                  </div>

                  <%!-- Personality --%>
                  <div>
                    <label class="text-[10px] tracking-wider text-[#888] block mb-1">PERSONALITY</label>
                    <form phx-submit="save_personality">
                      <input type="hidden" name="bot" value={bot} />
                      <textarea
                        name="personality"
                        rows="5"
                        class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none resize-y"
                      ><%= if(status && status.personality, do: status.personality, else: "") %></textarea>
                      <button type="submit" class="mt-1 px-4 py-1 border border-[#00ff88]/50 text-[#00ff88] text-[10px] tracking-widest hover:bg-[#00ff88]/10">
                        SAVE PERSONALITY
                      </button>
                    </form>
                  </div>

                  <%!-- Apply preset --%>
                  <div>
                    <label class="text-[10px] tracking-wider text-[#888] block mb-1">APPLY PRESET</label>
                    <div class="flex flex-wrap gap-1">
                      <%= for {category, presets} <- McFun.Presets.by_category() do %>
                        <div class="w-full mt-2 first:mt-0">
                          <div class="text-[9px] tracking-widest text-[#555] mb-1">{category |> to_string() |> String.upcase()}</div>
                          <div class="flex flex-wrap gap-1">
                            <button
                              :for={preset <- presets}
                              phx-click="apply_preset_to_bot"
                              phx-value-bot={bot}
                              phx-value-preset={preset.id}
                              class="px-2 py-0.5 border border-[#aa66ff]/30 text-[#aa66ff] text-[10px] hover:bg-[#aa66ff]/10 hover:border-[#aa66ff]/60 transition-all"
                              title={preset.description}
                            >
                              {preset.name}
                            </button>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Conversation history --%>
                  <div>
                    <div class="flex items-center justify-between mb-1">
                      <label class="text-[10px] tracking-wider text-[#888]">CONVERSATIONS</label>
                      <button
                        phx-click="clear_conversation"
                        phx-value-bot={bot}
                        class="text-[10px] text-[#ff4444]/50 hover:text-[#ff4444]"
                      >
                        CLEAR ALL
                      </button>
                    </div>
                    <%= if status && status.conversation_players && status.conversation_players != [] do %>
                      <div class="bg-[#080810] border border-[#222] p-2 text-[10px] text-[#888] space-y-1 max-h-32 overflow-y-auto">
                        <div :for={player <- status.conversation_players} class="flex items-center gap-2">
                          <span class="text-[#00ffff]">{player}</span>
                          <span class="text-[#444]">
                            {length(Map.get(status.conversations || %{}, player, []))} msgs
                          </span>
                        </div>
                      </div>
                    <% else %>
                      <div class="text-[10px] text-[#444]">No active conversations</div>
                    <% end %>
                  </div>
                </div>

                <%!-- === BEHAVIOR TAB === --%>
                <div :if={@modal_tab == "behavior"} class="space-y-4">
                  <%!-- Current behavior --%>
                  <div class="flex items-center justify-between">
                    <div>
                      <span class="text-[10px] tracking-wider text-[#888]">CURRENT: </span>
                      <span class="text-[10px] text-[#aa66ff]">{format_behavior(status && status.behavior)}</span>
                    </div>
                    <button
                      :if={status && status.behavior}
                      phx-click="stop_behavior"
                      phx-value-bot={bot}
                      class="px-3 py-1 border border-[#ff4444]/50 text-[#ff4444] text-[10px] tracking-widest hover:bg-[#ff4444]/10"
                    >
                      STOP
                    </button>
                  </div>

                  <%!-- Patrol --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">PATROL</div>
                    <form phx-submit="start_behavior_patrol">
                      <input type="hidden" name="bot" value={bot} />
                      <input
                        type="text"
                        name="waypoints"
                        placeholder="[[0,64,0],[10,64,10],[20,64,0]]"
                        class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
                      />
                      <button type="submit" class="mt-1 px-4 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10">
                        START PATROL
                      </button>
                    </form>
                  </div>

                  <%!-- Follow --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">FOLLOW</div>
                    <form phx-submit="start_behavior_follow">
                      <input type="hidden" name="bot" value={bot} />
                      <div class="flex gap-2">
                        <select
                          name="target"
                          class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
                        >
                          <option :for={player <- @online_players} value={player}>{player}</option>
                        </select>
                        <button type="submit" class="px-4 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10">
                          FOLLOW
                        </button>
                      </div>
                    </form>
                  </div>

                  <%!-- Guard --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">GUARD</div>
                    <form phx-submit="start_behavior_guard" class="space-y-2">
                      <input type="hidden" name="bot" value={bot} />
                      <div class="grid grid-cols-4 gap-2">
                        <div :for={{label, name, default} <- [{"X", "x", "0"}, {"Y", "y", "64"}, {"Z", "z", "0"}, {"R", "radius", "8"}]}>
                          <label class="text-[10px] tracking-wider text-[#666] block mb-0.5">{label}</label>
                          <input
                            type="text" name={name} value={default}
                            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
                          />
                        </div>
                      </div>
                      <button type="submit" class="px-4 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10">
                        GUARD POSITION
                      </button>
                    </form>
                  </div>
                </div>

                <%!-- === ACTIONS TAB === --%>
                <div :if={@modal_tab == "actions"} class="space-y-4">
                  <%!-- Chat --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#00ffff] mb-2">CHAT</div>
                    <form phx-submit="bot_action_chat" class="flex gap-2">
                      <input type="hidden" name="bot" value={bot} />
                      <input
                        type="text" name="message" placeholder="say something..."
                        class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
                      />
                      <button type="submit" class="px-4 py-1 border border-[#00ffff]/50 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10">
                        SEND
                      </button>
                    </form>
                  </div>

                  <%!-- Goto --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#00ffff] mb-2">GOTO</div>
                    <form phx-submit="bot_action_goto" class="space-y-2">
                      <input type="hidden" name="bot" value={bot} />
                      <div class="grid grid-cols-3 gap-2">
                        <div :for={{label, name} <- [{"X", "x"}, {"Y", "y"}, {"Z", "z"}]}>
                          <label class="text-[10px] tracking-wider text-[#666] block mb-0.5">{label}</label>
                          <input
                            type="text" name={name} value="0"
                            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
                          />
                        </div>
                      </div>
                      <button type="submit" class="px-4 py-1 border border-[#00ffff]/50 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10">
                        GO TO
                      </button>
                    </form>
                  </div>

                  <%!-- Teleport --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#00ffff] mb-2">TELEPORT</div>
                    <div class="flex flex-wrap gap-1">
                      <button
                        :for={player <- @online_players}
                        phx-click="teleport_bot"
                        phx-value-bot={bot}
                        phx-value-player={player}
                        class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                      >
                        TP {player}
                      </button>
                      <div :if={@online_players == []} class="text-[10px] text-[#444]">No players online</div>
                    </div>
                  </div>

                  <%!-- Quick actions --%>
                  <div class="border border-[#222] p-3">
                    <div class="text-[10px] tracking-widest text-[#00ffff] mb-2">QUICK ACTIONS</div>
                    <div class="flex flex-wrap gap-2">
                      <button
                        phx-click="bot_action_jump"
                        phx-value-bot={bot}
                        class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                      >
                        JUMP
                      </button>
                      <button
                        phx-click="bot_action_sneak"
                        phx-value-bot={bot}
                        class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                      >
                        SNEAK
                      </button>
                      <button
                        phx-click="bot_action_attack"
                        phx-value-bot={bot}
                        class="px-3 py-1 border border-[#ff4444]/30 text-[#ff4444] text-[10px] hover:bg-[#ff4444]/10"
                      >
                        ATTACK
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- ==================== RCON TAB ==================== --%>
        <div :if={@active_tab == "rcon"} class="border-2 border-[#333]/50 bg-[#0d0d14]">
          <div class="text-[10px] tracking-widest text-[#888] px-4 pt-3 pb-2">RCON TERMINAL</div>
          <div class="bg-[#080810] mx-2 mb-2 h-96 overflow-y-auto p-3 text-xs flex flex-col-reverse border border-[#222]">
            <div :for={entry <- @rcon_history} class="mb-2">
              <div class="text-[#00ffff]">&gt; {entry.cmd}</div>
              <div class="text-[#888] whitespace-pre-wrap">{entry.result}</div>
            </div>
            <div :if={@rcon_history == []} class="text-[#333]">awaiting input...</div>
          </div>
          <form phx-submit="rcon_submit" class="flex gap-2 px-4 pb-4">
            <input
              type="text" name="command" value={@rcon_input}
              phx-change="rcon_input" placeholder="enter rcon command..."
              class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
              autocomplete="off"
            />
            <button type="submit" class="px-4 py-2 border border-[#00ffff] text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10">
              EXEC
            </button>
          </form>
        </div>

        <%!-- ==================== FX TAB ==================== --%>
        <div :if={@active_tab == "effects"} class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
          <div class="text-[10px] tracking-widest text-[#888] mb-3">EFFECTS PANEL</div>
          <div class="flex items-center gap-2 mb-4">
            <span class="text-[10px] tracking-wider text-[#666]">TARGET</span>
            <input
              type="text" value={@effect_target} phx-change="set_effect_target" name="target"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs w-40 focus:border-[#00ffff] focus:outline-none"
            />
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              :for={effect <- ["celebration", "welcome", "death", "achievement", "firework"]}
              phx-click="fire_effect"
              phx-value-effect={effect}
              class="px-4 py-2 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10 hover:border-[#aa66ff] transition-all"
            >
              {String.upcase(effect)}
            </button>
          </div>
        </div>

        <%!-- ==================== DISPLAY TAB ==================== --%>
        <div :if={@active_tab == "display"} class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
          <div class="text-[10px] tracking-widest text-[#888] mb-3">BLOCK TEXT DISPLAY</div>
          <form phx-submit="place_text" class="space-y-3">
            <input
              type="text" name="text" value={@display_text} placeholder="text to render..."
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
            />
            <div class="grid grid-cols-4 gap-2">
              <div :for={{label, name, val} <- [{"X", "x", @display_x}, {"Y", "y", @display_y}, {"Z", "z", @display_z}, {"BLOCK", "block", @display_block}]}>
                <label class="text-[10px] tracking-wider text-[#666] block mb-1">{label}</label>
                <input
                  type="text" name={name} value={val}
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
                />
              </div>
            </div>
            <button type="submit" class="px-6 py-2 border-2 border-[#00ffff] text-[#00ffff] text-[10px] tracking-widest font-bold hover:bg-[#00ffff] hover:text-[#0a0a0f] transition-all">
              RENDER
            </button>
          </form>
        </div>

        <%!-- ==================== EVENTS TAB ==================== --%>
        <div :if={@active_tab == "events"} class="border-2 border-[#333]/50 bg-[#0d0d14]">
          <div class="flex items-center justify-between px-4 pt-3 pb-2">
            <div class="text-[10px] tracking-widest text-[#888]">
              EVENT STREAM <span class="text-[#00ffff]">[{length(@events)}]</span>
            </div>
            <div class="flex items-center gap-1">
              <div class="w-1.5 h-1.5 rounded-full bg-[#00ff88] animate-pulse" />
              <span class="text-[10px] text-[#00ff88]">LIVE</span>
            </div>
          </div>
          <div class="bg-[#080810] mx-2 mb-2 h-96 overflow-y-auto p-3 text-[11px] border border-[#222]">
            <div :for={event <- @events} class="mb-0.5 flex gap-2">
              <span class="text-[#444] shrink-0">{Calendar.strftime(event.at, "%H:%M:%S")}</span>
              <span class={"shrink-0 " <> event_color(event.type)}>[{event.type}]</span>
              <span class="text-[#888]">{format_event_data(event.data)}</span>
            </div>
            <div :if={@events == []} class="text-[#333]">waiting for events...</div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp event_color(:player_join), do: "text-[#00ff88]"
  defp event_color(:player_leave), do: "text-[#ffaa00]"
  defp event_color(:player_death), do: "text-[#ff4444]"
  defp event_color(:player_chat), do: "text-[#00ffff]"
  defp event_color(:player_advancement), do: "text-[#aa66ff]"
  defp event_color(:bot_chat), do: "text-[#00ffff]"
  defp event_color(:bot_whisper), do: "text-[#ff66aa]"
  defp event_color(:bot_spawn), do: "text-[#00ff88]"
  defp event_color(_), do: "text-[#666]"

  defp format_event_data(data) when is_map(data) do
    data
    |> Map.drop([:raw_line, :timestamp])
    |> Map.drop(["raw_line", "timestamp"])
    |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
    |> Enum.join(" ")
  end

  defp format_event_data(data), do: inspect(data)

  defp format_value(v) when is_map(v), do: inspect(v)
  defp format_value(v) when is_list(v), do: inspect(v)
  defp format_value(v), do: to_string(v)
end
