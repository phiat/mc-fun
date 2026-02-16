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
  attr :target, :any, default: nil

  def deploy_panel(assigns) do
    ~H"""
    <div class="border-2 border-[#00ffff]/20 bg-[#0d0d14] p-4">
      <div class="text-[10px] tracking-widest text-[#00ffff]/60 mb-3">DEPLOY CONFIGURATION</div>

      <form phx-submit="deploy_bot" phx-target={@target} class="space-y-3">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <%!-- Bot name --%>
          <div>
            <label class="text-[10px] tracking-wider text-[#888] block mb-1">NAME</label>
            <input
              type="text"
              name="name"
              value={@bot_spawn_name}
              phx-change="bot_name_input"
              phx-target={@target}
              phx-debounce="300"
              placeholder="McFunBot"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
            />
          </div>

          <%!-- Model selector --%>
          <div>
            <label class="text-[10px] tracking-wider text-[#888] block mb-1">MODEL</label>
            <select
              id="deploy-model-select"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none focus:shadow-[0_0_8px_rgba(0,255,255,0.2)]"
              phx-change="select_model"
              phx-target={@target}
              name="model"
              value={@selected_model}
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
              id="deploy-preset-select"
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none focus:shadow-[0_0_8px_rgba(0,255,255,0.2)]"
              phx-change="select_preset"
              phx-target={@target}
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
        </div>

        <%!-- Personality textarea --%>
        <div>
          <label class="text-[10px] tracking-wider text-[#888] block mb-1">PERSONALITY</label>
          <textarea
            id="deploy-personality-text"
            phx-change="update_deploy_personality"
            phx-target={@target}
            name="personality"
            phx-debounce="500"
            rows="3"
            class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none resize-y placeholder:text-[#444]"
          >{@deploy_personality}</textarea>
        </div>

        <%!-- Deploy button --%>
        <div class="flex items-center justify-between">
          <button
            type="submit"
            phx-target={@target}
            phx-disable-with="DEPLOYING..."
            class="py-2 px-6 border-2 border-[#00ff88] text-[#00ff88] font-bold text-xs tracking-widest hover:bg-[#00ff88] hover:text-[#0a0a0f] transition-all"
          >
            DEPLOY
          </button>
          <div class="text-[10px] text-[#444]">whitelist first: /whitelist add BotName</div>
        </div>
      </form>
    </div>
    """
  end

  # --- Bot Card ---

  attr :bot, :string, required: true
  attr :status, :map, default: nil
  attr :online_players, :list, default: []
  attr :available_models, :list, default: []
  attr :pending_model, :string, default: nil
  attr :target, :any, default: nil

  def bot_card(assigns) do
    ~H"""
    <div
      id={"bot-card-#{@bot}"}
      class="border border-[#333] bg-[#111] p-3 hover:border-[#00ffff]/40 transition-all group"
    >
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
            phx-target={@target}
            phx-value-bot={@bot}
            class="text-[#00ffff]/50 hover:text-[#00ffff] text-[10px] tracking-widest opacity-0 group-hover:opacity-100 transition-opacity"
          >
            [CFG]
          </button>
          <button
            phx-click="stop_bot"
            phx-target={@target}
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
            <div class="flex justify-between items-center">
              <span>HEARTBEAT</span>
              <button
                phx-click="toggle_heartbeat"
                phx-target={@target}
                phx-value-bot={@bot}
                phx-value-enabled={to_string(!@status[:heartbeat_enabled])}
                class={"text-[10px] tracking-widest " <>
                  if(@status[:heartbeat_enabled],
                    do: "text-[#00ff88]",
                    else: "text-[#ff4444]")}
              >
                {if @status[:heartbeat_enabled], do: "ON", else: "OFF"}
              </button>
            </div>
            <%= if @status[:cost] && @status.cost.calls > 0 do %>
              <div class="flex justify-between">
                <span>COST</span>
                <span class="text-[#ffcc00]">
                  {McFun.CostTracker.format_cost(@status.cost.cost)} | {McFun.CostTracker.format_tokens(
                    @status.cost.total_tokens
                  )} tok
                </span>
              </div>
            <% end %>
            <%!-- Bot vitals --%>
            <%= if @status.health do %>
              <div class="flex items-center justify-between">
                <span>HP</span>
                <div class="flex items-center gap-1">
                  <div class="w-20 h-1.5 bg-[#222] overflow-hidden">
                    <div
                      class="h-full bg-[#ff4444] shadow-[0_0_4px_#ff4444]"
                      style={"width: #{min(100, (@status.health || 0) / 20 * 100)}%"}
                    />
                  </div>
                  <span class="text-[#ff4444]">{trunc(@status.health)}/20</span>
                </div>
              </div>
              <div class="flex items-center justify-between">
                <span>FOOD</span>
                <div class="flex items-center gap-1">
                  <div class="w-20 h-1.5 bg-[#222] overflow-hidden">
                    <div
                      class="h-full bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]"
                      style={"width: #{min(100, (@status.food || 0) / 20 * 100)}%"}
                    />
                  </div>
                  <span class="text-[#ffaa00]">{@status.food}/20</span>
                </div>
              </div>
            <% end %>
            <%= if @status.position do %>
              <div class="flex justify-between items-center">
                <span>POS</span>
                <span class="text-[#888] flex items-center">
                  <%= with {x, y, z} <- @status.position do %>
                    X:<span class="text-[#e0e0e0]">{trunc(x)}</span> Y:<span class="text-[#e0e0e0]">{trunc(y)}</span> Z:<span class="text-[#e0e0e0]">{trunc(z)}</span>
                    <button
                      phx-click="use_coords"
                      phx-target={@target}
                      phx-value-x={trunc(x)}
                      phx-value-y={trunc(y)}
                      phx-value-z={trunc(z)}
                      phx-value-name={@bot}
                      class="text-[8px] text-[#00ffff]/60 hover:text-[#00ffff] ml-1"
                      title="Use coordinates in Display/FX"
                    >
                      [USE]
                    </button>
                  <% end %>
                </span>
              </div>
            <% end %>
            <%= if @status.dimension do %>
              <div class="flex justify-between">
                <span>DIM</span>
                <span class="text-[#aa66ff]">{String.upcase(@status.dimension)}</span>
              </div>
            <% end %>
            <%!-- Inventory --%>
            <%= if @status.inventory != [] do %>
              <div class="pt-1 border-t border-[#222]">
                <div class="text-[9px] text-[#666] mb-0.5">INVENTORY</div>
                <div class="flex flex-wrap gap-x-2 gap-y-0.5">
                  <span
                    :for={item <- Enum.take(format_inventory(@status.inventory), 6)}
                    class="text-[#aaa]"
                  >
                    {item}
                  </span>
                </div>
                <%= if length(@status.inventory) > 6 do %>
                  <div class="text-[9px] text-[#555] mt-0.5">
                    +{length(@status.inventory) - 6} more
                  </div>
                <% end %>
              </div>
            <% end %>
            <%!-- Last message --%>
            <%= if @status[:last_message] do %>
              <details class="pt-1 border-t border-[#222]">
                <summary class="text-[9px] text-[#666] cursor-pointer hover:text-[#aaa] select-none">
                  LAST MESSAGE
                </summary>
                <div class="mt-1 text-[10px] text-[#aaa] bg-[#080810] border border-[#222] p-2 break-words max-h-20 overflow-y-auto">
                  {@status.last_message}
                </div>
              </details>
            <% end %>
            <%!-- Model switcher --%>
            <div class="pt-1 flex gap-1">
              <select
                id={"model-select-#{@bot}"}
                class="flex-1 bg-[#0a0a0f] border border-[#333] text-[#aaa] px-2 py-1 text-[10px] focus:border-[#00ffff] focus:outline-none"
                phx-change="select_card_model"
                phx-target={@target}
                name="model"
                phx-value-bot={@bot}
                value={@pending_model || @status.model}
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
                phx-click="apply_card_model"
                phx-target={@target}
                phx-value-bot={@bot}
                disabled={is_nil(@pending_model)}
                class={"px-2 py-1 border text-[9px] tracking-widest transition-all " <>
                  if(@pending_model,
                    do: "border-[#00ff88] text-[#00ff88] hover:bg-[#00ff88]/10",
                    else: "border-[#333] text-[#444] cursor-not-allowed")}
              >
                APPLY
              </button>
            </div>
            <%!-- Actions row --%>
            <div class="pt-1 flex gap-1">
              <button
                :for={player <- Enum.reject(@online_players, &(&1 == @bot))}
                id={"tp-#{@bot}-#{player}"}
                phx-click="teleport_bot"
                phx-target={@target}
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
                phx-target={@target}
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
              phx-target={@target}
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

  # --- Player Card ---

  attr :name, :string, required: true
  attr :data, :map, required: true

  def player_card(assigns) do
    ~H"""
    <div class="border border-[#333] bg-[#111] p-3 hover:border-[#00ff88]/40 transition-all">
      <%!-- Player header --%>
      <div class="flex items-center gap-2 mb-2">
        <div class="w-1.5 h-1.5 bg-[#00ff88] shadow-[0_0_4px_#00ff88]" />
        <span class="text-sm font-bold text-[#e0e0e0]">{@name}</span>
      </div>

      <div class="text-[10px] tracking-wider space-y-1 text-[#888]">
        <%!-- Health --%>
        <%= if @data.health do %>
          <div class="flex items-center justify-between">
            <span>HP</span>
            <div class="flex items-center gap-1">
              <div class="w-20 h-1.5 bg-[#222] overflow-hidden">
                <div
                  class="h-full bg-[#ff4444] shadow-[0_0_4px_#ff4444]"
                  style={"width: #{min(100, (@data.health || 0) / 20 * 100)}%"}
                />
              </div>
              <span class="text-[#ff4444]">{trunc(@data.health)}/20</span>
            </div>
          </div>
        <% end %>
        <%!-- Food --%>
        <%= if @data.food do %>
          <div class="flex items-center justify-between">
            <span>FOOD</span>
            <div class="flex items-center gap-1">
              <div class="w-20 h-1.5 bg-[#222] overflow-hidden">
                <div
                  class="h-full bg-[#ffaa00] shadow-[0_0_4px_#ffaa00]"
                  style={"width: #{min(100, (@data.food || 0) / 20 * 100)}%"}
                />
              </div>
              <span class="text-[#ffaa00]">{@data.food}/20</span>
            </div>
          </div>
        <% end %>
        <%!-- Position --%>
        <%= if @data.position do %>
          <div class="flex justify-between items-center">
            <span>POS</span>
            <span class="text-[#888] flex items-center">
              <%= with {x, y, z} <- @data.position do %>
                X:<span class="text-[#e0e0e0]">{trunc(x)}</span> Y:<span class="text-[#e0e0e0]">{trunc(y)}</span> Z:<span class="text-[#e0e0e0]">{trunc(z)}</span>
                <button
                  phx-click="use_coords"
                  phx-value-x={trunc(x)}
                  phx-value-y={trunc(y)}
                  phx-value-z={trunc(z)}
                  phx-value-name={@name}
                  class="text-[8px] text-[#00ffff]/60 hover:text-[#00ffff] ml-1"
                  title="Use coordinates in Display/FX"
                >
                  [USE]
                </button>
              <% end %>
            </span>
          </div>
        <% end %>
        <%!-- Dimension --%>
        <%= if @data.dimension do %>
          <div class="flex justify-between">
            <span>DIM</span>
            <span class="text-[#aa66ff]">{String.upcase(@data.dimension)}</span>
          </div>
        <% end %>
        <%!-- Held Item --%>
        <%= if @data[:held_item] do %>
          <div class="flex justify-between">
            <span>HELD</span>
            <span class="text-[#ffcc00]">{format_item_name(@data.held_item)}</span>
          </div>
        <% end %>
        <%!-- Fallback if no data --%>
        <%= if is_nil(@data.health) and is_nil(@data.position) do %>
          <div class="text-[#444]">Loading data...</div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Shared Helpers ---

  defp format_behavior(nil), do: "NONE"
  defp format_behavior(%{behavior: :patrol}), do: "PATROL"
  defp format_behavior(%{behavior: :follow, params: %{target: t}}), do: "FOLLOW #{t}"
  defp format_behavior(%{behavior: :guard}), do: "GUARD"
  defp format_behavior(%{behavior: :mine, params: %{block_type: b}}), do: "MINE #{b}"
  defp format_behavior(_), do: "ACTIVE"

  defp format_inventory(items) when is_list(items) do
    # Group by name and sum counts, then format as "NxName"
    items
    |> Enum.group_by(fn item -> item["name"] || item[:name] end)
    |> Enum.map(fn {name, group} ->
      count =
        Enum.reduce(group, 0, fn item, acc -> acc + (item["count"] || item[:count] || 1) end)

      "#{count}x #{format_item_name(name)}"
    end)
    |> Enum.sort_by(fn entry ->
      case Integer.parse(entry) do
        {n, _} -> -n
        :error -> 0
      end
    end)
  end

  defp format_item_name(nil), do: "?"

  defp format_item_name(name) when is_binary(name) do
    name
    |> String.replace("minecraft:", "")
    |> String.replace("_", " ")
  end
end
