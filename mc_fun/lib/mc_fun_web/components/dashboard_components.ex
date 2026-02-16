defmodule McFunWeb.DashboardComponents do
  @moduledoc """
  Function components for the MC Fun dashboard.
  Extracted from DashboardLive to reduce file size.
  """
  use Phoenix.Component

  # --- Deploy Panel ---

  attr :selected_model, :string, required: true
  attr :selected_preset, :string, default: nil
  attr :deploy_personality, :string, required: true
  attr :available_models, :list, required: true
  attr :bot_spawn_name, :string, default: ""

  def deploy_panel(assigns) do
    ~H"""
    <div class="border-2 border-[#00ffff]/20 bg-[#0d0d14] p-4">
      <div class="text-[10px] tracking-widest text-[#00ffff]/60 mb-3">DEPLOY CONFIGURATION</div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <%!-- Model selector --%>
        <div>
          <label class="text-[10px] tracking-wider text-[#888] block mb-1">MODEL</label>
          <select
            id="deploy-model-select"
            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none focus:shadow-[0_0_8px_rgba(0,255,255,0.2)]"
            phx-change="select_model"
            name="model"
            value={@selected_model}
          >
            <option :for={model <- @available_models} value={model}>
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
            id="deploy-preset-select"
            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none focus:shadow-[0_0_8px_rgba(0,255,255,0.2)]"
            phx-change="select_preset"
            name="preset"
            value={@selected_preset || "custom"}
          >
            <option value="custom">Custom</option>
            <%= for {category, presets} <- McFun.Presets.by_category() do %>
              <optgroup label={category |> to_string() |> String.upcase()}>
                <option :for={preset <- presets} value={preset.id}>
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
          id="deploy-personality-text"
          phx-change="update_deploy_personality"
          name="personality"
          phx-debounce="500"
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
            phx-debounce="300"
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
    """
  end

  # --- Bot Card ---

  attr :bot, :string, required: true
  attr :status, :map, default: nil
  attr :online_players, :list, default: []
  attr :available_models, :list, default: []

  def bot_card(assigns) do
    ~H"""
    <div id={"bot-card-#{@bot}"} class="border border-[#333] bg-[#111] p-3 hover:border-[#00ffff]/40 transition-all group">
      <%!-- Unit header --%>
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <div class={"w-1.5 h-1.5 " <>
            if(@status && @status.chatbot,
              do: "bg-[#00ff88] shadow-[0_0_4px_#00ff88]",
              else: "bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]")} />
          <span class="text-sm font-bold text-[#e0e0e0]">{@bot}</span>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="open_bot_config"
            phx-value-bot={@bot}
            class="text-[#00ffff]/50 hover:text-[#00ffff] text-[10px] tracking-widest opacity-0 group-hover:opacity-100 transition-opacity"
          >
            [CFG]
          </button>
          <button
            phx-click="stop_bot"
            phx-value-name={@bot}
            class="text-[#ff4444]/50 hover:text-[#ff4444] text-xs opacity-0 group-hover:opacity-100 transition-opacity"
          >
            [X]
          </button>
        </div>
      </div>

      <%!-- Unit details --%>
      <div class="text-[10px] tracking-wider space-y-1 text-[#888]">
        <%= if @status do %>
          <%= if @status.chatbot do %>
            <div class="flex justify-between">
              <span>STATUS</span>
              <span class="text-[#00ff88]">CHAT ACTIVE</span>
            </div>
            <div class="flex justify-between">
              <span>MODEL</span>
              <span class="text-[#00ffff]">{@status.model || "default"}</span>
            </div>
            <div class="flex justify-between">
              <span>BEHAVIOR</span>
              <span class="text-[#aa66ff]">{format_behavior(@status.behavior)}</span>
            </div>
            <%!-- Bot vitals --%>
            <%= if @status.health do %>
              <div class="flex items-center justify-between">
                <span>HP</span>
                <div class="flex items-center gap-1">
                  <div class="w-20 h-1.5 bg-[#222] overflow-hidden">
                    <div class="h-full bg-[#ff4444] shadow-[0_0_4px_#ff4444]" style={"width: #{min(100, (@status.health || 0) / 20 * 100)}%"} />
                  </div>
                  <span class="text-[#ff4444]">{trunc(@status.health)}/20</span>
                </div>
              </div>
              <div class="flex items-center justify-between">
                <span>FOOD</span>
                <div class="flex items-center gap-1">
                  <div class="w-20 h-1.5 bg-[#222] overflow-hidden">
                    <div class="h-full bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]" style={"width: #{min(100, (@status.food || 0) / 20 * 100)}%"} />
                  </div>
                  <span class="text-[#ffaa00]">{@status.food}/20</span>
                </div>
              </div>
            <% end %>
            <%= if @status.position do %>
              <div class="flex justify-between">
                <span>POS</span>
                <span class="text-[#888]"><%= with {x, y, z} <- @status.position do %>X:<span class="text-[#e0e0e0]">{trunc(x)}</span> Y:<span class="text-[#e0e0e0]">{trunc(y)}</span> Z:<span class="text-[#e0e0e0]">{trunc(z)}</span><% end %></span>
              </div>
            <% end %>
            <%= if @status.dimension do %>
              <div class="flex justify-between">
                <span>DIM</span>
                <span class="text-[#aa66ff]">{String.upcase(@status.dimension)}</span>
              </div>
            <% end %>
            <%!-- Model switcher --%>
            <div class="pt-1">
              <select
                id={"model-select-#{@bot}"}
                class="w-full bg-[#0a0a0f] border border-[#333] text-[#aaa] px-2 py-1 text-[10px] focus:border-[#00ffff] focus:outline-none"
                phx-change="change_bot_model"
                name="model"
                phx-value-bot={@bot}
                value={@status.model}
              >
                <option :for={model <- @available_models} value={model}>
                  {model}
                </option>
              </select>
            </div>
            <%!-- Actions row --%>
            <div class="pt-1 flex gap-1">
              <button
                :for={player <- @online_players}
                id={"tp-#{@bot}-#{player}"}
                phx-click="teleport_bot"
                phx-value-bot={@bot}
                phx-value-player={player}
                class="flex-1 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
              >
                TP {player}
              </button>
            </div>
            <div class="pt-1">
              <button
                phx-click="open_bot_config"
                phx-value-bot={@bot}
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
              phx-value-bot={@bot}
              class="w-full mt-1 py-1 border border-[#00ff88]/50 text-[#00ff88] text-[10px] tracking-widest hover:bg-[#00ff88]/10"
            >
              ATTACH CHATBOT
            </button>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Bot Config Modal ---

  attr :bot, :string, required: true
  attr :status, :map, default: nil
  attr :modal_tab, :string, required: true
  attr :available_models, :list, default: []
  attr :online_players, :list, default: []

  def bot_config_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/70">
      <div class="fixed inset-0" phx-click="close_bot_config"></div>
      <div class="relative z-10 w-full max-w-2xl max-h-[85vh] overflow-y-auto bg-[#0d0d14] border-2 border-[#00ffff]/40 shadow-[0_0_30px_rgba(0,255,255,0.15)]">
        <%!-- Modal header --%>
        <div class="flex items-center justify-between px-4 py-3 border-b border-[#222]">
          <div class="flex items-center gap-2">
            <div class={"w-2 h-2 " <> if(@status && @status.chatbot, do: "bg-[#00ff88] shadow-[0_0_4px_#00ff88]", else: "bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]")} />
            <span class="text-sm font-bold text-[#e0e0e0] tracking-wider">{@bot}</span>
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
                id={"modal-model-#{@bot}"}
                class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none"
                phx-change="change_bot_model"
                name="model"
                phx-value-bot={@bot}
                value={@status && @status.model}
              >
                <option :for={model <- @available_models} value={model}>
                  {model}
                </option>
              </select>
            </div>

            <%!-- Personality --%>
            <div>
              <label class="text-[10px] tracking-wider text-[#888] block mb-1">PERSONALITY</label>
              <form id={"personality-form-#{@bot}"} phx-submit="save_personality">
                <input type="hidden" name="bot" value={@bot} />
                <textarea
                  id={"personality-text-#{@bot}"}
                  name="personality"
                  rows="5"
                  class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none resize-y"
                ><%= if(@status && @status.personality, do: @status.personality, else: "") %></textarea>
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
                  phx-value-bot={@bot}
                  class="text-[10px] text-[#ff4444]/50 hover:text-[#ff4444]"
                >
                  CLEAR ALL
                </button>
              </div>
              <%= if @status && @status.conversation_players && @status.conversation_players != [] do %>
                <div class="bg-[#080810] border border-[#222] p-2 text-[10px] text-[#888] space-y-1 max-h-32 overflow-y-auto">
                  <div :for={player <- @status.conversation_players} id={"convo-#{@bot}-#{player}"} class="flex items-center gap-2">
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
                <span class="text-[10px] text-[#aa66ff]">{format_behavior(@status && @status.behavior)}</span>
              </div>
              <button
                :if={@status && @status.behavior}
                phx-click="stop_behavior"
                phx-value-bot={@bot}
                class="px-3 py-1 border border-[#ff4444]/50 text-[#ff4444] text-[10px] tracking-widest hover:bg-[#ff4444]/10"
              >
                STOP
              </button>
            </div>

            <%!-- Patrol --%>
            <div class="border border-[#222] p-3">
              <div class="text-[10px] tracking-widest text-[#aa66ff] mb-2">PATROL</div>
              <form id={"patrol-form-#{@bot}"} phx-submit="start_behavior_patrol">
                <input type="hidden" name="bot" value={@bot} />
                <input
                  id={"patrol-waypoints-#{@bot}"}
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
              <form id={"follow-form-#{@bot}"} phx-submit="start_behavior_follow">
                <input type="hidden" name="bot" value={@bot} />
                <div class="flex gap-2">
                  <select
                    id={"follow-target-#{@bot}"}
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
              <form id={"guard-form-#{@bot}"} phx-submit="start_behavior_guard" class="space-y-2">
                <input type="hidden" name="bot" value={@bot} />
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
              <form id={"chat-form-#{@bot}"} phx-submit="bot_action_chat" class="flex gap-2">
                <input type="hidden" name="bot" value={@bot} />
                <input
                  id={"chat-msg-#{@bot}"}
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
              <form id={"goto-form-#{@bot}"} phx-submit="bot_action_goto" class="space-y-2">
                <input type="hidden" name="bot" value={@bot} />
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
                  id={"modal-tp-#{@bot}-#{player}"}
                  phx-click="teleport_bot"
                  phx-value-bot={@bot}
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
                  phx-value-bot={@bot}
                  class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                >
                  JUMP
                </button>
                <button
                  phx-click="bot_action_sneak"
                  phx-value-bot={@bot}
                  class="px-3 py-1 border border-[#00ffff]/30 text-[#00ffff] text-[10px] hover:bg-[#00ffff]/10"
                >
                  SNEAK
                </button>
                <button
                  phx-click="bot_action_attack"
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

  # --- Shared Helpers ---

  defp format_behavior(nil), do: "NONE"
  defp format_behavior(%{behavior: :patrol}), do: "PATROL"
  defp format_behavior(%{behavior: :follow, params: %{target: t}}), do: "FOLLOW #{t}"
  defp format_behavior(%{behavior: :guard}), do: "GUARD"
  defp format_behavior(_), do: "ACTIVE"
end
