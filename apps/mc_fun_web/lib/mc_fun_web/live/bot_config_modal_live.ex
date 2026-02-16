defmodule McFunWeb.BotConfigModalLive do
  @moduledoc "Bot configuration modal LiveComponent — LLM, behavior, and action controls."
  use McFunWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:modal_tab, fn -> "llm" end)
     |> assign_new(:pending_model, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/70"
      role="dialog"
      aria-modal="true"
      aria-label={"Configure #{@bot}"}
    >
      <div class="fixed inset-0" phx-click="close_bot_config"></div>
      <div class="relative z-10 w-full max-w-2xl max-h-[85vh] overflow-y-auto bg-[#0d0d14] border-2 border-[#00ffff]/40 shadow-[0_0_30px_rgba(0,255,255,0.15)]">
        <%!-- Modal header --%>
        <div class="flex items-center justify-between px-4 py-3 border-b border-[#222]">
          <div class="flex items-center gap-2">
            <div class={"w-2 h-2 " <> if(@status && @status.chatbot, do: "bg-[#00ff88] shadow-[0_0_4px_#00ff88]", else: "bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]")} />
            <span class="text-sm font-bold text-[#e0e0e0] tracking-wider">{@bot}</span>
            <span class="text-[10px] text-[#666] tracking-wider">CONFIG</span>
          </div>
          <button phx-click="close_bot_config" class="text-[#666] hover:text-[#e0e0e0] text-sm">
            [X]
          </button>
        </div>

        <%!-- Modal tabs --%>
        <div
          class="flex border-b border-[#222]"
          role="tablist"
          aria-label="Bot configuration sections"
        >
          <button
            :for={{id, label} <- [{"llm", "LLM"}, {"behavior", "BEHAVIOR"}, {"actions", "ACTIONS"}]}
            role="tab"
            aria-selected={to_string(@modal_tab == id)}
            class={"px-4 py-2 text-[10px] tracking-widest border-b-2 transition-all " <>
              if(@modal_tab == id,
                do: "border-[#00ffff] text-[#00ffff]",
                else: "border-transparent text-[#666] hover:text-[#aaa]")}
            phx-click="switch_modal_tab"
            phx-target={@myself}
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
              <div class="flex gap-2">
                <select
                  id={"modal-model-#{@bot}"}
                  class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none"
                  phx-change="select_modal_model"
                  phx-target={@myself}
                  name="model"
                  value={@pending_model || (@status && @status.model)}
                >
                  <option
                    :for={model <- @available_models}
                    value={model}
                    selected={model == (@pending_model || (@status && @status.model))}
                  >
                    {model}
                  </option>
                </select>
                <button
                  phx-click="apply_bot_model"
                  phx-target={@myself}
                  phx-value-bot={@bot}
                  disabled={is_nil(@pending_model)}
                  class={"px-4 py-2 border text-[10px] tracking-widest transition-all " <>
                    if(@pending_model,
                      do: "border-[#00ff88] text-[#00ff88] hover:bg-[#00ff88]/10",
                      else: "border-[#333] text-[#444] cursor-not-allowed")}
                >
                  APPLY
                </button>
              </div>
            </div>

            <%!-- Personality --%>
            <div>
              <label class="text-[10px] tracking-wider text-[#888] block mb-1">PERSONALITY</label>
              <form id={"personality-form-#{@bot}"} phx-submit="save_personality" phx-target={@myself}>
                <input type="hidden" name="bot" value={@bot} />
                <textarea
                  id={"personality-text-#{@bot}"}
                  name="personality"
                  rows="5"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none resize-y"
                ><%= if(@status && @status.personality, do: @status.personality, else: "") %></textarea>
                <button
                  type="submit"
                  class="mt-1 px-4 py-1 border border-[#00ff88]/50 text-[#00ff88] text-[10px] tracking-widest hover:bg-[#00ff88]/10"
                >
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
                    <div class="text-[9px] tracking-widest text-[#555] mb-1">
                      {category |> to_string() |> String.upcase()}
                    </div>
                    <div class="flex flex-wrap gap-1">
                      <button
                        :for={preset <- presets}
                        phx-click="apply_preset_to_bot"
                        phx-target={@myself}
                        phx-value-bot={@bot}
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
                  phx-target={@myself}
                  phx-value-bot={@bot}
                  class="text-[10px] text-[#ff4444]/50 hover:text-[#ff4444]"
                >
                  CLEAR ALL
                </button>
              </div>
              <%= if @status && @status.conversation_players && @status.conversation_players != [] do %>
                <div class="bg-[#080810] border border-[#222] p-2 text-[10px] text-[#888] space-y-1 max-h-32 overflow-y-auto">
                  <div
                    :for={player <- @status.conversation_players}
                    id={"convo-#{@bot}-#{player}"}
                    class="flex items-center gap-2"
                  >
                    <span class="text-[#00ffff]">{player}</span>
                    <span class="text-[#444]">
                      {length(Map.get(@status.conversations || %{}, player, []))} msgs
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
                <span class="text-[10px] text-[#aa66ff]">
                  {format_behavior(@status && @status.behavior)}
                </span>
              </div>
              <button
                :if={@status && @status.behavior}
                phx-click="stop_behavior"
                phx-target={@myself}
                phx-value-bot={@bot}
                class="px-3 py-1 border border-[#ff4444]/50 text-[#ff4444] text-[10px] tracking-widest hover:bg-[#ff4444]/10"
              >
                STOP
              </button>
            </div>

            <%!-- Patrol --%>
            <div class="border border-[#222] p-3">
              <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">PATROL</div>
              <form id={"patrol-form-#{@bot}"} phx-submit="start_behavior_patrol" phx-target={@myself}>
                <input type="hidden" name="bot" value={@bot} />
                <input
                  id={"patrol-waypoints-#{@bot}"}
                  type="text"
                  name="waypoints"
                  placeholder="[[0,64,0],[10,64,10],[20,64,0]]"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
                />
                <button
                  type="submit"
                  class="mt-1 px-4 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10"
                >
                  START PATROL
                </button>
              </form>
            </div>

            <%!-- Follow --%>
            <div class="border border-[#222] p-3">
              <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">FOLLOW</div>
              <form id={"follow-form-#{@bot}"} phx-submit="start_behavior_follow" phx-target={@myself}>
                <input type="hidden" name="bot" value={@bot} />
                <div class="flex gap-2">
                  <select
                    id={"follow-target-#{@bot}"}
                    name="target"
                    class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
                  >
                    <option :for={player <- @online_players} value={player}>{player}</option>
                  </select>
                  <button
                    type="submit"
                    class="px-4 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10"
                  >
                    FOLLOW
                  </button>
                </div>
              </form>
            </div>

            <%!-- Guard --%>
            <div class="border border-[#222] p-3">
              <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">GUARD</div>
              <form
                id={"guard-form-#{@bot}"}
                phx-submit="start_behavior_guard"
                phx-target={@myself}
                class="space-y-2"
              >
                <input type="hidden" name="bot" value={@bot} />
                <div class="grid grid-cols-4 gap-2">
                  <div :for={
                    {label, name, default} <- [
                      {"X", "x", guard_default(@status, :x, "0")},
                      {"Y", "y", guard_default(@status, :y, "64")},
                      {"Z", "z", guard_default(@status, :z, "0")},
                      {"R", "radius", "8"}
                    ]
                  }>
                    <label class="text-[10px] tracking-wider text-[#666] block mb-0.5">{label}</label>
                    <input
                      type="text"
                      name={name}
                      value={default}
                      class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
                    />
                  </div>
                </div>
                <button
                  type="submit"
                  class="px-4 py-1 border border-[#aa66ff]/50 text-[#aa66ff] text-[10px] tracking-widest hover:bg-[#aa66ff]/10"
                >
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
              <form
                id={"chat-form-#{@bot}"}
                phx-submit="bot_action_chat"
                phx-target={@myself}
                class="flex gap-2"
              >
                <input type="hidden" name="bot" value={@bot} />
                <input
                  id={"chat-msg-#{@bot}"}
                  type="text"
                  name="message"
                  placeholder="say something..."
                  class="flex-1 bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
                />
                <button
                  type="submit"
                  class="px-4 py-1 border border-[#00ffff]/50 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10"
                >
                  SEND
                </button>
              </form>
            </div>

            <%!-- Goto --%>
            <div class="border border-[#222] p-3">
              <div class="text-[10px] tracking-widest text-[#00ffff] mb-2">GOTO</div>
              <form
                id={"goto-form-#{@bot}"}
                phx-submit="bot_action_goto"
                phx-target={@myself}
                class="space-y-2"
              >
                <input type="hidden" name="bot" value={@bot} />
                <div class="grid grid-cols-3 gap-2">
                  <div :for={{label, name} <- [{"X", "x"}, {"Y", "y"}, {"Z", "z"}]}>
                    <label class="text-[10px] tracking-wider text-[#666] block mb-0.5">{label}</label>
                    <input
                      type="text"
                      name={name}
                      value="0"
                      class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
                    />
                  </div>
                </div>
                <button
                  type="submit"
                  class="px-4 py-1 border border-[#00ffff]/50 text-[#00ffff] text-[10px] tracking-widest hover:bg-[#00ffff]/10"
                >
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
                  id={"modal-tp-#{@bot}-#{player}"}
                  phx-click="teleport_bot"
                  phx-target={@myself}
                  phx-value-bot={@bot}
                  phx-value-player={player}
                  class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                >
                  TP {player}
                </button>
                <div :if={@online_players == []} class="text-[10px] text-[#444]">
                  No players online
                </div>
              </div>
            </div>

            <%!-- Quick actions --%>
            <div class="border border-[#222] p-3">
              <div class="text-[10px] tracking-widest text-[#00ffff] mb-2">QUICK ACTIONS</div>
              <div class="flex flex-wrap gap-2">
                <button
                  phx-click="bot_action_jump"
                  phx-target={@myself}
                  phx-value-bot={@bot}
                  class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                >
                  JUMP
                </button>
                <button
                  phx-click="bot_action_sneak"
                  phx-target={@myself}
                  phx-value-bot={@bot}
                  class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                >
                  SNEAK
                </button>
                <button
                  phx-click="bot_action_attack"
                  phx-target={@myself}
                  phx-value-bot={@bot}
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
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("switch_modal_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, modal_tab: tab)}
  end

  def handle_event("select_modal_model", %{"model" => model}, socket) do
    current = socket.assigns.status && socket.assigns.status.model
    pending = if model == current, do: nil, else: model
    {:noreply, assign(socket, pending_model: pending)}
  end

  def handle_event("apply_bot_model", %{"bot" => bot_name}, socket) do
    model = socket.assigns.pending_model

    if model do
      McFun.ChatBot.set_model(bot_name, model)
      notify_parent(socket, {:flash, :info, "#{bot_name} >> #{model}"})
      notify_parent(socket, :refresh_bot_statuses)
      {:noreply, assign(socket, pending_model: nil)}
    else
      {:noreply, socket}
    end
  catch
    _, _ ->
      notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot_name}"})
      {:noreply, socket}
  end

  def handle_event("save_personality", %{"bot" => bot, "personality" => personality}, socket) do
    McFun.ChatBot.set_personality(bot, personality)
    notify_parent(socket, {:flash, :info, "#{bot} personality updated"})
    notify_parent(socket, :refresh_bot_statuses)
    {:noreply, socket}
  catch
    _, _ ->
      notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot}"})
      {:noreply, socket}
  end

  def handle_event("clear_conversation", %{"bot" => bot}, socket) do
    info = McFun.ChatBot.info(bot)

    for _player <- info[:conversation_players] || [] do
      McFun.ChatBot.set_personality(bot, info[:personality] || default_personality())
    end

    McFun.Bot.chat(bot, "Memory cleared!")
    notify_parent(socket, {:flash, :info, "#{bot} conversations cleared"})
    notify_parent(socket, :refresh_bot_statuses)
    {:noreply, socket}
  catch
    _, _ ->
      notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot}"})
      {:noreply, socket}
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
        combined =
          String.trim(default_personality()) <> "\n\n" <> String.trim(preset.system_prompt)

        try do
          McFun.ChatBot.set_personality(bot, combined)
          notify_parent(socket, {:flash, :info, "#{bot} >> #{preset.name}"})
          notify_parent(socket, :refresh_bot_statuses)
          {:noreply, socket}
        catch
          _, _ ->
            notify_parent(socket, {:flash, :error, "ChatBot not active for #{bot}"})
            {:noreply, socket}
        end

      _ ->
        notify_parent(socket, {:flash, :error, "Preset not found: #{preset_id}"})
        {:noreply, socket}
    end
  end

  # --- Bot Actions ---

  def handle_event("bot_action_chat", %{"bot" => bot, "message" => msg}, socket) when msg != "" do
    McFun.Bot.chat(bot, msg)
    notify_parent(socket, {:flash, :info, "#{bot}: #{msg}"})
    {:noreply, socket}
  end

  def handle_event("bot_action_chat", _, socket), do: {:noreply, socket}

  def handle_event("bot_action_goto", params, socket) do
    bot = params["bot"]
    x = safe_int(params["x"])
    y = safe_int(params["y"])
    z = safe_int(params["z"])
    McFun.Bot.send_command(bot, %{action: "goto", x: x, y: y, z: z})
    notify_parent(socket, {:flash, :info, "#{bot} >> goto #{x},#{y},#{z}"})
    {:noreply, socket}
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

  def handle_event("teleport_bot", %{"bot" => bot, "player" => player}, socket)
      when player != "" do
    McFun.Bot.teleport_to(bot, player)
    notify_parent(socket, {:flash, :info, "#{bot} >> tp to #{player}"})
    {:noreply, socket}
  end

  def handle_event("teleport_bot", _, socket), do: {:noreply, socket}

  # --- Behavior Controls ---

  def handle_event("start_behavior_patrol", %{"bot" => bot, "waypoints" => wp_json}, socket) do
    case Jason.decode(wp_json) do
      {:ok, waypoints} when is_list(waypoints) ->
        tuples = Enum.map(waypoints, fn [x, y, z] -> {x, y, z} end)
        McFun.BotBehaviors.start_patrol(bot, tuples)

        notify_parent(
          socket,
          {:flash, :info, "#{bot} patrol started (#{length(tuples)} waypoints)"}
        )

        notify_parent(socket, :refresh_bot_statuses)
        {:noreply, socket}

      _ ->
        notify_parent(socket, {:flash, :error, "Invalid waypoints JSON. Use [[x,y,z], ...]"})
        {:noreply, socket}
    end
  end

  def handle_event("start_behavior_follow", params, socket) do
    bot = params["bot"]
    target = params["target"]

    if target && target != "" do
      McFun.BotBehaviors.start_follow(bot, target)
      notify_parent(socket, {:flash, :info, "#{bot} following #{target}"})
      notify_parent(socket, :refresh_bot_statuses)
      {:noreply, socket}
    else
      notify_parent(socket, {:flash, :error, "Select a player to follow"})
      {:noreply, socket}
    end
  end

  def handle_event("start_behavior_guard", params, socket) do
    bot = params["bot"]
    x = safe_int(params["x"])
    y = safe_int(params["y"])
    z = safe_int(params["z"])
    radius = safe_int(params["radius"] || "8")
    McFun.BotBehaviors.start_guard(bot, {x, y, z}, radius: radius)
    notify_parent(socket, {:flash, :info, "#{bot} guarding #{x},#{y},#{z} (r=#{radius})"})
    notify_parent(socket, :refresh_bot_statuses)
    {:noreply, socket}
  end

  def handle_event("stop_behavior", %{"bot" => bot}, socket) do
    McFun.BotBehaviors.stop(bot)
    notify_parent(socket, {:flash, :info, "#{bot} behavior stopped"})
    notify_parent(socket, :refresh_bot_statuses)
    {:noreply, socket}
  end

  # --- Helpers ---

  defp notify_parent(socket, message) do
    send(socket.assigns.parent_pid, message)
  end

  defp default_personality do
    "You are a friendly Minecraft bot. Keep responses to 1-2 sentences. No markdown."
  end

  defp safe_int(val) when is_integer(val), do: val

  defp safe_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp safe_int(_), do: 0

  defp format_behavior(nil), do: "NONE"
  defp format_behavior(%{behavior: :patrol}), do: "PATROL"
  defp format_behavior(%{behavior: :follow, params: %{target: t}}), do: "FOLLOW #{t}"
  defp format_behavior(%{behavior: :guard}), do: "GUARD"
  defp format_behavior(_), do: "ACTIVE"

  defp guard_default(%{position: {x, _y, _z}}, :x, _fallback) when is_number(x),
    do: to_string(trunc(x))

  defp guard_default(%{position: {_x, y, _z}}, :y, _fallback) when is_number(y),
    do: to_string(trunc(y))

  defp guard_default(%{position: {_x, _y, z}}, :z, _fallback) when is_number(z),
    do: to_string(trunc(z))

  defp guard_default(_, _, fallback), do: fallback
end
