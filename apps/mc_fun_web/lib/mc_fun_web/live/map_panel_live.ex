defmodule McFunWeb.MapPanelLive do
  @moduledoc "Map panel LiveComponent — top-down terrain map from bot chunk data."
  use McFunWeb, :live_component

  require Logger

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:terrain_data, fn -> nil end)
      |> assign_new(:scan_bot, fn -> nil end)
      |> assign_new(:scanning, fn -> false end)
      |> assign_new(:scan_center, fn -> nil end)
      |> assign_new(:scan_error, fn -> nil end)

    # Push entity positions to JS hook whenever statuses update
    entities = build_entity_list(assigns[:bot_statuses] || %{}, assigns[:player_statuses] || %{})
    socket = push_event(socket, "entity_positions", %{entities: entities})

    {:ok, socket}
  end

  @impl true
  def handle_event("select_scan_bot", %{"bot" => bot}, socket) do
    {:noreply, assign(socket, scan_bot: bot)}
  end

  def handle_event("scan_terrain", _params, socket) do
    bot = socket.assigns.scan_bot || List.first(socket.assigns.bots || [])

    if bot do
      parent = socket.assigns.parent_pid
      lv_id = socket.assigns.id

      Task.start(fn ->
        result = BotFarmer.terrain_scan(bot)
        send(parent, {:terrain_scan_result, lv_id, result})
      end)

      {:noreply, assign(socket, scanning: true, scan_bot: bot, scan_error: nil)}
    else
      {:noreply, assign(socket, scan_error: "No bots available")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="panel-map" role="tabpanel" class="space-y-4">
      <div class="border-2 border-[#333]/50 bg-[#0d0d14] p-4">
        <div class="flex items-center justify-between mb-3">
          <div class="text-[10px] tracking-widest text-[#888]">WORLD MAP</div>
          <div class="flex items-center gap-2">
            <select
              phx-change="select_scan_bot"
              phx-target={@myself}
              name="bot"
              class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1 text-xs focus:border-[#00ffff] focus:outline-none"
            >
              <option :for={bot <- @bots} value={bot} selected={bot == @scan_bot}>{bot}</option>
            </select>
            <button
              phx-click="scan_terrain"
              phx-target={@myself}
              disabled={@scanning}
              class={"px-3 py-1 text-[10px] tracking-widest border transition-all " <>
                if(@scanning,
                  do: "border-[#333] text-[#555] cursor-wait",
                  else: "border-[#00ffff] text-[#00ffff] hover:bg-[#00ffff]/10")}
            >
              {if @scanning, do: "SCANNING...", else: "SCAN"}
            </button>
          </div>
        </div>

        <div :if={@scan_error} class="text-[#ff4444] text-xs mb-2">{@scan_error}</div>

        <div :if={@scan_center} class="text-[10px] text-[#666] mb-2 flex gap-4">
          <span>CENTER: <span class="text-[#00ffff]">{@scan_center.x}, {@scan_center.z}</span></span>
          <span>BLOCKS: <span class="text-[#00ff88]">{if @terrain_data, do: length(@terrain_data), else: 0}</span></span>
          <span class="text-[#555]">scroll=zoom, drag=pan</span>
        </div>

        <div
          id="world-map-container"
          phx-hook="WorldMap"
          phx-update="ignore"
          class="relative border border-[#222] bg-[#050508]"
          style="height: 600px;"
        >
          <canvas id="world-map-canvas" class="w-full h-full" />
          <div
            :if={!@terrain_data}
            class="absolute inset-0 flex items-center justify-center text-[#333] text-xs tracking-widest"
          >
            SELECT A BOT AND CLICK SCAN
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp build_entity_list(bot_statuses, player_statuses) do
    bots =
      for {name, status} <- bot_statuses, status[:position] do
        {x, y, z} = status.position

        %{
          name: name,
          type: "bot",
          x: x,
          y: y,
          z: z,
          color: "#00ffff"
        }
      end

    players =
      for {name, data} <- player_statuses, data[:position] do
        pos = data.position

        %{
          name: name,
          type: "player",
          x: pos[:x] || pos["x"],
          y: pos[:y] || pos["y"],
          z: pos[:z] || pos["z"],
          color: "#00ff88"
        }
      end

    bots ++ players
  end
end
