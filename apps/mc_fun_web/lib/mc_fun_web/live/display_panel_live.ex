defmodule McFunWeb.DisplayPanelLive do
  @moduledoc "Display panel LiveComponent — block text rendering controls."
  use McFunWeb, :live_component

  alias McFun.World.Display

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:display_text, fn -> "" end)
     |> assign_new(:display_x, fn -> "0" end)
     |> assign_new(:display_y, fn -> "80" end)
     |> assign_new(:display_z, fn -> "0" end)
     |> assign_new(:display_block, fn -> "diamond_block" end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="panel-display"
      role="tabpanel"
      class="border-2 border-[#333]/50 bg-[#0d0d14] p-4"
    >
      <div class="text-[10px] tracking-widest text-[#888] mb-3">BLOCK TEXT DISPLAY</div>
      <form phx-submit="place_text" phx-target={@myself} class="space-y-3">
        <input
          type="text"
          name="text"
          value={@display_text}
          placeholder="text to render..."
          class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-3 py-2 text-xs focus:border-[#00ffff] focus:outline-none placeholder:text-[#444]"
        />
        <%!-- Entity picker for location --%>
        <div class="flex items-center gap-2">
          <span class="text-[10px] tracking-wider text-[#666]">LOCATION FROM</span>
          <select
            phx-change="pick_display_entity"
            phx-target={@myself}
            name="entity"
            class="bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
          >
            <option value="">Manual</option>
            <%= for bot <- @bots do %>
              <option value={bot}>{bot}</option>
            <% end %>
            <%= for {name, _data} <- @player_statuses, name not in @bots do %>
              <option value={name}>{name}</option>
            <% end %>
          </select>
        </div>
        <div class="grid grid-cols-4 gap-2">
          <div :for={
            {label, name, val} <- [
              {"X", "x", @display_x},
              {"Y", "y", @display_y},
              {"Z", "z", @display_z},
              {"BLOCK", "block", @display_block}
            ]
          }>
            <label class="text-[10px] tracking-wider text-[#666] block mb-1">{label}</label>
            <input
              type="text"
              name={name}
              value={val}
              class="w-full bg-[#111] border border-[#333] text-[#e0e0e0] px-2 py-1.5 text-xs focus:border-[#00ffff] focus:outline-none"
            />
          </div>
        </div>
        <button
          type="submit"
          phx-disable-with="RENDERING..."
          class="px-6 py-2 border-2 border-[#00ffff] text-[#00ffff] text-[10px] tracking-widest font-bold hover:bg-[#00ffff] hover:text-[#0a0a0f] transition-all"
        >
          RENDER
        </button>
      </form>
    </div>
    """
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("place_text", params, socket) do
    text = Map.get(params, "text", "")
    x = safe_int(Map.get(params, "x", "0"))
    y = safe_int(Map.get(params, "y", "80"))
    z = safe_int(Map.get(params, "z", "0"))
    block = Map.get(params, "block", "diamond_block")

    if text != "" do
      parent = socket.assigns.parent_pid

      Task.start(fn ->
        try do
          Display.write(text, {x, y, z}, block: block)
        rescue
          e -> send(parent, {:flash, :error, "Display failed: #{Exception.message(e)}"})
        end
      end)

      send(parent, {:flash, :info, "Placing '#{text}' at #{x},#{y},#{z}"})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_display_entity", %{"entity" => ""}, socket), do: {:noreply, socket}

  def handle_event("pick_display_entity", %{"entity" => name}, socket) do
    case lookup_entity_position(socket.assigns, name) do
      {x, y, z} ->
        {:noreply,
         assign(socket,
           display_x: to_string(trunc(x)),
           display_y: to_string(trunc(y)),
           display_z: to_string(trunc(z))
         )}

      nil ->
        {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp safe_int(val) when is_integer(val), do: val

  defp safe_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp safe_int(_), do: 0

  defp lookup_entity_position(assigns, name) do
    case get_in(assigns, [:bot_statuses, name, :position]) do
      {_, _, _} = pos ->
        pos

      _ ->
        case get_in(assigns, [:player_statuses, name, :position]) do
          {_, _, _} = pos -> pos
          _ -> nil
        end
    end
  end
end
